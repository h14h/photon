defmodule PhotonNode.Executor.Request do
  @moduledoc """
  Turns the hub's `op.start` into an operation this node can run, and
  builds the snapshots the executor sends for operations it won't run.

  `operation/2` judges a parsed `op.start` (`PhotonCore.Operation.Wire`
  checks only its shape) and fills in what the node knows: the shell to run
  commands with, the ops directory (`<data_dir>/ops`, where each operation
  keeps its journal and output files) and the workspace. `facts` carries
  them, so this module reads nothing itself:

      %{shell: "/bin/bash", ops_dir: "/data/ops", workspace: "/data/workspace"}

  Arguments by kind (`docs/plans/step-1-machine-tools.md`, section 2.2):

    * `shell`: `command` (a string with no NUL byte, at most 100,000
      bytes), `directory` (a string or null; null is the workspace, and a
      relative one is taken from the workspace) and `max_output_length`
      (1 to 1,000,000).
    * `view_image`: `path` (not blank, no NUL byte; a relative one is taken
      from `directory`, or from the workspace), `directory` and `max_size`
      (base64 bytes, at most 5,000,000, so a snapshot carrying the image
      stays under the frame limit).

  An unknown kind or a bad argument is `{:error, reason}`, and `rejected/2`
  makes that the operation's `failed` snapshot. `lost/2`, `never_started/1`,
  `unrecorded/2` and `unreadable/2` are the snapshots for the other
  operations the node answers without running (section 2.3, node rules 3,
  7 and 8, and a journal entry that can't be read). `failed/2` is the
  snapshot of an operation whose process crashed or couldn't start. Each
  carries its message in `terminal_error`; a `view_image` one also has it
  in `result.error`, where a failed image job puts its reason.

  `fit/2` keeps a snapshot's JSON under a byte budget (node rule 9).

  Pure: no processes, files or clock.
  """

  # Functional core (see PhotonNode.Executor): no processes, no I/O.
  use Boundary, type: :strict, deps: [PhotonCore, Jason]

  alias PhotonCore.{Operation, Output}

  @max_command_bytes 100_000
  @max_image_bytes 5_000_000
  @snapshot_budget 6_000_000
  @version 1

  # How many times `fit/2` re-cuts from the original when its estimate of
  # the encoding was off.
  @fit_attempts 3

  # The text fields fit/2 may cut: where each sits in a snapshot, and the
  # state and result keys of its file's path, the file's size and its
  # truncated flag.
  @cuttable [
    %{
      keys: ["state", "result", "out"],
      path: "out_path",
      size: "out_size",
      flag: "out_truncated"
    },
    %{
      keys: ["state", "result", "err"],
      path: "err_path",
      size: "err_size",
      flag: "err_truncated"
    },
    %{keys: ["state", "terminal_error"], path: nil, size: nil, flag: nil}
  ]

  @typedoc "What the node knows that an operation needs; see the moduledoc."
  @type facts :: %{shell: String.t(), ops_dir: String.t(), workspace: String.t()}

  @typedoc ~S|A parsed `op.start`: `%{"id", "kind", "args", "known"}`.|
  @type start :: %{optional(String.t()) => term()}

  @doc "The largest JSON encoding of a snapshot, in bytes, under the hub's 8 MB frame limit."
  @spec snapshot_budget() :: pos_integer()
  def snapshot_budget, do: @snapshot_budget

  @doc """
  The `ready` operation for a parsed `op.start`, or `{:error, reason}` when
  the node can't run its kind or its arguments are wrong.
  """
  @spec operation(start(), facts()) :: {:ok, Operation.t()} | {:error, String.t()}
  def operation(%{"id" => id, "kind" => "shell", "args" => args}, facts) do
    with {:ok, command} <- command(args["command"]),
         {:ok, directory} <- directory(args["directory"], "shell"),
         {:ok, limit} <- output_limit(args["max_output_length"]) do
      input = %{
        "command" => command,
        "shell" => facts.shell,
        "directory" => resolve(directory || facts.workspace, facts.workspace)
      }

      {:ok, Operation.new(id, "shell", @version, shell_state(input, facts.ops_dir), limit)}
    end
  end

  def operation(%{"id" => id, "kind" => "view_image", "args" => args}, facts) do
    with {:ok, path} <- image_path(args["path"]),
         {:ok, directory} <- directory(args["directory"], "view_image"),
         {:ok, max_size} <- max_size(args["max_size"]) do
      base = resolve(directory || facts.workspace, facts.workspace)
      state = %{"path" => resolve(path, base), "max_size" => max_size, "result" => nil}
      {:ok, Operation.new(id, "view_image", @version, state, nil)}
    end
  end

  def operation(%{"kind" => kind}, _facts),
    do: {:error, ~s(photon-node can't run operations of kind "#{kind}")}

  @doc "The `failed` snapshot for an `op.start` that `operation/2` refused with `reason`."
  @spec rejected(start(), String.t()) :: Operation.t()
  def rejected(%{"id" => id, "kind" => kind}, reason), do: answer(id, kind, "failed", reason)

  @doc """
  The `failed` snapshot for an operation the hub has seen but this node has
  no journal for (node rule 3): its data directory was wiped or reset.
  """
  @spec lost(String.t(), String.t()) :: Operation.t()
  def lost(id, kind),
    do:
      answer(
        id,
        kind,
        "failed",
        "The machine has no record of this operation. It may or may not have run."
      )

  @doc """
  The `canceled` snapshot for an `op.cancel` that came before its
  `op.start` (node rule 7). `op.cancel` carries only the ID, so the type is
  `"unknown"`; the hub reads the kind from its own record.
  """
  @spec never_started(String.t()) :: Operation.t()
  def never_started(id), do: answer(id, "unknown", "canceled", "Canceled before it started.")

  @doc """
  The `failed` snapshot for a `ready` operation whose journal entry couldn't
  be written, so it never ran (node rule 8).
  """
  @spec unrecorded(Operation.t(), String.t()) :: Operation.t()
  def unrecorded(op, reason),
    do: failed(op, "The machine couldn't record the operation: #{reason}. It didn't run.")

  @doc """
  The `failed` snapshot for an `op.start` whose journal entry exists but
  can't be read (`reason`), with no process running the operation.
  """
  @spec unreadable(start(), String.t()) :: Operation.t()
  def unreadable(%{"id" => id, "kind" => kind}, reason) do
    message =
      "The machine's record of this operation can't be read (#{reason}). " <>
        "It may or may not have run."

    answer(id, kind, "failed", message)
  end

  @doc """
  `op` failed with `message`: the snapshot the executor records when an
  operation process crashes or can't be started.
  """
  @spec failed(Operation.t(), String.t()) :: Operation.t()
  def failed(op, message), do: Operation.advance(op, "failed", failure(op["type"], message))

  ## Arguments

  defp command(command) when is_binary(command) do
    cond do
      byte_size(command) > @max_command_bytes ->
        {:error, ~s(shell argument "command" is over #{@max_command_bytes} bytes)}

      nul?(command) ->
        {:error, ~s(shell argument "command" contains a NUL byte)}

      true ->
        {:ok, command}
    end
  end

  defp command(_command), do: {:error, ~s(shell argument "command" must be a string)}

  defp directory(nil, _kind), do: {:ok, nil}

  defp directory(directory, kind) when is_binary(directory) do
    cond do
      String.trim(directory) == "" -> {:error, ~s(#{kind} argument "directory" is blank)}
      nul?(directory) -> {:error, ~s(#{kind} argument "directory" contains a NUL byte)}
      true -> {:ok, directory}
    end
  end

  defp directory(_directory, kind),
    do: {:error, ~s(#{kind} argument "directory" must be a string or null)}

  defp output_limit(limit) when is_integer(limit) and limit in 1..1_000_000//1,
    do: {:ok, limit}

  defp output_limit(_limit),
    do:
      {:error,
       ~s(shell argument "max_output_length" must be an integer from 1 to #{Output.max_limit()})}

  defp image_path(path) when is_binary(path) do
    cond do
      String.trim(path) == "" -> {:error, ~s(view_image argument "path" is blank)}
      nul?(path) -> {:error, ~s(view_image argument "path" contains a NUL byte)}
      true -> {:ok, path}
    end
  end

  defp image_path(_path), do: {:error, ~s(view_image argument "path" must be a string)}

  defp max_size(size) when is_integer(size) and size in 1..@max_image_bytes//1, do: {:ok, size}

  defp max_size(_size),
    do:
      {:error,
       ~s(view_image argument "max_size" must be an integer from 1 to #{@max_image_bytes})}

  defp nul?(text), do: :binary.match(text, <<0>>) != :nomatch

  # `path` as an absolute path, taking a relative one from `base`.
  defp resolve(path, base) do
    if Path.type(path) == :absolute, do: path, else: Path.join(base, path)
  end

  # The state `Ops.Shell` starts from.
  defp shell_state(input, ops_dir) do
    %{
      "input" => input,
      "base_directory" => ops_dir,
      "phase" => "",
      "pgid" => 0,
      "exit_code" => nil,
      "result" => nil,
      "terminal_error" => "",
      "out_path" => "",
      "err_path" => ""
    }
  end

  ## Answers

  defp answer(id, kind, status, message),
    do: %{Operation.new(id, kind, @version, failure(kind, message), nil) | "status" => status}

  # An image job's reason is in `result.error`; the hub reads it from there.
  defp failure("view_image", message),
    do: %{"terminal_error" => message, "result" => %{"error" => message}}

  defp failure(_kind, message), do: %{"terminal_error" => message}

  ## Fitting a snapshot to a budget

  @doc """
  `snapshot` with its JSON encoding at most `budget` bytes (node rule 9).

  Output bounds count code points, and a NUL encodes as `\\u0000`, so two
  streams of 1,000,000 code points can encode to 12 MB. A snapshot over
  the budget has `result.out`, `result.err` and `terminal_error` cut
  further by encoded bytes. The budget left after the rest of the snapshot
  is shared out so the smaller fields stay whole. Each cut field keeps its
  head and its tail around a marker with the number of bytes left out of
  the full output and, for `out` and `err`, the path of the file that has
  it, and its `out_truncated` or `err_truncated` flag is set. A snapshot
  under the budget comes back unchanged. One whose other fields alone are
  over it (it can't happen within the argument limits) comes back with
  those three fields cut to their markers.
  """
  @spec fit(Operation.t(), pos_integer()) :: Operation.t()
  def fit(snapshot, budget) do
    size = encoded_size(snapshot)
    if size <= budget, do: snapshot, else: fit(snapshot, budget, budget, size, @fit_attempts)
  end

  # Cuts the original snapshot to `target`, and again to a smaller target
  # if the encoding still comes out over `budget`.
  defp fit(snapshot, budget, target, size, attempts) do
    cut = cut(snapshot, cuttable(snapshot), size, target)

    case encoded_size(cut) do
      fitted when fitted <= budget or attempts <= 1 -> cut
      over -> fit(snapshot, budget, target - (over - budget), size, attempts - 1)
    end
  end

  defp cut(snapshot, fields, size, target) do
    rest = size - Enum.sum_by(fields, & &1.encoded)
    available = target - rest - Enum.sum_by(fields, &marker_room/1)

    fields
    |> share(available)
    |> Enum.reduce(snapshot, fn {field, allowance}, acc -> cut_field(acc, field, allowance) end)
  end

  defp encoded_size(snapshot), do: snapshot |> Jason.encode!() |> byte_size()

  # The text fields fit/2 may cut, with what each needs: where it sits, the
  # file holding all of it and that file's size, and its truncated flag.
  defp cuttable(%{"state" => state} = snapshot) when is_map(state) do
    for spec <- @cuttable,
        text = get_in(snapshot, spec.keys),
        is_binary(text) and text != "",
        do: field(spec, text, state)
  end

  defp cuttable(_snapshot), do: []

  defp field(spec, text, state) do
    path = state[spec.path]
    size = if is_map(state["result"]), do: state["result"][spec.size]
    truncated = spec.flag != nil and state[spec.flag] == true
    path = if is_binary(path) and path != "", do: path, else: nil

    %{
      keys: spec.keys,
      flag: spec.flag,
      path: path,
      size: if(is_integer(size) and size >= byte_size(text), do: size, else: byte_size(text)),
      encoded: encoded_length(text),
      parts: parts(text, path, truncated)
    }
  end

  # The head and tail of a text: either side of the marker it already has,
  # or the whole text from both ends.
  defp parts(text, path, true = _truncated) do
    case Regex.run(marker_pattern(path), text, return: :index) do
      [{start, length} | _] ->
        {binary_part(text, 0, start),
         binary_part(text, start + length, byte_size(text) - start - length)}

      nil ->
        {text, text}
    end
  end

  defp parts(text, _path, _truncated), do: {text, text}

  defp marker_pattern(nil), do: ~r/\.\.\.\d+ bytes truncated\.\.\./

  defp marker_pattern(path),
    do:
      Regex.compile!(
        "\\.\\.\\.\\d+ bytes truncated; complete output in " <> Regex.escape(path) <> "\\.\\.\\."
      )

  # Room for a marker with any byte count.
  defp marker_room(field), do: encoded_length(marker(1_000_000_000_000, field.path))

  # Output's marker on its own: nothing kept around it, `skipped` bytes left out.
  defp marker(skipped, path), do: Output.truncated("", "", skipped, 0, path)

  # Shares `available` encoded bytes among the fields, the smallest first,
  # so a field under its fair share keeps all of it. Returns each field
  # with its allowance.
  defp share(fields, available) do
    {shares, _left} =
      fields
      |> Enum.sort_by(& &1.encoded)
      |> Enum.with_index()
      |> Enum.map_reduce(max(available, 0), fn {field, index}, left ->
        allowance = min(field.encoded, div(left, length(fields) - index))
        {{field, allowance}, left - allowance}
      end)

    shares
  end

  defp cut_field(snapshot, %{encoded: encoded}, allowance) when allowance >= encoded,
    do: snapshot

  defp cut_field(snapshot, field, allowance) do
    {head, tail} = keep(field.parts, allowance)
    skipped = max(field.size - byte_size(head) - byte_size(tail), 0)
    snapshot = put_in(snapshot, field.keys, head <> marker(skipped, field.path) <> tail)
    if field.flag, do: put_in(snapshot, ["state", field.flag], true), else: snapshot
  end

  # The head and tail to keep within `allowance` encoded bytes: half each,
  # and what one side doesn't use goes to the other.
  defp keep({head_text, tail_text}, allowance) do
    {first, first_cost} = take_head(head_text, div(allowance, 2))
    {tail, tail_cost} = take_tail(tail_text, allowance - first_cost)

    if tail_cost < allowance - first_cost,
      do: {head_text |> take_head(allowance - tail_cost) |> elem(0), tail},
      else: {first, tail}
  end

  # The longest prefix of `text` whose JSON encoding is at most `allowance`
  # bytes, and that encoding's size.
  defp take_head(text, allowance), do: take_head(text, text, allowance, 0, 0)

  defp take_head(text, <<char::utf8, rest::binary>>, allowance, bytes, cost) do
    char_cost = escaped_size(char)

    if cost + char_cost <= allowance,
      do: take_head(text, rest, allowance, bytes + byte_size(<<char::utf8>>), cost + char_cost),
      else: {binary_part(text, 0, bytes), cost}
  end

  defp take_head(text, _rest, _allowance, bytes, cost), do: {binary_part(text, 0, bytes), cost}

  # The longest suffix of `text` whose JSON encoding is at most `allowance`
  # bytes, and that encoding's size.
  defp take_tail(text, allowance), do: take_tail(text, allowance, byte_size(text), 0)

  defp take_tail(text, allowance, start, cost) do
    with {char, char_start} <- previous_char(text, start),
         char_cost = escaped_size(char),
         true <- cost + char_cost <= allowance do
      take_tail(text, allowance, char_start, cost + char_cost)
    else
      _ -> {binary_part(text, start, byte_size(text) - start), cost}
    end
  end

  # The code point that ends at byte `stop` (a UTF-8 code point is 1 to 4
  # bytes), and where it starts.
  defp previous_char(text, stop) when stop >= 1 do
    case binary_part(text, stop - 1, 1) do
      <<char::utf8>> -> {char, stop - 1}
      _ -> previous_char(text, stop, 2)
    end
  end

  defp previous_char(_text, _stop), do: nil

  defp previous_char(text, stop, width) when width <= 4 and stop >= width do
    case binary_part(text, stop - width, width) do
      <<char::utf8>> -> {char, stop - width}
      _ -> previous_char(text, stop, width + 1)
    end
  end

  defp previous_char(_text, _stop, _width), do: nil

  defp encoded_length(text), do: encoded_length(text, 0)

  defp encoded_length(<<char::utf8, rest::binary>>, cost),
    do: encoded_length(rest, cost + escaped_size(char))

  # Not UTF-8: counted as the replacement character JSON needs instead.
  defp encoded_length(<<_byte, rest::binary>>, cost), do: encoded_length(rest, cost + 3)
  defp encoded_length(<<>>, cost), do: cost

  # A code point's size in a JSON string, as Jason escapes it by default.
  defp escaped_size(char) when char in [?", ?\\, ?\b, ?\t, ?\n, ?\f, ?\r], do: 2
  defp escaped_size(char) when char < 0x20, do: 6
  defp escaped_size(char), do: byte_size(<<char::utf8>>)
end

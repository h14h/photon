defmodule Photon.MachineTools.Translate do
  @moduledoc """
  Translates between Blip's machine tools and operations, as pure
  functions (sections 3.1 and 3.4 of `docs/plans/step-1-machine-tools.md`).
  Ported from the node's `Tools.Bash` and `Tools.ViewImage`.

  Arguments one way: `shell_args/1` and `view_image_args/1` check a tool
  call's arguments and return the op's `args` for `op.start`, with
  `directory` null (commands run in the machine's workspace in step 1).

  Snapshots the other way: `result/3` turns a terminal snapshot into the
  content the model sees, and `details/3` into what the UI keeps with it.
  The node already bounds each output field to the call's
  `max_output_length`; the hub bounds it again, so a misbehaving node
  can't flood the model. The second bound leaves room for the node's own
  truncation marker, so a well-behaved node's output passes through
  unchanged. An image is passed on only if its type is one the model takes
  and its base64 is within `max_size/0`.

  Also the error texts for a machine the hub doesn't know or that runs a
  photon-node too old to take commands.
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: [PhotonCore]

  alias PhotonCore.{Message, Operation, Output}

  # A command is passed to the shell as one argument, and Linux refuses one
  # over 128 KB, so a longer one couldn't run anyway (section 2.2).
  @max_command_bytes 100_000

  # The largest base64 image a result may carry, about 3.7 MB of image data.
  @max_size 4_999_000

  @mimes ~w(image/png image/jpeg image/gif image/webp)

  # Room for the node's truncation marker ("...N bytes truncated; complete
  # output in <path>...") on top of the limit, when the hub bounds a field
  # the node has already bounded.
  @marker_room 1_000

  # How long a node keeps a finished op's out and err files (node rule 6).
  @kept "7 days"

  @typedoc "A tool call's arguments, as the model sent them."
  @type tool_args :: %{optional(String.t()) => term()}

  @typedoc "An op's `args`, as `op.start` carries them."
  @type op_args :: %{optional(String.t()) => term()}

  @typedoc "What the UI keeps with a result: string keys, no image data."
  @type details :: %{optional(String.t()) => term()}

  @doc "The largest `command`, in bytes."
  @spec max_command_bytes() :: pos_integer()
  def max_command_bytes, do: @max_command_bytes

  @doc "The largest base64 image a `view_image` result may carry."
  @spec max_size() :: pos_integer()
  def max_size, do: @max_size

  @doc """
  The `args` of a `shell` op for a `shell` call's arguments: `command`,
  `directory` (null) and `max_output_length` (40,000 if not given), or the
  reason the call can't run.
  """
  @spec shell_args(tool_args()) :: {:ok, op_args()} | {:error, String.t()}
  def shell_args(args) do
    with {:ok, limit} <- limit(args["max_output_length"]),
         {:ok, command} <- command(Map.fetch(args, "command")) do
      {:ok, %{"command" => command, "directory" => nil, "max_output_length" => limit}}
    end
  end

  defp limit(nil), do: {:ok, Output.default_limit()}

  defp limit(n) when is_integer(n) and n > 1_000_000,
    do: {:error, "shell argument: max_output_length must not exceed 1000000"}

  defp limit(n) when is_integer(n) and n > 0, do: {:ok, n}

  defp limit(n) when is_integer(n),
    do: {:error, "shell argument: max_output_length must be a positive integer"}

  defp limit(_), do: {:error, "shell argument: max_output_length must be an integer"}

  defp command(:error), do: {:error, ~s(shell argument "command" must be set)}
  defp command({:ok, nil}), do: {:error, ~s(shell argument "command" must be set)}

  defp command({:ok, command}) when is_binary(command) do
    cond do
      String.trim(command) == "" ->
        {:error, ~s(shell argument "command" must be set)}

      byte_size(command) > @max_command_bytes ->
        {:error,
         ~s(shell argument "command" is #{byte_size(command)} bytes; the limit is #{@max_command_bytes}. ) <>
           "Write a long script to a file in smaller pieces and run the file."}

      true ->
        check_nul(command, :binary.match(command, <<0>>))
    end
  end

  defp command({:ok, _other}), do: {:error, ~s(shell argument "command" must be a string)}

  defp check_nul(command, :nomatch), do: {:ok, command}

  defp check_nul(_command, {offset, _length}),
    do: {:error, ~s(shell argument "command" contains a NUL byte at offset #{offset})}

  @doc """
  The `args` of a `view_image` op for a `view_image` call's arguments:
  `path` (absolute, or relative to the machine's workspace), `directory`
  (null) and `max_size`, or the reason the call can't run.
  """
  @spec view_image_args(tool_args()) :: {:ok, op_args()} | {:error, String.t()}
  def view_image_args(%{"path" => path}) when is_binary(path) do
    cond do
      String.trim(path) == "" ->
        {:error, ~s(view_image argument "path" must be set)}

      match?({_, _}, :binary.match(path, <<0>>)) ->
        {:error, ~s(view_image argument "path" contains a NUL byte)}

      true ->
        {:ok, %{"path" => path, "directory" => nil, "max_size" => @max_size}}
    end
  end

  def view_image_args(%{"path" => path}) when not is_nil(path),
    do: {:error, ~s(view_image argument "path" must be a string)}

  def view_image_args(_args), do: {:error, ~s(view_image argument "path" must be set)}

  @doc """
  The content the model sees for an op's terminal snapshot: for `shell`,
  stdout, then stderr and the exit code when not 0 (or `(no output)`), or
  `Error: ...` if it failed or was canceled; for `view_image`, the image
  and a line with its size, type, path and machine.
  """
  @spec result(String.t(), Operation.t(), String.t()) :: [Message.part()]
  def result(_kind, %{"status" => status}, machine)
      when status not in ["completed", "failed", "canceled"],
      do: [Message.text("Error: the operation on #{machine} ended while #{status}.")]

  def result("shell", snapshot, _machine), do: [Message.text(shell_text(snapshot))]
  def result("view_image", snapshot, machine), do: image_result(snapshot, machine)

  def result(kind, _snapshot, machine),
    do: [
      Message.text("Error: #{machine} answered an operation of unknown kind #{inspect(kind)}.")
    ]

  defp shell_text(%{"status" => "completed", "state" => state} = snapshot) do
    result = state["result"] || %{}
    limit = bound_limit(snapshot)

    lines =
      Enum.reject(
        [
          out_line(bounded(result["out"], limit, state["out_path"])),
          err_line(bounded(result["err"], limit, state["err_path"])),
          exit_line(result["exit_code"])
        ],
        &is_nil/1
      )

    if lines == [], do: "(no output)", else: Enum.join(lines, "\n")
  end

  defp shell_text(%{"status" => status} = snapshot),
    do: "Error: " <> failure(snapshot, "shell operation #{status}")

  defp out_line(""), do: nil
  defp out_line(out), do: out

  defp err_line(""), do: nil
  defp err_line(err), do: "Stderr:\n" <> err

  defp exit_line(code) when is_integer(code) and code != 0, do: "Exit code: #{code}"
  defp exit_line(_code), do: nil

  defp image_result(%{"status" => "completed", "state" => %{"result" => %{} = image}}, machine) do
    case check_image(image) do
      :ok ->
        [Message.image(image["mime"], image["content"]), Message.text(image_line(image, machine))]

      {:error, reason} ->
        [Message.text("Error: #{machine} sent an image the hub can't pass on: #{reason}.")]
    end
  end

  defp image_result(%{"status" => "completed"}, machine),
    do: [Message.text("Error: #{machine} finished the operation without an image.")]

  defp image_result(%{"status" => status} = snapshot, _machine),
    do: [Message.text("Error: " <> failure(snapshot, "view_image operation #{status}"))]

  defp check_image(%{"mime" => mime, "content" => content}) when is_binary(content) do
    cond do
      mime not in @mimes ->
        {:error, "#{inspect(mime)} is not PNG, JPEG, GIF or WebP"}

      byte_size(content) > @max_size ->
        {:error, "#{byte_size(content)} base64 bytes is over the limit of #{@max_size}"}

      true ->
        :ok
    end
  end

  defp check_image(_image), do: {:error, "it has no image data"}

  defp image_line(image, machine) do
    size =
      if is_integer(image["width"]) and is_integer(image["height"]),
        do: "#{image["width"]}x#{image["height"]} ",
        else: ""

    "#{size}#{image["mime"]}, #{image["path"]} on #{machine}"
  end

  # The reason an op failed or was canceled: the job's own error, the
  # snapshot's terminal error, or a plain fallback; bounded like output.
  defp failure(%{"state" => state} = snapshot, fallback) when is_map(state) do
    message =
      case state do
        %{"result" => %{"error" => error}} when is_binary(error) and error != "" -> error
        %{"terminal_error" => error} when is_binary(error) and error != "" -> error
        _ -> fallback
      end

    bounded(message, bound_limit(snapshot), nil)
  end

  defp failure(_snapshot, fallback), do: fallback

  defp bounded(text, limit, path) when is_binary(text) do
    path = if is_binary(path) and path != "", do: path, else: nil
    Output.bound!(text, limit, path)
  end

  defp bounded(_text, _limit, _path), do: ""

  defp bound_limit(snapshot), do: output_limit(snapshot) + @marker_room

  # The call's own limit, which the snapshot repeats; the default if the
  # node sent something else.
  defp output_limit(%{"max_output_length" => n}) when is_integer(n) and n > 0,
    do: min(n, Output.max_limit())

  defp output_limit(_snapshot), do: Output.default_limit()

  @doc """
  What the UI keeps with a result: `machine`, `op_id`, `kind`, `status`,
  and `command` or `path`; for `shell` also `exit_code`, `out_truncated`
  and `err_truncated`, and `full_output`, where the machine keeps the
  complete `out` and `err` (the hint `Photon.Durable.Context` shows when it
  shortens an older result). No image data.
  """
  @spec details(String.t(), Operation.t(), String.t()) :: details()
  def details("shell", snapshot, machine) do
    state = state(snapshot)
    result = if is_map(state["result"]), do: state["result"], else: %{}

    snapshot
    |> base_details("shell", machine)
    |> Map.merge(%{
      "command" => get_in(state, ["input", "command"]),
      "exit_code" => result["exit_code"],
      "out_truncated" => truncated?(state["out_truncated"], result["out"], snapshot),
      "err_truncated" => truncated?(state["err_truncated"], result["err"], snapshot)
    })
    |> put_full_output(state["out_path"], state["err_path"], machine)
  end

  def details("view_image", snapshot, machine) do
    state = state(snapshot)
    path = get_in(state, ["result", "path"]) || state["path"]
    snapshot |> base_details("view_image", machine) |> Map.put("path", path)
  end

  def details(kind, snapshot, machine), do: base_details(snapshot, kind, machine)

  defp state(%{"state" => %{} = state}), do: state
  defp state(_snapshot), do: %{}

  defp base_details(snapshot, kind, machine),
    do: %{
      "machine" => machine,
      "op_id" => snapshot["id"],
      "kind" => kind,
      "status" => snapshot["status"]
    }

  # Truncated by the node, or by the hub's second bound.
  defp truncated?(true, _text, _snapshot), do: true

  defp truncated?(_flag, text, snapshot) when is_binary(text),
    do: text |> Output.bound(bound_limit(snapshot)) |> elem(1)

  defp truncated?(_flag, _text, _snapshot), do: false

  defp put_full_output(details, out, err, machine)
       when is_binary(out) and out != "" and is_binary(err) and err != "",
       do:
         Map.put(
           details,
           "full_output",
           "Full output: #{out} and #{err} on #{machine}, kept for #{@kept}."
         )

  defp put_full_output(details, _out, _err, _machine), do: details

  @doc """
  The error for a call on a machine the hub doesn't know, listing the ones
  it does.
  """
  @spec unknown_machine(String.t(), [String.t()]) :: String.t()
  def unknown_machine(machine, []),
    do:
      "There is no machine called #{inspect(machine)}, and this hub doesn't know any machines yet. " <>
        "Add one from the Nodes page."

  def unknown_machine(machine, known_ids),
    do:
      "There is no machine called #{inspect(machine)}. The machines this hub knows are " <>
        Enum.join(known_ids, ", ") <> "."

  @doc "The error for a call on a machine whose photon-node predates the operation protocol."
  @spec outdated_machine(String.t()) :: String.t()
  def outdated_machine(machine),
    do:
      "#{machine} runs an older photon-node that can't take commands. " <>
        "Reinstall it from the Nodes page."
end

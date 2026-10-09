defmodule PhotonCore.Operation.Result do
  @moduledoc """
  What a terminal snapshot's state may hold, so a reader can take each
  field as a string, an integer, an object or nil without guarding it.
  `PhotonCore.Operation.Wire` checks only the envelope; this checks the
  state. The hub runs `accept/2` on every terminal snapshot a node sends,
  against the kind of op it asked for (not the snapshot's own `type`, which
  is the node's word), so a malformed result becomes a failure the tool
  call reports, instead of a crash when the call reads it.

  Each field may be missing or null. When set:

    * every kind: `terminal_error` is a string, `input` and `result`
      objects, and `result`'s `error` a string
    * `shell`: `out_path` and `err_path` are strings; `input`'s `command`,
      `shell` and `directory` strings; `result`'s `out` and `err` strings,
      and `exit_code`, `out_size` and `err_size` integers
    * `view_image`: `result`'s `content`, `mime` and `path` are strings, and
      `width` and `height` integers

  Other kinds aren't checked; the hub reports them as unknown.
  """

  alias PhotonCore.Operation

  @state_fields %{
    "shell" => [terminal_error: :string, out_path: :string, err_path: :string],
    "view_image" => [terminal_error: :string]
  }

  @input_fields %{
    "shell" => [command: :string, shell: :string, directory: :string],
    "view_image" => []
  }

  @result_fields %{
    "shell" => [
      error: :string,
      out: :string,
      err: :string,
      exit_code: :integer,
      out_size: :integer,
      err_size: :integer
    ],
    "view_image" => [
      error: :string,
      content: :string,
      mime: :string,
      path: :string,
      width: :integer,
      height: :integer
    ]
  }

  @doc """
  `:ok` when `op`'s state holds what an op of `kind` promises (see the
  moduledoc), or the first field that doesn't. A snapshot that isn't
  terminal, or a kind not listed, is `:ok`.
  """
  @spec check(Operation.t(), String.t()) :: :ok | {:error, String.t()}
  def check(%{"state" => state} = op, kind)
      when is_map_key(@state_fields, kind) and is_map(state) do
    if Operation.terminal?(op), do: check_state(kind, state), else: :ok
  end

  def check(_op, _kind), do: :ok

  @doc """
  `{:ok, op}` when `check/2` passes; otherwise `{:malformed, failed, reason}`,
  where `failed` is the same op `failed`, its input and result dropped and
  its `terminal_error` saying the machine sent a result the hub can't read.
  """
  @spec accept(Operation.t(), String.t()) ::
          {:ok, Operation.t()} | {:malformed, Operation.t(), String.t()}
  def accept(op, kind) do
    case check(op, kind) do
      :ok ->
        {:ok, op}

      {:error, reason} ->
        message = "The machine sent a result the hub can't read (#{reason})."

        {:malformed,
         Operation.advance(op, "failed", %{
           "input" => nil,
           "result" => nil,
           "terminal_error" => message
         }), reason}
    end
  end

  defp check_state(kind, state) do
    with :ok <- check_fields(state, @state_fields[kind], "state"),
         :ok <- check_object(state, "input", @input_fields[kind]) do
      check_object(state, "result", @result_fields[kind])
    end
  end

  defp check_object(state, key, fields) do
    case state[key] do
      nil -> :ok
      %{} = object -> check_fields(object, fields, "state." <> key)
      _other -> {:error, "state.#{key} must be an object"}
    end
  end

  defp check_fields(map, fields, prefix) do
    Enum.find_value(fields, :ok, fn {field, kind} ->
      value = Map.get(map, Atom.to_string(field))

      if is_nil(value) or kind?(kind, value),
        do: nil,
        else: {:error, "#{prefix}.#{field} must be #{article(kind)}"}
    end)
  end

  defp kind?(:string, value), do: is_binary(value)
  defp kind?(:integer, value), do: is_integer(value)

  defp article(:string), do: "a string"
  defp article(:integer), do: "an integer"
end

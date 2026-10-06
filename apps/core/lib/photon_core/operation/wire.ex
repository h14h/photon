defmodule PhotonCore.Operation.Wire do
  @moduledoc """
  The operation protocol's messages, built and parsed in this one place. They
  travel on a node's channel, `"node:<node_id>"`, as string-keyed JSON maps.

  Hub to node:

    * `op.start`: `id`, `kind`, `args`, `known`. Run this operation, or, if
      the node already has it, send its latest snapshot. `known` is true once
      the hub has seen a snapshot for it.
    * `op.cancel`: `id`. Stop the operation if it runs, and never start it.
    * `op.ack`: `id`. The hub has recorded the operation's result; the node
      may forget it.

  Node to hub:

    * `op.snapshot`: `op`, the operation's latest snapshot
      (`PhotonCore.Operation`). A terminal one is the result.
    * `op.output`: `id`, `stream` (`"out"` or `"err"`) and `text`, new
      command output. Never stored.

  Each builder returns `{event, payload}`, ready to push. Each parser takes a
  payload as it arrived and returns `{:ok, map}` with only the fields named
  here, or `{:error, reason}` when a field is missing or has the wrong type.
  Unknown fields are dropped, so either side can be updated first. Parsers
  check shapes, not meaning: `op.start` accepts any `kind` and any `args`
  map, and the node decides what it can run. Operation IDs must be safe as
  file names (`PhotonCore.ID.valid?/1`) and start with `op_`, since the node
  names a directory after each.

  `event/1` names each event, for handlers that match on it:

      @snapshot Wire.event(:snapshot)
      def handle_in(@snapshot, payload, socket), do: ...

  `docs/plans/step-1-machine-tools.md` (section 2) has the rules each side
  follows.
  """

  alias PhotonCore.{ID, Operation}

  @start "op.start"
  @cancel "op.cancel"
  @ack "op.ack"
  @snapshot "op.snapshot"
  @output "op.output"

  @streams ~w(out err)

  @typedoc "A message of the protocol."
  @type message :: :start | :cancel | :ack | :snapshot | :output

  @typedoc "An event name and its payload, ready to push."
  @type push :: {String.t(), map()}

  @doc "The event name of `message`."
  @spec event(message()) :: String.t()
  def event(:start), do: @start
  def event(:cancel), do: @cancel
  def event(:ack), do: @ack
  def event(:snapshot), do: @snapshot
  def event(:output), do: @output

  ## Builders

  @doc "`op.start`: run operation `id` of `kind` with `args`, or report it if the node has it."
  @spec start(String.t(), String.t(), map(), boolean()) :: push()
  def start(id, kind, args, known),
    do: {@start, %{"id" => id, "kind" => kind, "args" => args, "known" => known}}

  @doc "`op.cancel`: stop operation `id`, and never start it."
  @spec cancel(String.t()) :: push()
  def cancel(id), do: {@cancel, %{"id" => id}}

  @doc "`op.ack`: the hub has recorded operation `id`'s result."
  @spec ack(String.t()) :: push()
  def ack(id), do: {@ack, %{"id" => id}}

  @doc "`op.snapshot`: an operation's latest snapshot."
  @spec snapshot(Operation.t()) :: push()
  def snapshot(op), do: {@snapshot, %{"op" => op}}

  @doc ~S|`op.output`: new output on `stream` (`"out"` or `"err"`) of operation `id`.|
  @spec output(String.t(), String.t(), String.t()) :: push()
  def output(id, stream, text) when stream in @streams,
    do: {@output, %{"id" => id, "stream" => stream, "text" => text}}

  ## Parsers

  # The fields each message keeps, in the order they are checked, with what
  # each must be (`valid?/2`).
  @start_fields [id: :op_id, kind: :name, args: :object, known: :boolean]
  @id_fields [id: :op_id]
  @snapshot_fields [
    id: :op_id,
    type: :name,
    version: :positive,
    status: :status,
    max_output_length: :limit,
    state: :object
  ]
  @output_fields [id: :op_id, stream: :stream, text: :text]

  @doc ~S|Parses an `op.start` payload into `%{"id", "kind", "args", "known"}`.|
  @spec parse_start(term()) :: {:ok, map()} | {:error, String.t()}
  def parse_start(payload), do: take(payload, @start_fields, @start)

  @doc ~S|Parses an `op.cancel` or `op.ack` payload into `%{"id"}`.|
  @spec parse_id(term()) :: {:ok, map()} | {:error, String.t()}
  def parse_id(payload), do: take(payload, @id_fields, "op.cancel or op.ack")

  @doc """
  Parses an `op.snapshot` payload into the snapshot it carries, with only
  the fields of `PhotonCore.Operation`.
  """
  @spec parse_snapshot(term()) :: {:ok, Operation.t()} | {:error, String.t()}
  def parse_snapshot(%{"op" => op}) when is_map(op), do: take(op, @snapshot_fields, @snapshot)
  def parse_snapshot(_payload), do: {:error, "op.snapshot: op must be an object"}

  @doc ~S|Parses an `op.output` payload into `%{"id", "stream", "text"}`.|
  @spec parse_output(term()) :: {:ok, map()} | {:error, String.t()}
  def parse_output(payload), do: take(payload, @output_fields, @output)

  # The named fields of `payload`, each checked, or the first one that's wrong.
  defp take(payload, fields, event) when is_map(payload) do
    Enum.reduce_while(fields, {:ok, %{}}, fn {key, check}, {:ok, taken} ->
      key = Atom.to_string(key)
      value = Map.get(payload, key)

      if valid?(check, value),
        do: {:cont, {:ok, Map.put(taken, key, value)}},
        else: {:halt, {:error, "#{event}: #{key} must be #{expected(check)}"}}
    end)
  end

  defp take(_payload, _fields, event), do: {:error, "#{event}: the payload must be an object"}

  defp valid?(:op_id, value), do: ID.valid?(value) and String.starts_with?(value, "op_")
  defp valid?(:name, value), do: is_binary(value) and value != ""
  defp valid?(:object, value), do: is_map(value)
  defp valid?(:boolean, value), do: is_boolean(value)
  defp valid?(:positive, value), do: is_integer(value) and value > 0
  defp valid?(:limit, value), do: is_nil(value) or valid?(:positive, value)
  defp valid?(:status, value), do: value in Operation.statuses()
  defp valid?(:stream, value), do: value in @streams
  defp valid?(:text, value), do: is_binary(value)

  defp expected(:op_id), do: "an operation ID (op_ and up to 61 of [0-9A-Za-z_-])"
  defp expected(:name), do: "a string"
  defp expected(:object), do: "an object"
  defp expected(:boolean), do: "true or false"
  defp expected(:positive), do: "a positive integer"
  defp expected(:limit), do: "null or a positive integer"
  defp expected(:status), do: "one of " <> Enum.join(Operation.statuses(), ", ")
  defp expected(:stream), do: ~s("out" or "err")
  defp expected(:text), do: "a string"
end

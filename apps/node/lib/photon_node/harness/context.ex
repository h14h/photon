defmodule PhotonNode.Harness.Context do
  @moduledoc """
  Assembles model input in memory: pure, no I/O.

  Like unreal-agent's context builder, it keeps a committed prefix (what
  earlier turns sent, plus model responses) and a staged suffix (what arrived
  since the last turn started). `commit/1` moves the suffix into the prefix
  when a turn starts. Model responses join the prefix directly, ahead of
  anything staged, so input that arrived during a request comes after the
  response to it.

  A call that is still running when a turn starts shows a placeholder result.
  Its real result is appended later. If the placeholder was never sent it is
  replaced in place; otherwise both stay, as upstream does.

  `build/1` writes the shape model APIs expect, where a tool call's result
  must directly follow the assistant message that made it: each call's first
  result is placed there, and a later real result for an already-answered
  call goes in as a user message that says which call it belongs to.
  """

  # Functional core (see PhotonNode.Harness): no processes, no I/O.
  use Boundary, type: :strict, deps: [PhotonCore]

  alias PhotonCore.Message

  @placeholder "Tool call is still running. Its result arrives in a later turn: continue with independent work, or end your turn to wait for it."

  defstruct system: "", committed: [], staged: []

  @typedoc "A tool call's result: its call, the parts, and whether it is the placeholder."
  @type result :: %{
          call_id: String.t(),
          name: String.t(),
          parts: [Message.part()],
          placeholder: boolean()
        }

  @typedoc "A staged or committed item, newest first in each list."
  @type item :: {:user, [Message.part()]} | {:assistant, Message.t()} | {:result, result()}

  @type t :: %__MODULE__{system: String.t(), committed: [item()], staged: [item()]}

  @spec placeholder() :: String.t()
  def placeholder, do: @placeholder

  @spec new(String.t()) :: t()
  def new(system), do: %__MODULE__{system: system}

  @spec set_system(t(), String.t()) :: t()
  def set_system(ctx, system), do: %{ctx | system: system}

  @doc "Stages a user message (external input or heartbeat)."
  @spec add_user(t(), Message.content()) :: t()
  def add_user(ctx, content), do: stage(ctx, {:user, Message.parts(content)})

  @doc "Appends a model response to the committed prefix."
  @spec add_response(t(), Message.t()) :: t()
  def add_response(ctx, message), do: %{ctx | committed: [{:assistant, message} | ctx.committed]}

  @doc """
  Stages a tool result. A running call gets the placeholder. Any placeholder
  for the call still in the staged suffix is replaced.
  """
  @spec add_tool_result(t(), String.t(), String.t(), [Message.part()], boolean()) :: t()
  def add_tool_result(ctx, call_id, name, parts, running?) do
    parts = if running?, do: [Message.text(@placeholder)], else: parts

    staged =
      Enum.reject(ctx.staged, fn
        {:result, %{call_id: ^call_id, placeholder: true}} -> true
        _ -> false
      end)

    result = %{call_id: call_id, name: name, parts: parts, placeholder: running?}
    stage(%{ctx | staged: staged}, {:result, result})
  end

  @doc "Moves the staged suffix into the committed prefix (a turn started)."
  @spec commit(t()) :: t()
  def commit(ctx), do: %{ctx | committed: ctx.staged ++ ctx.committed, staged: []}

  defp stage(ctx, item), do: %{ctx | staged: [item | ctx.staged]}

  @doc "The messages for the next request."
  @spec build(t()) :: [Message.t()]
  def build(ctx) do
    items = Enum.reverse(ctx.committed) ++ Enum.reverse(ctx.staged)
    emit(Enum.with_index(items), MapSet.new(), MapSet.new(), [])
  end

  # Walks the items in order, building the messages newest first. `consumed`
  # holds the indexes of results already placed after their call;
  # `answered` the call IDs that have a result in place.
  defp emit([], _consumed, _answered, acc), do: Enum.reverse(acc)

  defp emit([{item, index} | rest], consumed, answered, acc) do
    if MapSet.member?(consumed, index),
      do: emit(rest, consumed, answered, acc),
      else: emit_item(item, rest, consumed, answered, acc)
  end

  defp emit_item({:user, parts}, rest, consumed, answered, acc),
    do: emit(rest, consumed, answered, [Message.user(parts) | acc])

  defp emit_item({:assistant, message}, rest, consumed, answered, acc) do
    {results, consumed, answered} = first_results(message, rest, consumed, answered)
    acc = [message | acc]
    emit(rest, consumed, answered, results ++ acc)
  end

  defp emit_item({:result, result}, rest, consumed, answered, acc) do
    if MapSet.member?(answered, result.call_id),
      do: emit(rest, consumed, answered, [late_result(result) | acc]),
      # A result whose call isn't in this context (it predates a fork).
      else: emit(rest, consumed, answered, acc)
  end

  defp late_result(%{call_id: call_id, name: name, parts: parts}) do
    text = "Result of the earlier #{name} tool call #{call_id}, which has now finished:"
    Message.user([Message.text(text) | parts])
  end

  # Each call's first result goes right after the assistant message that
  # made it: the first unconsumed one later in the items, or the
  # placeholder. Returns the results newest first.
  defp first_results(message, rest, consumed, answered) do
    Enum.reduce(Message.tool_calls(message), {[], consumed, answered}, fn call, acc ->
      first_result(call["id"], rest, acc)
    end)
  end

  defp first_result(id, rest, {results, consumed, answered}) do
    case find_result(id, rest, consumed) do
      {{:result, %{parts: parts}}, index} ->
        {[Message.tool_result(id, parts) | results], MapSet.put(consumed, index),
         MapSet.put(answered, id)}

      nil ->
        {[Message.tool_result(id, @placeholder) | results], consumed, MapSet.put(answered, id)}
    end
  end

  defp find_result(id, rest, consumed) do
    Enum.find(rest, fn {item, index} ->
      match?({:result, %{call_id: ^id}}, item) and not MapSet.member?(consumed, index)
    end)
  end
end

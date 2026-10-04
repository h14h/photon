defmodule Photon.Durable.ToolAPI do
  @moduledoc "What a running tool call can use: its task, conversation and call, and live output."

  alias Photon.Durable
  alias Photon.Durable.TaskRecord

  @enforce_keys [:task, :conversation_id, :call]
  defstruct [:task, :conversation_id, :call]

  @type t :: %__MODULE__{
          task: TaskRecord.t(),
          conversation_id: String.t(),
          call: PhotonCore.Message.tool_call()
        }

  @doc "The API for the call a tool task runs."
  @spec new(TaskRecord.t()) :: t()
  def new(%TaskRecord{} = task),
    do: %__MODULE__{task: task, conversation_id: task.conversation_id, call: task.input["call"]}

  @spec task_id(t()) :: String.t()
  def task_id(%__MODULE__{task: task}), do: task.id

  @spec call_id(t()) :: String.t() | nil
  def call_id(%__MODULE__{call: call}), do: call["id"]

  @doc """
  Streams running output to anyone watching. Not stored; the result is. A
  broadcast per call, with no acknowledgement, so a tool that streams a lot
  should send it in chunks.
  """
  @spec output(t(), String.t()) :: :ok
  def output(%__MODULE__{} = api, text) do
    Durable.live(api.conversation_id, %{
      "type" => "tool_output",
      "call_id" => call_id(api),
      "text" => text
    })
  end

  @doc "Commits side effects of the call (see `Photon.Durable.Store.commit/1`)."
  @spec commit(t(), (Durable.Tx.t() -> result)) :: result | {:rolled_back, term()}
        when result: term()
  def commit(%__MODULE__{}, fun), do: Durable.commit(fun)
end

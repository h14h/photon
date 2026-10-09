defmodule Photon.Threads.Titling do
  @moduledoc """
  The `"thread_title"` task: names a thread once its first run has ended.

  `Photon.Threads.start/2` creates it in the commit that starts the
  thread, as background work waiting on the thread's first run, so it
  never holds the thread up or counts as the thread running. Its input
  holds the thread's first title (`"fallback"`) and the start of its first
  message (`"message"`).

  When the run ends (answered, failed or stopped), its one step asks the
  model in Settings for a short title, through the client every
  conversation uses (`Photon.ChatGPT`; the scripted `Photon.Threads.MockTitle`
  with `PHOTON_MOCK_MODEL=1`), with the start of the first message and the
  first answer (`Photon.Threads.Rules.title_request/2`). It is one small
  request: low reasoning, no tools and no retries. A step that runs again
  after a hub restart doesn't ask again. If the request fails, or what
  comes back doesn't read as a title (`Rules.model_title/1`), the thread
  keeps its first title.

  The title is stored with `Photon.Threads.titled_tx/4`, which leaves a
  title the owner gave the thread meanwhile alone, and announces the
  change so the pages update.
  """

  @behaviour Photon.Durable.TaskKind

  require Logger

  alias Photon.{ChatGPT, Settings, Threads}
  alias Photon.Durable.{Runtime, TaskRecord}
  alias Photon.Threads.{MockTitle, Rules}
  alias PhotonCore.Message

  @kind "thread_title"

  @doc "The task's kind, as registered with `Photon.Durable`."
  @spec kind() :: String.t()
  def kind, do: @kind

  @doc """
  The task for a thread whose first title is `fallback`, started by
  `message`, waiting on its first run `run_id`.
  """
  @spec task(String.t(), String.t(), String.t(), String.t()) :: map()
  def task(thread_id, run_id, fallback, message) do
    %{
      kind: @kind,
      conversation_id: thread_id,
      background: true,
      phase: "title",
      waiting: %{"on" => [run_id]},
      input: %{"fallback" => fallback, "message" => String.slice(message, 0, 4_000)}
    }
  end

  @impl true
  def step("title", %TaskRecord{runs: 1} = task, runtime) do
    title = ask(task)
    fallback = task.input["fallback"]
    Runtime.commit(runtime, &done(&1, task.conversation_id, fallback, title))
  end

  # Run again after a restart: one request is all a title gets.
  def step("title", task, runtime),
    do: Runtime.commit(runtime, &done(&1, task.conversation_id, task.input["fallback"], nil))

  defp done(tx, thread_id, fallback, title) do
    :ok = Threads.titled_tx(tx, thread_id, fallback, title)
    {:done, %{"title" => title}}
  end

  # The model's title, or nil when there's none to use.
  defp ask(task) do
    settings = Settings.load()

    request =
      task.input["message"]
      |> Rules.title_request(Threads.latest_answer(task.conversation_id))
      |> Map.merge(%{model: Settings.model(settings), reasoning: "low"})

    config = MockTitle |> ChatGPT.llm_config() |> Map.put(:max_attempts, 1)

    with {:ok, %{"message" => message}} <- ChatGPT.stream(request, config, fn _event -> :ok end),
         {:ok, title} <- message |> Message.text_of() |> Rules.model_title() do
      title
    else
      {:error, error} ->
        Logger.info("No title for thread #{task.conversation_id}: #{Exception.message(error)}")
        nil

      _not_a_title ->
        nil
    end
  end
end

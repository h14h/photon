defmodule Photon.Assistant do
  @moduledoc """
  The assistant that lives on the hub: one long-running conversation the
  user talks to in the web UI, run by `Photon.Durable`.

  It doesn't run commands itself. It hands work to nodes, each of which runs
  its own agent (`PhotonNode.Harness`), and keeps a memory, a list of
  schedules, and an eye on everything it started. Node work is
  asynchronous: a `run_on_node` call waits briefly for the answer, and if the
  work takes longer, a background watcher (`Photon.Assistant.NodeWatch`)
  posts the node's report into the conversation when it finishes, which
  wakes the assistant.

  This module is the assistant's API, which the web pages use, and its
  `Photon.Durable.Profile`. Behind it, by layer:

    * functional core (pure): `Photon.Assistant.Prompt` (system prompt and
      model settings), `Photon.Assistant.Memory`, `Photon.Assistant.Report`
      (how node work's outcome reads), `Photon.Assistant.Transcript` (what
      the page shows), `Photon.Assistant.MockScript` (the mock model)
    * boundary: the tools in `Photon.Assistant.Tools`, and
      `Photon.Assistant.NodeWork`, what the node tools share
    * workers: the task kinds `Photon.Assistant.NodeWatch` and
      `Photon.Assistant.Routine`, run by the durable scheduler
  """

  use Boundary,
    deps: [
      Photon.ChatGPT,
      Photon.Durable,
      Photon.NodeSessions,
      Photon.Nodes,
      Photon.Settings,
      PhotonCore,
      PhotonCore.LLM
    ],
    exports: [Notice, Page, Transcript]

  @behaviour Photon.Durable.Profile

  alias Photon.Assistant.{Memory, Page, Prompt, Tools}
  alias Photon.{Durable, Settings}
  alias Photon.Durable.{Entry, Submission, TaskRecord}

  @tools [
    Tools.ListNodes,
    Tools.RunOnNode,
    Tools.MessageNodeSession,
    Tools.CheckNodeSession,
    Tools.StopNodeSession,
    Tools.UpdateMemory,
    Tools.Schedule,
    Tools.ListSchedules,
    Tools.CancelSchedule
  ]

  @doc "The assistant's conversation, created on first use."
  @spec conversation_id() :: String.t()
  def conversation_id do
    case Durable.doc("global", "assistant") do
      %{"conversation_id" => id} -> id
      _ -> Durable.commit(&ensure_conversation/1)
    end
  end

  # Inside the commit, so two first uses still make one conversation.
  defp ensure_conversation(tx) do
    case Durable.Tx.get_doc(tx, "global", "assistant") do
      %{"conversation_id" => id} ->
        id

      _ ->
        conversation =
          Durable.Tx.create_conversation(tx, %{profile: "assistant", title: "Assistant"})

        _doc =
          Durable.Tx.put_doc(tx, "global", "assistant", %{"conversation_id" => conversation.id})

        conversation.id
    end
  end

  @doc """
  Sends the user's message. With `page:` (a `Photon.Assistant.Page`), the
  model sees a note of the page the user had open in front of it. Other
  options are `Photon.Durable.submit/3`'s.
  """
  @spec send(String.t(), keyword()) :: {:ok, Submission.t()} | {:error, :busy}
  def send(text, opts \\ []) do
    {page, opts} = Keyword.pop(opts, :page)
    source = if page, do: %{"kind" => "user", "page" => page}, else: %{"kind" => "user"}

    Durable.submit(
      conversation_id(),
      Page.note(text, page),
      Keyword.put_new(opts, :source, source)
    )
  end

  @doc """
  Stops the current run and withdraws the user's queued messages. Reports
  from node work and scheduled prompts that are waiting stay, since they
  come from background work the stop leaves running.
  """
  @spec stop() :: :ok
  def stop do
    _run = Durable.abort(conversation_id(), withdraw: &(not background_input?(&1)))
    :ok
  end

  @doc false
  # Input from the assistant's own background work, which a stop keeps.
  @spec background_input?(Submission.t()) :: boolean()
  def background_input?(submission),
    do: get_in(submission.content, ["source", "kind"]) in ["node_report", "routine"]

  @spec memory() :: String.t()
  def memory, do: Durable.doc("global", "memory", Memory.empty())["text"]

  @spec put_memory(String.t()) :: :ok
  def put_memory(text) do
    _memory = Durable.put_doc("global", "memory", Memory.replace(text))
    :ok
  end

  @doc "Scheduled routines that haven't finished."
  @spec schedules() :: [TaskRecord.t()]
  def schedules, do: Durable.live_tasks("routine")

  @doc "Cancels a scheduled routine (the web page's cancel button)."
  @spec cancel_schedule(String.t()) :: :ok
  def cancel_schedule(id) do
    _routine = Durable.abort_task(id, background: true)
    :ok
  end

  ## The conversation, for the web pages

  @doc """
  Subscribes to the conversation (`{:durable, id, changes}` and
  `{:live, id, event}`) and to global changes (`{:durable, "global",
  changes}` for memory, `{:durable_tasks, tasks}` for schedules); see
  `Photon.Durable.subscribe/1`.
  """
  @spec subscribe(String.t()) :: :ok
  def subscribe(conversation_id), do: Durable.subscribe(conversation_id)

  @doc "Subscribes to task changes, `{:durable_tasks, tasks}`, and global docs."
  @spec subscribe_tasks() :: :ok
  def subscribe_tasks, do: Durable.subscribe_global()

  @doc "The conversation's entries, in order."
  @spec entries(String.t()) :: [Entry.t()]
  def entries(conversation_id), do: Durable.entries(conversation_id)

  @doc "Whether the assistant is working on something."
  @spec busy?(String.t()) :: boolean()
  def busy?(conversation_id), do: Durable.busy?(conversation_id)

  @doc "Messages waiting for the current run, oldest first."
  @spec queued(String.t()) :: [Submission.t()]
  def queued(conversation_id), do: Durable.queued(conversation_id)

  @doc "Withdraws a waiting message."
  @spec withdraw(String.t()) :: :ok
  def withdraw(submission_id) do
    _submission = Durable.withdraw(submission_id)
    :ok
  end

  @doc "Starts a fresh context; earlier messages stay but the model stops seeing them."
  @spec fresh_start(String.t()) :: :ok
  def fresh_start(conversation_id) do
    _reset = Durable.reset(conversation_id)
    :ok
  end

  ## Profile

  @impl true
  def llm(conversation) do
    settings = Settings.load()

    %{
      config: Photon.ChatGPT.llm_config(Photon.Assistant.MockScript),
      stream: &Photon.ChatGPT.stream/3,
      model: Settings.model(settings),
      reasoning: Prompt.reasoning(settings),
      cache_key: conversation.id
    }
  end

  @impl true
  def tools(_conversation), do: @tools

  @impl true
  def system_prompt(_conversation) do
    settings = Settings.load()
    now = DateTime.utc_now()
    Prompt.system_prompt(settings, memory(), now)
  end
end

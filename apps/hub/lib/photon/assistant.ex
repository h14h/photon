# This module is two things on purpose, as `Photon.Threads` is: the
# assistant context's API, which the web pages use, and the `"assistant"`
# profile. The profile alone reaches the model, Settings, the machine
# tools, skills and the prompt, and splitting it out would only move the
# same calls behind a facade.
# credo:disable-for-next-line Credo.Check.Refactor.ModuleDependencies
defmodule Photon.Assistant do
  @moduledoc """
  The assistant that lives on the hub: one long-running conversation the
  user talks to in the web UI, run by `Photon.Durable`.

  It runs commands and looks at images on the user's machines itself, with
  the machine tools (`Photon.MachineTools`: `shell`, `view_image`,
  `list_machines`), keeps a memory, and keeps schedules of its own in
  `Photon.Schedules`, which post into its conversation. Its prompt
  lists the skills turned on for Blip (`Photon.Skills`), and `load_skill`
  loads one. It sees every project and thread with its read tools
  (`list_projects`, `read_project`, `list_threads`, `read_thread`),
  which find what they name through `find_project/1` and `find_thread/1`
  and put their texts together in `Photon.Assistant.Readout`. It starts
  projects and threads, messages threads and stops them
  (`start_project`, `start_thread`, `message_thread`, `stop_thread`),
  each inside the commit that records its result. It lists, reads, writes
  and edits any project's context files (`list_context_files`,
  `read_context_file`, `write_context_file`, `edit_context_file`), which
  read through `Photon.Threads.describe_files/2` and `read_file_text/3`
  as a thread's file tools do, and write as `"blip"` through
  `Photon.Projects`.

  Who asked for a run is read from the sources of the messages it
  answers (`origin_tx/2`, `Photon.Assistant.Origin`): the owner, a
  schedule, Blip's own follow-up on a thread update, or a thread's
  `ask_blip` question. A run that carries a question the owner hasn't
  written into can't start, wake or stop work or change a project's
  files, and between two of the
  owner's messages Blip can start or message threads only
  `unattended_limit/0` times on its own (`may_act_tx/3`), so a loop
  between Blip and a thread stops in code.

  This module is the assistant's API, which the web pages use, and its
  `Photon.Durable.Profile`. Behind it, by layer:

    * functional core (pure): `Photon.Assistant.Prompt` (the system
      prompt), `Photon.Assistant.Memory`, `Photon.Assistant.Page` (the
      page the user has open, and the note of it the model sees),
      `Photon.Assistant.Notice` (what Blip says unasked),
      `Photon.Assistant.Readout` (what the read tools say),
      `Photon.Assistant.Origin` (who asked for a run, and what it may do),
      `Photon.Assistant.MockScript` and `Photon.Assistant.MockCoordinator`
      (the mock model)
    * boundary: the tools in `Photon.Assistant.Tools`; the machine tools
      are their own context, `Photon.MachineTools`
    * workers: none of its own; Blip's schedules fire through the
      `"routine"` task kind, `Photon.Schedules.Routine`

  Blip floats over every page, so it knows which project, context file or
  thread is on screen: `page_at/1` makes the page from its path, and
  `send/2` with `page:` reads the page's facts through `Photon.Projects`
  and `Photon.Threads` and puts a note of them in front of the message.
  """

  use Boundary,
    deps: [
      Photon.ChatGPT,
      Photon.Durable,
      Photon.MachineTools,
      Photon.Projects,
      Photon.Schedules,
      Photon.Settings,
      Photon.Signals,
      Photon.Skills,
      Photon.Threads,
      Photon.Transcript,
      PhotonCore,
      PhotonCore.LLM
    ],
    exports: [Notice]

  @behaviour Photon.Durable.Profile

  alias Photon.Assistant.{Memory, Origin, Page, Prompt, Readout, Tools}

  alias Photon.{
    Durable,
    MachineTools,
    Projects,
    Schedules,
    Settings,
    Signals,
    Skills,
    Threads,
    Transcript
  }

  alias Photon.Durable.{Entry, Submission, TaskRecord, Tx}
  alias Photon.Projects.Project
  alias Photon.Threads.Thread
  alias PhotonCore.Message

  @tools [
    Tools.UpdateMemory,
    Tools.Schedule,
    Tools.ListSchedules,
    Tools.CancelSchedule,
    Tools.LoadSkill,
    Tools.ListProjects,
    Tools.ReadProject,
    Tools.ListThreads,
    Tools.ReadThread,
    Tools.StartProject,
    Tools.StartThread,
    Tools.MessageThread,
    Tools.StopThread,
    Tools.ListContextFiles,
    Tools.ReadContextFile,
    Tools.WriteContextFile,
    Tools.EditContextFile
  ]

  # The tools that start or wake threads, which the unattended limit counts.
  @unattended_tools ~w(start_thread message_thread)

  # The source kinds of a message from the owner, which end an unattended
  # stretch: what they typed, and their answer to a question.
  @owner_kinds ~w(user answer)

  # How many times Blip may start or message threads between two of the
  # owner's messages, when the config doesn't say (section 5.4).
  @unattended_limit 10

  @doc """
  The assistant's conversation, created on first use. `Photon.Signals`
  owns finding it, since threads post into it too.
  """
  @spec conversation_id() :: String.t()
  defdelegate conversation_id, to: Signals, as: :blip_conversation_id

  @doc """
  Sends the user's message. With `page:` (from `page_at/1`), the page's
  facts are read now and the message goes as two text parts, the note of
  the page (`Photon.Assistant.Page.note/2`) and then `text`, with the page,
  as it is now, in its `source`. The conversation shows only `text`
  (`Photon.Transcript.typed/2`). A page whose project is gone is left out.
  Other options are `Photon.Durable.submit/3`'s.
  """
  @spec send(String.t(), keyword()) :: {:ok, Submission.t()} | {:error, :busy}
  def send(text, opts \\ []) do
    {page, opts} = Keyword.pop(opts, :page)
    {content, source} = with_page(text, page && page_now(page))
    Durable.submit(conversation_id(), content, Keyword.put_new(opts, :source, source))
  end

  defp with_page(text, nil), do: {text, %{"kind" => "user"}}

  defp with_page(text, {page, facts}),
    do:
      {[Message.text(Page.note(page, facts)), Message.text(text)],
       %{"kind" => "user", "page" => page}}

  ## The page under Blip

  @doc """
  The page at `path` (`Photon.Assistant.Page.t/0`), when it is inside a
  project: the project's page, a context file's or a thread's. Nil for any
  other path, and for a project, file or thread that doesn't exist (a
  thread under another project's slug included).
  """
  @spec page_at(String.t()) :: Page.t() | nil
  def page_at(path) do
    case Page.at(path) do
      nil ->
        nil

      {:project, slug} ->
        with %Project{} = p <- Projects.get_by_slug(slug), do: Page.of_project(p)

      {:file, slug, name} ->
        file_page(slug, name)

      {:thread, slug, id} ->
        thread_page(slug, id)
    end
  end

  defp file_page(slug, name) do
    with %Project{} = project <- Projects.get_by_slug(slug),
         %{name: name} <- Projects.get_file(project.id, name) do
      Page.of_file(project, name)
    end
  end

  defp thread_page(slug, id) do
    with %Project{} = project <- Projects.get_by_slug(slug),
         %{project_id: project_id} = thread when project_id == project.id <- Threads.get(id) do
      Page.of_thread(project, thread)
    else
      _missing -> nil
    end
  end

  # The page as it is at send time, with its facts, or nil when its project
  # is gone. The project's name or the thread's title may have changed
  # since the page was read, so the page is made again.
  defp page_now(%{"project_id" => project_id} = page) do
    case Projects.get(project_id) do
      nil -> nil
      project -> page_now(page, project, project_facts(project))
    end
  end

  defp page_now(%{"kind" => "file", "file" => name}, project, facts) do
    file = Projects.get_file(project.id, name)
    file_facts = file && %{content: file.content}
    {Page.of_file(project, (file && file.name) || name), Map.put(facts, :file, file_facts)}
  end

  defp page_now(%{"kind" => "thread", "thread_id" => id}, project, facts) do
    case Enum.find(facts.threads, &(&1.id == id)) do
      nil ->
        {Page.of_project(project), facts}

      thread ->
        state = %{running?: thread.running?, answer: Threads.latest_answer(id)}
        {Page.of_thread(project, thread), Map.put(facts, :thread, state)}
    end
  end

  defp page_now(_page, project, facts), do: {Page.of_project(project), facts}

  defp project_facts(project) do
    threads = Threads.list(project.id)
    running = Threads.running(Enum.map(threads, & &1.id))

    %{
      purpose: project.purpose,
      files: Enum.map(Projects.list_files(project.id), & &1.name),
      threads:
        Enum.map(
          threads,
          &%{id: &1.id, title: &1.title, running?: MapSet.member?(running, &1.id)}
        )
    }
  end

  ## Finding what Blip's tools name

  @doc """
  The project a tool's `project` argument names: its slug, or its ID.
  Otherwise an error that lists the projects there are
  (`Photon.Assistant.Readout.unknown_project/2`).
  """
  @spec find_project(String.t()) :: {:ok, Project.t()} | {:error, String.t()}
  def find_project(name) do
    name = String.trim(name)

    case Projects.get_by_slug(name) || Projects.get(name) do
      %Project{} = project ->
        {:ok, project}

      nil ->
        {:error, Readout.unknown_project(name, Enum.map(Projects.list(), & &1.slug))}
    end
  end

  @doc """
  The thread a tool's `thread` argument names, by its ID. Otherwise an
  error that points Blip to `list_threads`.
  """
  @spec find_thread(String.t()) :: {:ok, Thread.t()} | {:error, String.t()}
  def find_thread(id) do
    id = String.trim(id)

    case Threads.get(id) do
      %Thread{} = thread -> {:ok, thread}
      nil -> {:error, Readout.unknown_thread(id)}
    end
  end

  ## Who asked, and what a run may do

  @doc """
  Who asked for the run `task` belongs to (`Photon.Assistant.Origin.of/1`),
  from the sources of the submissions its generation answers, read
  inside the caller's commit. `task` is the generation or one of its tool
  calls. Total, since the activity log's hooks call it on the harness's
  abort and fail paths: a missing task or submission is left out, and no
  sources make `by: "unknown"`.
  """
  @spec origin_tx(Tx.t(), TaskRecord.t() | nil) :: Origin.t()
  def origin_tx(tx, task) do
    sources =
      case generation_tx(tx, task) do
        %TaskRecord{checkpoint: %{"submissions" => ids}} when is_list(ids) ->
          for id <- ids, is_binary(id), %Submission{} = s <- [Tx.get_submission(tx, id)] do
            s.content["source"]
          end

        _none ->
          []
      end

    Origin.of(sources)
  end

  defp generation_tx(_tx, %TaskRecord{kind: "generation"} = task), do: task

  defp generation_tx(tx, %TaskRecord{owner_task_id: id}) when is_binary(id),
    do: Tx.get_task(tx, id)

  defp generation_tx(_tx, _task), do: nil

  @doc """
  How many times Blip has started or messaged a thread (ok
  `start_thread` and `message_thread` results) since the owner last
  wrote to it (a message they typed, or their answer to a question),
  inside the caller's commit. One query.
  """
  @spec unattended_count_tx(Tx.t()) :: non_neg_integer()
  def unattended_count_tx(tx) do
    blip = Signals.blip_conversation_tx(tx)
    Tx.count_tool_results_since(tx, blip, @unattended_tools, @owner_kinds)
  end

  @doc """
  How many times Blip may start or message threads on its own between
  two of the owner's messages (`config :photon, Photon.Assistant,
  unattended_limit: 10`).
  """
  @spec unattended_limit() :: non_neg_integer()
  def unattended_limit,
    do: Application.get_env(:photon, __MODULE__, [])[:unattended_limit] || @unattended_limit

  @doc """
  Whether Blip's tool call `task` may act, inside the commit that records
  its result: `:change` for the tools that change a project or stop or
  schedule work, which a thread's question forbids (`restricted?`);
  `:start` for the tools that start or wake a thread, which the
  unattended limit bounds too. `:ok`, or `{:error, message}` for the
  model.
  """
  @spec may_act_tx(Tx.t(), TaskRecord.t(), :change | :start) :: :ok | {:error, String.t()}
  def may_act_tx(tx, task, kind) do
    origin = origin_tx(tx, task)

    cond do
      origin.restricted? ->
        {:error, Origin.restricted_message()}

      kind == :start and
          not Origin.unattended_ok?(origin, unattended_count_tx(tx), unattended_limit()) ->
        {:error, Origin.unattended_message(unattended_limit())}

      true ->
        :ok
    end
  end

  @doc """
  Stops the current run and withdraws the user's queued messages.
  Background input that is waiting stays
  (`Photon.Durable.Submission.background?/1`: scheduled prompts, signals
  from threads (`Photon.Signals`) and relayed answers), since the work
  that sent it keeps going.
  """
  @spec stop() :: :ok
  def stop do
    _run = Durable.abort(conversation_id(), withdraw: &(not Submission.background?(&1)))
    :ok
  end

  @spec memory() :: String.t()
  def memory, do: Durable.doc("global", "memory", Memory.empty())["text"]

  @spec put_memory(String.t()) :: :ok
  def put_memory(text) do
    _memory = Durable.put_doc("global", "memory", Memory.replace(text))
    :ok
  end

  @doc """
  Blip's own schedules that are waiting for their next time, soonest
  first, then any that stopped after an error, with why
  (`Photon.Schedules.list/1`), for the home page and Blip's
  `list_schedules`: a stopped one stays in sight until it is cancelled.
  One-offs that fired are left out. A project's schedules are on its page.
  """
  @spec schedules() :: [Schedules.listed()]
  def schedules, do: Enum.reject(Schedules.list(:blip), &(&1.state == :done))

  @doc """
  Deletes one of Blip's schedules (the home page's cancel button). A
  project's schedule, or one already gone, is `{:error, :not_found}`.
  """
  @spec cancel_schedule(String.t()) :: :ok | {:error, :not_found}
  def cancel_schedule(id), do: Durable.commit(&Schedules.delete_tx(&1, id, :blip))

  ## The conversation, for the web pages

  @doc """
  Subscribes to the conversation (`{:durable, id, changes}` and
  `{:live, id, event}`); see `Photon.Durable.subscribe/1`. Blip's
  schedules announce on `Photon.Schedules.subscribe/0`.
  """
  @spec subscribe(String.t()) :: :ok
  def subscribe(conversation_id), do: Durable.subscribe(conversation_id)

  @doc "Subscribes to task changes, `{:durable_tasks, tasks}`, and global docs."
  @spec subscribe_tasks() :: :ok
  def subscribe_tasks, do: Durable.subscribe_global()

  @doc "The conversation's entries, in order."
  @spec entries(String.t()) :: [Entry.t()]
  def entries(conversation_id), do: Durable.entries(conversation_id)

  @doc """
  The image at `index` among a tool result's images in the assistant's
  conversation, for the page to load on its own (`Transcript.image/2`):
  `{:ok, mime, bytes}`, or `:error` if there is no such entry or image.
  """
  @spec image(String.t(), non_neg_integer()) :: {:ok, String.t(), binary()} | :error
  def image(entry_id, index) do
    case Durable.entry(conversation_id(), entry_id) do
      nil -> :error
      entry -> Transcript.image(entry, index)
    end
  end

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
      # Blip searches the web itself (OpenAI runs the search), rather than
      # sending a machine to look something up. The scripted model ignores it.
      config:
        Photon.Assistant.MockScript
        |> Photon.ChatGPT.llm_config()
        |> Map.put(:hosted_tools, [%{"type" => "web_search"}]),
      stream: &Photon.ChatGPT.stream/3,
      model: Settings.model(settings),
      reasoning: Settings.reasoning(settings),
      cache_key: conversation.id
    }
  end

  @impl true
  def tools(_conversation), do: MachineTools.tools() ++ @tools

  @impl true
  def system_prompt(_conversation) do
    settings = Settings.load()
    now = DateTime.utc_now()
    Prompt.system_prompt(settings, memory(), now, Skills.enabled(:blip))
  end
end

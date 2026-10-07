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
  `list_machines`), keeps a memory, and keeps schedules in
  `Photon.Schedules`: its own, which post into its conversation, and
  projects', which start or wake threads (`schedule`, `list_schedules`,
  `cancel_schedule`). Its prompt lists the skills turned on for Blip and
  for each machine (`Photon.Skills.offered/1`), and `load_skill` loads
  one; `list_skills` and `set_project_skill` show every skill and turn
  one on or off for a project. It sees every project and thread with its read tools
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

  It handles the threads' `ask_blip` questions (`Photon.Questions`),
  which reach it as signals: it answers one from what it knows
  (`answer_question`), or asks the owner in its own words (`ask_owner`).
  The owner answers from Blip's panel through `answer/2`, and the answer
  goes straight to the thread.

  Who asked for a run is read from the sources of the messages it
  answers (`origin_tx/2`, `Photon.Assistant.Origin`): the owner, a
  schedule, Blip's own follow-up on a thread update, or a thread's
  `ask_blip` question. A run that carries a question the owner hasn't
  written into can't start, wake, stop or schedule work or change a
  project. Between two of the owner's messages Blip can start or message
  threads only `unattended_limit/0` times in runs the owner didn't type
  into, and it sets up a project's schedule only in a run the owner typed
  into (`may_act_tx/3`), so a loop between Blip and a thread stops in
  code. In ambient mode a run started by a digest or a daily review only
  reports until the owner types into it: the tools that start or change
  work refuse, so a digest can't cause the next one. Its prompt gains a
  section on digests and reviews only while ambient mode is on
  (`Photon.Signals.mode/0`), and an answer of `[nothing to tell]`
  (`Photon.Transcript.nothing_to_tell?/1`) makes no activity row.

  Everything Blip does goes in the activity log (`Photon.Activity`), from
  the profile's two hooks: `on_tool_result/4` records each tool call's
  result with who asked for it, and `on_settled/3` records what Blip told
  the owner in a run they didn't type into.

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
      Photon.Activity,
      Photon.Ambient,
      Photon.ChatGPT,
      Photon.Durable,
      Photon.MachineTools,
      Photon.Projects,
      Photon.Questions,
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
    Activity,
    Ambient,
    Durable,
    MachineTools,
    Projects,
    Questions,
    Schedules,
    Settings,
    Signals,
    Skills,
    Threads,
    Transcript
  }

  alias Photon.Durable.{Entry, Submission, TaskRecord, Tx}
  alias Photon.Projects.Project
  alias Photon.Questions.Question
  alias Photon.Questions.Rules, as: QuestionRules
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
    Tools.EditContextFile,
    Tools.AnswerQuestion,
    Tools.AskOwner,
    Tools.ListSkills,
    Tools.SetProjectSkill
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

  ## Questions

  @doc """
  The owner's answer to question `question_id`, from the reply chip in
  Blip's panel (`Photon.Questions.answer/2`): the thread gets it
  unchanged, and Blip gets it as a message of its own. A refusal is the
  owner's words for it, to show as it is.
  """
  @spec answer(String.t(), String.t()) :: {:ok, Question.t()} | {:error, String.t()}
  def answer(question_id, text), do: Questions.answer(question_id, text)

  @doc """
  Why Blip's `answer_question` or `ask_owner` on question `id` was
  refused, in Blip's words (`Photon.Questions.Rules.message/3`). An
  unknown ID lists the questions that are open
  (`Photon.Assistant.Readout.unknown_question/2`), so Blip can pick the
  right one. Read inside the tool's commit.
  """
  @spec question_refusal(Questions.reason(), String.t()) :: String.t()
  def question_refusal(:not_found, id), do: Readout.unknown_question(id, Questions.open())
  def question_refusal(reason, id), do: QuestionRules.message(reason, :blip, Questions.get(id))

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
  How many times Blip has started or messaged a thread on its own (ok
  `start_thread` and `message_thread` results marked unattended, from
  runs the owner didn't type into) since the owner last wrote to it (a
  message they typed, or their answer to a question), inside the
  caller's commit. One query.
  """
  @spec unattended_count_tx(Tx.t()) :: non_neg_integer()
  def unattended_count_tx(tx) do
    blip = Signals.blip_conversation_tx(tx)
    Tx.count_tool_results_since(tx, blip, @unattended_tools, @owner_kinds, "unattended")
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
  its result. A run that only reports (`report_only?`: a digest or daily
  review the owner hasn't typed into) refuses every kind. Otherwise:

    * `:change` for the tools that change a project or stop or schedule
      work, which a thread's question forbids (`restricted?`)
    * `:start` for the tools that start or wake a thread, which the
      unattended limit bounds too
    * `:schedule_work` for a project's schedule, which also needs the
      owner to have typed into the run (`Origin.schedule_work_ok?/1`)

  `{:ok, origin}`, the run's origin (`origin_tx/2`), or `{:error,
  message}` for the model.
  """
  @spec may_act_tx(Tx.t(), TaskRecord.t(), :change | :start | :schedule_work) ::
          {:ok, Origin.t()} | {:error, String.t()}
  def may_act_tx(tx, task, kind) do
    origin = origin_tx(tx, task)

    cond do
      origin.restricted? ->
        {:error, Origin.restricted_message()}

      origin.report_only? ->
        {:error, Origin.report_only_message()}

      kind == :schedule_work and not Origin.schedule_work_ok?(origin) ->
        {:error, Origin.schedule_work_message()}

      kind == :start and
          not Origin.unattended_ok?(origin, unattended_count_tx(tx), unattended_limit()) ->
        {:error, Origin.unattended_message(unattended_limit())}

      true ->
        {:ok, origin}
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
  A project's schedules as Blip's `read_project` and `list_schedules`
  show them (`Photon.Assistant.Readout.schedule/0`): those waiting for
  their next time, soonest first, then any that stopped after an error.
  One-offs that fired are left out, as `schedules/0` leaves out Blip's.
  """
  @spec project_schedules(String.t()) :: [Readout.schedule()]
  def project_schedules(project_id) do
    for %{state: state} = listed when state != :done <- Schedules.list({:project, project_id}) do
      schedule = listed.schedule

      %{
        id: schedule.id,
        when: Schedules.when_text(schedule),
        state: state,
        next_at: listed.next_at,
        prompt: schedule.prompt,
        thread_id: schedule.conversation_id
      }
    end
  end

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

  @doc """
  Withdraws a waiting message, in one commit with what that means for a
  digest or a daily review (`Photon.Ambient.withdrawn_tx/2`: its items
  go, its threads lose their review mark).
  """
  @spec withdraw(String.t()) :: :ok
  def withdraw(submission_id) do
    Durable.commit(fn tx ->
      case Durable.withdraw_tx(tx, submission_id) do
        %Submission{status: "withdrawn"} = submission -> Ambient.withdrawn_tx(tx, submission)
        _not_withdrawn -> :ok
      end
    end)
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
    ambient? = Signals.mode() == :ambient
    Prompt.system_prompt(settings, memory(), now, Skills.offered(:blip), ambient?)
  end

  ## The activity log's hooks

  # Both run inside the harness's commits, on a Stop or a failed task
  # inside the Scheduler's own, so they are total: `origin_tx/2`,
  # `Origin.for_call/3` and `Activity.record_tx/2` take what they are given
  # as it is, and a missing row records less (section 3.1).

  @doc """
  Records the activity row for one of Blip's tool calls, with who asked
  for it (`Photon.Assistant.Origin.for_call/3`: a call that handles a
  thread's question is that thread's), in the commit that stores its
  result, whatever ended the call.
  """
  @impl true
  def on_tool_result(_conversation, task, entry, tx) do
    call = stored_call(task)
    origin = Origin.for_call(origin_tx(tx, task), call["name"], call["arguments"])
    Activity.record_tx(tx, %{kind: "call", task: task, entry: entry, origin: origin})
  end

  # The call as the model sent it, from its tool task.
  defp stored_call(%TaskRecord{input: %{"call" => call}}) when is_map(call), do: call
  defp stored_call(_task), do: %{}

  @doc """
  Records a message row when one of Blip's runs that the owner didn't
  type into (a thread's update, a schedule, its own follow-up) ends a
  model turn with an answer that has text: the owner didn't watch that
  reply come in, so the activity page shows it. Runs the owner wrote
  to, runs that only handle threads' questions (their calls already say
  what Blip did, and the reply isn't for the owner), answers with no
  text, and an answer of `[nothing to tell]` to a digest or review
  (`Photon.Transcript.nothing_to_tell?/1`) record nothing.

  First, in the same commit, a settled digest or review is used up or
  given back (`Photon.Ambient.settled_tx/2`): a digest's items go once
  Blip has read it, and wait for the next digest when its run failed.
  """
  @impl true
  def on_settled(conversation, settled, tx) do
    :ok = Ambient.settled_tx(tx, settled)
    settled_tx(tx, conversation, settled)
  end

  defp settled_tx(tx, conversation, %{outcome: "done", answer_entry_id: entry_id} = settled)
       when is_binary(entry_id) do
    with %{by: by, quiet?: false} = origin when by != "owner" <-
           origin_tx(tx, Map.get(settled, :task)),
         text when is_binary(text) <- told(conversation.id, entry_id) do
      Activity.record_tx(tx, %{kind: "message", entry_id: entry_id, text: text, origin: origin})
    else
      _owner_or_nothing_told -> :ok
    end
  end

  defp settled_tx(_tx, _conversation, _settled), do: :ok

  # What Blip's answer `entry_id` told the owner: its text, or nil when it
  # has none or is `[nothing to tell]`.
  defp told(conversation_id, entry_id) do
    with %Entry{data: %{"message" => message}} <- Durable.entry(conversation_id, entry_id),
         text when text != "" <- String.trim(Message.text_of(message)),
         false <- Transcript.nothing_to_tell?(text) do
      text
    else
      _nothing -> nil
    end
  end
end

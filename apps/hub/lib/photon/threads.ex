# This module is two things on purpose, as `Photon.Assistant` is for Blip:
# the threads context's API and the `"thread"` profile. The profile alone
# reaches the model, Settings, the machine tools, skills and the prompt,
# and splitting it out would only move the same calls behind a facade.
# credo:disable-for-next-line Credo.Check.Refactor.ModuleDependencies
defmodule Photon.Threads do
  @moduledoc """
  Threads: durable agent conversations inside a project (sections 2.4 and
  3 of `docs/plans/step-2-projects-and-threads.md`).

  A thread is one conversation under the `"thread"` profile, run by
  `Photon.Durable` like Blip's, and a row in `threads` that ties it to its
  project, with its title and when it last got a message (`active_at`).
  Every thread belongs to a project. The user starts threads, and so does
  Blip, whose `start_thread`, `message_thread` and `stop_thread` tools go
  through `start_tx/4`, `send_tx/4` (with source `%{"kind" => "blip"}`)
  and `stop_tx/2` inside the commit that records their result. A thread
  can't start one, schedule anything or touch Blip's memory, and its prompt
  says nothing about the user. What it needs to know of the user it asks
  Blip with `ask_blip` (`Photon.Threads.Tools.AskBlip`, through
  `Photon.Questions`), and its call waits for the answer.

  A thread works with the machine tools (`Photon.MachineTools`: `shell`,
  `view_image`, `list_machines`) in its project's folder on whichever
  machine a call names (`workdir/1` is the project's slug), and reads and
  writes the project's context files with four tools of its own
  (`Photon.Threads.Tools`). Its prompt lists the skills turned on for its
  project (`Photon.Skills`), and `load_skill` loads one. It can search the
  web, and uses the model and reasoning level in Settings.

  This module is the threads context's API, which the web pages use, and
  the `"thread"` profile's module, as `Photon.Assistant` is both for Blip.
  Behind it, by layer:

    * data: `Photon.Threads.Thread`
    * functional core (pure): `Photon.Threads.Rules` (titles, who started
      a thread, and how the tools describe files),
      `Photon.Threads.State` (a thread's state from its facts),
      `Photon.Threads.Prompt` (the system prompt),
      `Photon.Threads.MockScript` (the scripted model)
    * boundary: the tools in `Photon.Threads.Tools`: the context-file
      tools, which write through `Photon.Projects` inside the commit that
      records their result, `load_skill`, which reads through
      `Photon.Skills` the same way, and `ask_blip`, which asks through
      `Photon.Questions` and parks on the answer

  Starting a thread makes the row, the conversation and the first message
  in one commit, so there is never a thread without its first message or a
  conversation without its row.

  The project's schedules start and wake threads too, inside their own
  commits, through `start_tx/4` and `send_tx/4`: the message then carries
  the schedule as its source and a request ID, so one firing makes one
  submission. A thread itself has no way to reach them.

  A thread's first title is made from its first message
  (`Photon.Threads.Rules.title/1`). The same commit creates a background
  task, `Photon.Threads.Titling`, that asks the model once for a short
  title when the first run ends; the owner can also rename a thread
  (`rename/2`). Either change announces `{:projects_changed, project_id}`,
  so the sidebar, the pages and Blip's chip show the new title. Starting one and sending one a message
  move its `active_at` and announce `{:projects_changed, project_id}`
  (through `Photon.Projects.threads_changed_tx/2`) in the same commit.
  Whether a thread is running is derived from its durable run
  (`Photon.Durable.busy/1`), never stored (rule 15).

  ## State

  A thread's state (running, asking Blip, waiting on you, failed,
  finished and unread, quiet, idle; `Photon.Threads.State`) is worked out
  when it is read (`board/1`, `state/1`, `sidebar/1`), from its open
  `ask_blip` questions (`Photon.Questions`) and facts on its row recorded
  when something happened (section 2 of
  `docs/plans/step-4-blip-as-coordinator.md`):

    * who started it (`started_by`), from its first message's source
    * how its last run ended: the `"thread"` profile's `on_settled/3`
      hook runs inside the harness's commit that settles a run, and when
      the run ends there it records `"done"`, `"failed"` or `"stopped"`,
      whether the answer asked the user something, and a short note, then
      announces `{:projects_changed, project_id}`. On a Stop or a failed
      task that commit is the Scheduler's, so the hook never raises: a
      missing row or answer records less.
    * when the owner last had the thread open (`mark_seen/1`,
      `mark_all_seen/0`), and whether they resolved it (`resolve/1`,
      `reopen/1`; a new message clears it)

  ## Signals to Blip

  The same hook decides, in code, whether Blip hears about the settle
  (`Photon.Signals.Rules.thread_update/2`, in the mode `Photon.Signals`
  gives), and posts it into Blip's conversation in the same commit
  (`Photon.Signals.post_tx/2`). Whose work it was comes from the settled
  messages' sources: Blip's own messages, and firings of schedules Blip
  made, are Blip's, and Blip hears how they end; everything else is the
  owner's, and Blip hears only when it fails or ends asking the user
  something. A stop is never a signal. While ambient mode is on, the
  owner's run that finishes without asking is collected as a digest item
  instead (`Photon.Signals.collect_tx/2`), in the same commit, and so are
  a thread the owner starts (`start/2`, not `start_tx/4`, which Blip's
  tools and schedules use) and the owner's Resolve (`resolve/1`).
  Ambient mode's daily review records when it listed a thread
  (`mark_reviewed_tx/3`, `reviewed_at`), a fact Home and the next review
  read and the thread's state doesn't.

  There is no process here: the harness runs the conversations, and the
  rows hold the rest.
  """

  use Boundary,
    deps: [
      Photon.ChatGPT,
      Photon.Durable,
      Photon.MachineTools,
      Photon.Projects,
      Photon.Questions,
      Photon.Repo,
      Photon.Settings,
      Photon.Signals,
      Photon.Skills,
      Photon.Transcript,
      PhotonCore,
      PhotonCore.LLM,
      Ecto
    ],
    exports: [Thread, State]

  @behaviour Photon.Durable.Profile

  import Ecto.Query

  alias Photon.{
    Durable,
    MachineTools,
    Projects,
    Questions,
    Repo,
    Settings,
    Signals,
    Skills,
    Transcript
  }

  alias Photon.Durable.{Entry, Submission, Tx}
  alias Photon.Projects.Project
  alias Photon.Questions.Question
  alias Photon.Signals.Rules, as: SignalRules
  alias Photon.Signals.Text, as: SignalText
  alias Photon.Threads.{Prompt, Rules, State, Thread, Titling, Tools}

  @profile "thread"

  # How many of a thread's newest assistant messages `latest_answer/1` looks
  # through for one with text (the others only call tools).
  @answer_lookback 20

  @tools [
    Tools.ListContextFiles,
    Tools.ReadContextFile,
    Tools.WriteContextFile,
    Tools.EditContextFile,
    Tools.LoadSkill,
    Tools.AskBlip
  ]

  # How long a stopped thread is left alone before it reads as quiet, when
  # the config doesn't say (section 2.3).
  @quiet_after_hours 72

  @typedoc "A project's ID, slug and name, as the board and sidebar give them."
  @type project_ref :: %{id: String.t(), slug: String.t(), name: String.t()}

  @typedoc "A project as the sidebar shows it, with its most recently active threads."
  @type sidebar_project :: %{
          project: project_ref(),
          threads: [
            %{id: String.t(), title: String.t(), running?: boolean(), state: State.t()}
          ],
          more: non_neg_integer()
        }

  @typedoc """
  A thread on the board (`board/1`): the thread, its project, its state,
  whether it has a question Blip still holds, and its open `ask_blip`
  questions, oldest first.
  """
  @type board_entry :: %{
          id: String.t(),
          thread: Thread.t(),
          project: project_ref(),
          state: State.t(),
          asking_blip?: boolean(),
          questions: [Question.t()]
        }

  ## Starting and talking to threads

  @doc """
  Starts a thread in project `project_id` with the user's first message:
  the thread's row, its conversation, the message and the task that names
  the thread after its first run, in one commit. The first title comes
  from the message, and `started_by` from its source
  (`Photon.Threads.Rules.started_by/1`). Errors: `:blank` when the message has no
  text, `:not_found` when the project doesn't exist; either makes nothing.
  In ambient mode a thread the owner starts is collected for the next
  digest (`"thread_started"`), in the same commit.
  """
  @spec start(String.t(), String.t()) :: {:ok, Thread.t()} | {:error, :blank | :not_found}
  def start(project_id, text), do: Durable.commit(&owner_start_tx(&1, project_id, text))

  defp owner_start_tx(tx, project_id, text) do
    with {:ok, thread} <- start_tx(tx, project_id, text, []) do
      :ok = collect_tx(tx, "thread_started", thread)
      {:ok, thread}
    end
  end

  @doc """
  `start/2` inside the caller's commit, for `Photon.Schedules` to start a
  thread when a schedule fires. Options:

    * `:source` - where the first message came from, stored with it
      (default `%{"kind" => "user"}`)
    * `:request_id` - when a thread of this project already has a message
      with this request ID, that thread is returned and nothing is made, so
      a retried start makes one thread and one submission

  Errors as `start/2`'s; they make nothing, so the caller's commit can go
  on.
  """
  @spec start_tx(Tx.t(), String.t(), String.t(), keyword()) ::
          {:ok, Thread.t()} | {:error, :blank | :not_found}
  def start_tx(tx, project_id, text, opts \\ []) do
    with false <- blank?(text),
         %Project{} = project <- Projects.get(project_id),
         nil <- started(project.id, opts[:request_id]) do
      {:ok, create_tx(tx, project, text, submit_opts(opts))}
    else
      true -> {:error, :blank}
      nil -> {:error, :not_found}
      %Thread{} = thread -> {:ok, thread}
    end
  end

  # The thread of project `project_id` whose conversation has a submission
  # with `request_id`, or nil (always nil without a request ID).
  defp started(_project_id, nil), do: nil

  defp started(project_id, request_id) do
    Thread
    |> join(:inner, [t], s in Submission, on: s.conversation_id == t.id)
    |> where([t, s], t.project_id == ^project_id and s.request_id == ^request_id)
    |> limit(1)
    |> Repo.one()
  end

  defp create_tx(tx, project, text, opts) do
    title = Rules.title(text)
    conversation = Tx.create_conversation(tx, %{profile: @profile, title: title})

    thread =
      Repo.insert!(%Thread{
        id: conversation.id,
        project_id: project.id,
        title: title,
        active_at: DateTime.utc_now(),
        started_by: Rules.started_by(opts[:source])
      })

    _submission = Durable.submit_tx(tx, conversation.id, text, opts)
    :ok = title_later(tx, conversation.id, title, text)
    :ok = Projects.threads_changed_tx(tx, project.id)
    thread
  end

  # The task that names the thread once its first run ends
  # (`Photon.Threads.Titling`), unless the hub is set not to (tests).
  defp title_later(tx, thread_id, title, text) do
    with true <- Application.get_env(:photon, __MODULE__, [])[:auto_title] != false,
         %{id: run_id} <- Tx.active_run(tx, thread_id) do
      _task = Tx.create_task(tx, Titling.task(thread_id, run_id, title, text))
      :ok
    else
      _off_or_no_run -> :ok
    end
  end

  @doc """
  Stores the title `Photon.Threads.Titling` asked the model for, inside
  its commit, and announces it: only while the thread still has its first
  title `fallback` (the owner may have renamed it), and only when there is
  a new one (`title` is nil when the model gave none).
  """
  @spec titled_tx(Tx.t(), String.t(), String.t(), String.t() | nil) :: :ok
  def titled_tx(tx, thread_id, fallback, title) do
    case get(thread_id) do
      %Thread{title: ^fallback} = thread when is_binary(title) and title != fallback ->
        retitle_tx(tx, thread, title)

      _renamed_gone_or_none ->
        :ok
    end
  end

  @doc """
  Renames thread `thread_id` to what the owner typed (whitespace
  collapsed, at most 80 characters; see `Photon.Threads.Rules.rename/1`),
  and announces it. Errors: `:blank`, and `:not_found` when there is no
  such thread.
  """
  @spec rename(String.t(), String.t()) :: {:ok, Thread.t()} | {:error, :blank | :not_found}
  def rename(thread_id, text) do
    with {:ok, title} <- Rules.rename(text),
         do: Durable.commit(&rename_tx(&1, thread_id, title))
  end

  defp rename_tx(tx, thread_id, title) do
    case get(thread_id) do
      %Thread{} = thread ->
        :ok = retitle_tx(tx, thread, title)
        {:ok, %{thread | title: title}}

      nil ->
        {:error, :not_found}
    end
  end

  # The thread's title, and the announcement that updates the pages showing
  # it. The conversation keeps its first title: nothing shows it, and only
  # the harness writes its rows.
  defp retitle_tx(tx, thread, title) do
    _thread = Repo.update!(Ecto.Changeset.change(thread, title: title))
    Projects.threads_changed_tx(tx, thread.project_id)
  end

  @doc """
  Sends the user's message to thread `thread_id`, and moves the thread's
  `active_at` and clears its `resolved_at`, in one commit. The options are `send_tx/4`'s.
  Errors: `:blank`, `:not_found`, and `:busy` for `when_busy: "reject"`.
  """
  @spec send(String.t(), String.t(), keyword()) ::
          {:ok, Submission.t()} | {:error, :blank | :not_found | :busy}
  def send(thread_id, text, opts \\ []) do
    case Durable.commit(&send_tx(&1, thread_id, text, opts)) do
      {:rolled_back, :busy} -> {:error, :busy}
      result -> result
    end
  end

  @doc """
  `send/3` inside the caller's commit, for `Photon.Schedules` to wake a
  thread when a schedule fires. The options are
  `Photon.Durable.submit/3`'s: `:source` (default `%{"kind" =>
  "user"}`), `:request_id` (a repeated one returns the submission already
  made instead of making another) and `:when_busy`. With `when_busy:
  "reject"` a busy thread rolls back the caller's whole commit with
  `:busy`. `:blank` and `:not_found` make nothing.
  """
  @spec send_tx(Tx.t(), String.t(), String.t(), keyword()) ::
          {:ok, Submission.t()} | {:error, :blank | :not_found}
  def send_tx(tx, thread_id, text, opts \\ []) do
    with false <- blank?(text),
         %Thread{} = thread <- get(thread_id) do
      submission = Durable.submit_tx(tx, thread.id, text, submit_opts(opts))

      _thread =
        Repo.update!(
          Ecto.Changeset.change(thread, active_at: DateTime.utc_now(), resolved_at: nil)
        )

      :ok = Projects.threads_changed_tx(tx, thread.project_id)
      {:ok, submission}
    else
      true -> {:error, :blank}
      nil -> {:error, :not_found}
    end
  end

  # A submission's options, with the user as its source unless one is given.
  defp submit_opts(opts), do: Keyword.put_new(opts, :source, %{"kind" => "user"})

  defp blank?(text), do: not is_binary(text) or String.trim(text) == ""

  @doc """
  Stops a thread: aborts its run and withdraws everything queued for it (a
  thread has no background input to keep).
  """
  @spec stop(String.t()) :: :ok
  def stop(thread_id) do
    _run = Durable.abort(thread_id)
    :ok
  end

  @doc """
  `stop/1` inside the caller's commit, for Blip's `stop_thread` tool:
  `:stopped` when the thread had a run to stop (it ends once the
  harness has stopped it), `:idle` when it had none.
  """
  @spec stop_tx(Tx.t(), String.t()) :: :stopped | :idle
  def stop_tx(tx, thread_id) do
    case Durable.abort_tx(tx, thread_id) do
      :idle -> :idle
      _run -> :stopped
    end
  end

  @doc "Withdraws a waiting message."
  @spec withdraw(String.t()) :: :ok
  def withdraw(submission_id) do
    _submission = Durable.withdraw(submission_id)
    :ok
  end

  ## Reading

  @doc "The thread with ID `id`, or nil."
  @spec get(String.t()) :: Thread.t() | nil
  def get(id), do: Repo.get(Thread, id)

  @doc "A project's threads, most recently active first."
  @spec list(String.t()) :: [Thread.t()]
  def list(project_id) do
    Thread
    |> where([t], t.project_id == ^project_id)
    |> order_by([t], desc: t.active_at, desc: t.inserted_at, asc: t.id)
    |> Repo.all()
  end

  @doc """
  The sidebar's projects, by name, each with its `limit` most recently
  active threads plus any other of its threads that is running (most
  recent first, each with `running?` and its `state`), and `more`, how
  many threads it has besides those.
  """
  @spec sidebar(pos_integer()) :: [sidebar_project()]
  def sidebar(limit) do
    running = Durable.busy_in_profile(@profile)
    rows = listed(limit, MapSet.to_list(running))
    questions = open_questions(rows)
    by_project = Enum.group_by(rows, & &1.project_id)
    now = DateTime.utc_now()
    opts = state_opts()

    for project <- Projects.list() do
      rows = Map.get(by_project, project.id, [])

      %{
        project: %{id: project.id, slug: project.slug, name: project.name},
        threads: Enum.map(rows, &sidebar_thread(&1, running, questions, now, opts)),
        more: total(rows) - length(rows)
      }
    end
  end

  defp open_questions(rows), do: rows |> Enum.map(& &1.id) |> Questions.open_by_thread()

  defp sidebar_thread(row, running, questions, now, opts) do
    running? = MapSet.member?(running, row.id)
    open = Map.get(questions, row.id, [])

    %{
      id: row.id,
      title: row.title,
      running?: running?,
      state: State.of(facts(row, running?, open), now, opts)
    }
  end

  # Each project's `limit` most recently active threads and the running
  # ones, with each project's thread count, in one query.
  defp listed(limit, running_ids) do
    ranked =
      from(t in Thread,
        windows: [by_project: [partition_by: t.project_id]],
        select: %{
          id: t.id,
          project_id: t.project_id,
          title: t.title,
          active_at: t.active_at,
          last_run_status: t.last_run_status,
          last_run_ended_at: t.last_run_ended_at,
          last_run_asked: t.last_run_asked,
          seen_at: t.seen_at,
          resolved_at: t.resolved_at,
          rank:
            over(row_number(),
              partition_by: t.project_id,
              order_by: [desc: t.active_at, desc: t.inserted_at, asc: t.id]
            ),
          total: over(count(t.id), :by_project)
        }
      )

    query =
      from(r in subquery(ranked),
        where: r.rank <= ^limit or r.id in ^running_ids,
        order_by: [asc: r.project_id, asc: r.rank]
      )

    Repo.all(query)
  end

  defp total([row | _rows]), do: row.total
  defp total([]), do: 0

  ## State

  @doc """
  Every thread in `scope` (`:all`, or `{:project, project_id}`) with its
  state (`Photon.Threads.State`), most recently active first, in a fixed
  number of queries however many threads there are: the threads with
  their projects, which are running, and their open questions. The pages
  group and cut it.
  """
  @spec board(:all | {:project, String.t()}) :: [board_entry()]
  def board(scope) do
    rows = scope |> board_query() |> Repo.all()
    busy = Durable.busy_in_profile(@profile)
    questions = Questions.open_by_thread(for {thread, _project} <- rows, do: thread.id)
    now = DateTime.utc_now()
    opts = state_opts()

    Enum.map(rows, fn {thread, project} ->
      entry(thread, project, busy, Map.get(questions, thread.id, []), {now, opts})
    end)
  end

  @doc "Thread `thread_id`'s board entry (see `board/1`), or nil when there is no such thread."
  @spec state(String.t()) :: board_entry() | nil
  def state(thread_id) do
    case :all |> board_query() |> where([t], t.id == ^thread_id) |> Repo.one() do
      {thread, project} ->
        questions = Map.get(Questions.open_by_thread([thread_id]), thread_id, [])

        entry(
          thread,
          project,
          Durable.busy([thread_id]),
          questions,
          {DateTime.utc_now(), state_opts()}
        )

      nil ->
        nil
    end
  end

  @doc """
  How many threads need the owner: waiting on them, failed, or finished
  and not yet looked at. Threads asking Blip don't count; Blip has those.
  """
  @spec needs_you_count() :: non_neg_integer()
  def needs_you_count, do: :all |> board() |> Enum.count(&needs_you?/1)

  defp needs_you?(%{state: state}), do: state in [:waiting, :failed, :unread]

  defp board_query(:all) do
    from(t in Thread,
      join: p in Project,
      on: p.id == t.project_id,
      order_by: [desc: t.active_at, desc: t.inserted_at, asc: t.id],
      select: {t, map(p, [:id, :slug, :name])}
    )
  end

  defp board_query({:project, project_id}),
    do: where(board_query(:all), [t], t.project_id == ^project_id)

  defp entry(thread, project, busy, questions, {now, opts}) do
    facts = facts(thread, MapSet.member?(busy, thread.id), questions)

    %{
      id: thread.id,
      thread: thread,
      project: project,
      state: State.of(facts, now, opts),
      asking_blip?: Enum.any?(questions, &(&1.status == "asked")),
      questions: questions
    }
  end

  # What `State.of/3` works the state out from, for a thread row (or a
  # map with its fields), whether it is running, and its open questions.
  defp facts(thread, busy?, questions) do
    thread
    |> Map.take([
      :last_run_status,
      :last_run_ended_at,
      :last_run_asked,
      :active_at,
      :seen_at,
      :resolved_at
    ])
    |> Map.merge(%{busy?: busy?, question: question(questions)})
  end

  # Where a thread's open questions are: with the owner if any is, else
  # with Blip if any is asked, else nil.
  defp question(questions) do
    cond do
      Enum.any?(questions, &(&1.status == "with_owner")) -> :with_owner
      Enum.any?(questions, &(&1.status == "asked")) -> :with_blip
      true -> nil
    end
  end

  defp state_opts, do: %{quiet_after: quiet_after()}

  @doc """
  How long, in seconds, a stopped thread is left alone before it reads as
  quiet (`config :photon, Photon.Threads, quiet_after_hours:`, 72 by
  default). Ambient mode's daily review uses it too, so it covers the
  threads Home lists as gone quiet.
  """
  @spec quiet_after() :: non_neg_integer()
  def quiet_after do
    case :photon |> Application.get_env(__MODULE__, []) |> Keyword.get(:quiet_after_hours) do
      hours when is_integer(hours) and hours >= 0 -> hours * 3600
      # Unset, or not a whole number of hours: the default.
      _other -> @quiet_after_hours * 3600
    end
  end

  @doc """
  Records that the owner has looked at thread `thread_id` (its page is
  open), in one commit, when it is unread: its last run finished
  (`"done"`) and the owner hasn't seen it since. Announces
  `{:projects_changed, project_id}` only then, so a page that calls this
  on every update doesn't loop on its own announcement. Blip reading a
  thread doesn't count: seen is the owner's.
  """
  @spec mark_seen(String.t()) :: :ok | {:error, :not_found}
  def mark_seen(thread_id), do: Durable.commit(&mark_seen_tx(&1, thread_id))

  defp mark_seen_tx(tx, thread_id) do
    case get(thread_id) do
      %Thread{} = thread ->
        if State.unseen?(thread), do: seen_tx(tx, [thread], DateTime.utc_now()), else: :ok

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Marks every thread that reads as finished and unread (`:unread` on the
  board) as seen, in one commit, announcing once per project touched.
  Returns how many it marked.
  """
  @spec mark_all_seen() :: non_neg_integer()
  def mark_all_seen do
    Durable.commit(fn tx ->
      threads = for %{state: :unread, thread: thread} <- board(:all), do: thread
      :ok = seen_tx(tx, threads, DateTime.utc_now())
      length(threads)
    end)
  end

  defp seen_tx(_tx, [], _now), do: :ok

  defp seen_tx(tx, threads, now) do
    ids = Enum.map(threads, & &1.id)

    {_count, _rows} = Thread |> where([t], t.id in ^ids) |> Repo.update_all(set: [seen_at: now])

    threads
    |> Enum.map(& &1.project_id)
    |> Enum.uniq()
    |> Enum.each(&(:ok = Projects.threads_changed_tx(tx, &1)))
  end

  @doc """
  Marks thread `thread_id` resolved: it reads as idle ("Resolved") until
  its next message, whatever its last run did. A running thread can be
  resolved; its state changes once the run ends. Input already queued
  for it starts a new run afterwards, which clears the mark again.
  Announces it. In ambient mode it is collected for the next digest
  (`"resolved"`), in the same commit.
  """
  @spec resolve(String.t()) :: :ok | {:error, :not_found}
  def resolve(thread_id), do: Durable.commit(&owner_resolve_tx(&1, thread_id))

  defp owner_resolve_tx(tx, thread_id) do
    case get(thread_id) do
      %Thread{} = thread ->
        :ok = set_resolved_tx(tx, thread, DateTime.utc_now())
        collect_tx(tx, "resolved", thread)

      nil ->
        {:error, :not_found}
    end
  end

  @doc "Takes back `resolve/1`, and announces it."
  @spec reopen(String.t()) :: :ok | {:error, :not_found}
  def reopen(thread_id), do: Durable.commit(&resolved_tx(&1, thread_id, nil))

  defp resolved_tx(tx, thread_id, resolved_at) do
    case get(thread_id) do
      %Thread{} = thread -> set_resolved_tx(tx, thread, resolved_at)
      nil -> {:error, :not_found}
    end
  end

  defp set_resolved_tx(tx, thread, resolved_at) do
    _thread = Repo.update!(Ecto.Changeset.change(thread, resolved_at: resolved_at))
    Projects.threads_changed_tx(tx, thread.project_id)
  end

  # An owner's start or Resolve, collected for the next digest while
  # ambient mode is on (`Photon.Signals.collect_tx/2` reads the mode in
  # this commit). One row per thread and kind: a second Resolve replaces
  # the first.
  defp collect_tx(tx, kind, thread) do
    Signals.collect_tx(tx, %{
      kind: kind,
      thread_id: thread.id,
      project_id: thread.project_id
    })
  end

  ## Ambient mode's review marks

  @doc """
  Records, inside the caller's commit, that ambient mode's daily review
  listed threads `thread_ids` at `now` (`reviewed_at`, section 4.2 of
  `docs/plans/step-5-ambient-mode.md`), and announces
  `{:projects_changed, project_id}` once per project. The mark is a fact
  the next review and Home read; a thread's state doesn't.
  """
  @spec mark_reviewed_tx(Tx.t(), [String.t()], DateTime.t()) :: :ok
  def mark_reviewed_tx(tx, thread_ids, %DateTime{} = now),
    do: set_reviewed_tx(tx, thread_ids, now)

  @doc """
  Clears the review marks of threads `thread_ids` inside the caller's
  commit, and announces once per project: for a review withdrawn before
  Blip read it, when ambient mode is turned off.
  """
  @spec unmark_reviewed_tx(Tx.t(), [String.t()]) :: :ok
  def unmark_reviewed_tx(tx, thread_ids), do: set_reviewed_tx(tx, thread_ids, nil)

  defp set_reviewed_tx(_tx, [], _reviewed_at), do: :ok

  defp set_reviewed_tx(tx, thread_ids, reviewed_at) when is_list(thread_ids) do
    threads = where(Thread, [t], t.id in ^thread_ids)
    project_ids = threads |> select([t], t.project_id) |> distinct(true) |> Repo.all()
    {_count, _rows} = Repo.update_all(threads, set: [reviewed_at: reviewed_at])
    Enum.each(project_ids, &(:ok = Projects.threads_changed_tx(tx, &1)))
  end

  @doc "Which of `thread_ids` are running."
  @spec running([String.t()]) :: MapSet.t(String.t())
  def running(thread_ids), do: Durable.busy(thread_ids)

  @doc """
  The ID of thread `thread_id`'s project. Raises when there is no such
  thread, which a thread's own tools never see, since threads aren't
  deleted.
  """
  @spec project_id!(String.t()) :: String.t()
  def project_id!(thread_id) do
    Thread
    |> where([t], t.id == ^thread_id)
    |> select([t], t.project_id)
    |> Repo.one() || raise "There's no thread #{thread_id}."
  end

  @doc """
  The titles of threads `thread_ids`, by ID; an ID with no thread is left
  out. The context-file tools and the project pages use it to name the
  thread that last wrote a file.
  """
  @spec titles([String.t()]) :: %{optional(String.t()) => String.t()}
  def titles([]), do: %{}

  def titles(thread_ids) do
    Thread
    |> where([t], t.id in ^thread_ids)
    |> select([t], {t.id, t.title})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  The titles and projects of threads `thread_ids`, by ID; an ID with no
  thread is left out. The activity page names and links the threads its
  rows mention with it, which needs each thread's project for the link.
  """
  @spec places([String.t()]) :: %{
          optional(String.t()) => %{title: String.t(), project_id: String.t()}
        }
  def places([]), do: %{}

  def places(thread_ids) do
    Thread
    |> where([t], t.id in ^thread_ids)
    |> select([t], {t.id, %{title: t.title, project_id: t.project_id}})
    |> Repo.all()
    |> Map.new()
  end

  ## Context files, as the file tools describe them

  @doc """
  The project's context files, newest change first, each with its size and
  who changed it last, as `viewer` sees them: a thread's ID for a thread's
  `list_context_files`, or `"blip"` for Blip's
  (`Photon.Threads.Rules.listing/3`). Says so when there are none.
  """
  @spec describe_files(String.t(), String.t()) :: String.t()
  def describe_files(project_id, viewer) do
    files = Projects.list_files(project_id)
    titles = files |> Enum.map(& &1.updated_by) |> Enum.uniq() |> titles()
    Rules.listing(files, viewer, titles)
  end

  @doc """
  The project's context file `name` after a line naming it with its size,
  when it changed and who changed it, as `viewer` sees it (a thread's ID
  or `"blip"`). A missing file is an error that lists the files there are.
  """
  @spec read_file_text(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def read_file_text(project_id, name, viewer) do
    case Projects.get_file(project_id, name) do
      nil ->
        names = project_id |> Projects.list_files() |> Enum.map(& &1.name)
        {:error, Rules.missing_file(String.trim(name), names)}

      file ->
        titles = titles([file.updated_by])
        {:ok, Rules.file_header(file, viewer, titles) <> "\n" <> file.content}
    end
  end

  @doc """
  The text of the thread's latest answer: its newest assistant message that
  has text, or nil when it has none yet. A message that only calls tools has
  no text, so it is skipped; only the last #{@answer_lookback} assistant
  messages are looked at.
  """
  @spec latest_answer(String.t()) :: String.t() | nil
  def latest_answer(thread_id) do
    thread_id
    |> Durable.last_entries("assistant", @answer_lookback)
    |> Enum.find_value(fn %Entry{data: data} ->
      text = data["message"] |> PhotonCore.Message.text_of() |> String.trim()
      if text != "", do: text
    end)
  end

  @doc """
  Thread `thread_id`'s newest `limit` entries of kinds `"user"`,
  `"assistant"` and `"tool_result"`, oldest first, for Blip's
  `read_thread`. Blip reading a thread doesn't mark it seen.
  """
  @spec recent_entries(String.t(), pos_integer()) :: [Entry.t()]
  def recent_entries(thread_id, limit), do: Durable.recent_entries(thread_id, limit)

  ## The conversation, for the thread page

  @doc """
  Subscribes to a thread's conversation: `{:durable, id, changes}` and
  `{:live, id, event}`; see `Photon.Durable.subscribe/1`.
  """
  @spec subscribe(String.t()) :: :ok
  def subscribe(thread_id), do: Durable.subscribe(thread_id)

  @doc "The thread's entries, in order."
  @spec entries(String.t()) :: [Entry.t()]
  def entries(thread_id), do: Durable.entries(thread_id)

  @doc "Whether the thread is working on something."
  @spec busy?(String.t()) :: boolean()
  def busy?(thread_id), do: Durable.busy?(thread_id)

  @doc "Messages waiting for the thread's current run, oldest first."
  @spec queued(String.t()) :: [Submission.t()]
  def queued(thread_id), do: Durable.queued(thread_id)

  @doc """
  The image at `index` among a tool result's images in thread
  `thread_id`'s conversation, for the page to load on its own:
  `{:ok, mime, bytes}`, or `:error` if there is no such thread, entry in
  it, or image.
  """
  @spec image(String.t(), String.t(), non_neg_integer()) ::
          {:ok, String.t(), binary()} | :error
  def image(thread_id, entry_id, index) do
    with %Thread{} <- get(thread_id),
         %Entry{} = entry <- Durable.entry(thread_id, entry_id) do
      Transcript.image(entry, index)
    else
      nil -> :error
    end
  end

  ## Profile

  @impl true
  def llm(conversation) do
    settings = Settings.load()

    %{
      # Threads search the web as Blip does (OpenAI runs the search). The
      # scripted model ignores it.
      config:
        Photon.Threads.MockScript
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
  def system_prompt(conversation) do
    project = project!(conversation.id)
    Prompt.system_prompt(project, DateTime.utc_now(), Skills.enabled({:project, project.id}))
  end

  @impl true
  def workdir(conversation), do: project!(conversation.id).slug

  @impl true
  def on_settled(conversation, settled, tx), do: settled_tx(tx, conversation, settled)

  # A generation settled what it placed (sections 2.4 and 3.2). When the
  # run ends with it, records how on the thread row and announces it; in
  # every case, posts the signal Blip hears about it, if any. It runs
  # inside the harness's commit, on a Stop or a failed task inside the
  # Scheduler's, so it is total: a missing row, project or answer records
  # less, and nothing here raises.
  defp settled_tx(tx, conversation, settled) do
    case get(conversation.id) do
      %Thread{} = thread ->
        text = run_text(conversation.id, settled)
        :ok = record_end_tx(tx, thread, settled, text)
        :ok = reopen_tx(tx, thread, settled)
        signal_tx(tx, thread, settled, text)

      nil ->
        :ok
    end
  end

  defp record_end_tx(tx, thread, %{ended?: true, outcome: status}, text) do
    {_count, _rows} =
      Thread
      |> where([t], t.id == ^thread.id)
      |> Repo.update_all(
        set: [
          last_run_status: status,
          last_run_ended_at: DateTime.utc_now(),
          last_run_asked: status == "done" and State.asks?(text),
          last_run_note: State.note(status, text)
        ]
      )

    Projects.threads_changed_tx(tx, thread.project_id)
  end

  defp record_end_tx(_tx, _thread, _settled, _text), do: :ok

  # A settle the generation goes on from places the next queued input: a
  # new run, which a Resolve made before it doesn't cover, just as a new
  # message clears it (section 2.5). Without this, input queued before the
  # owner resolved a running thread could fail or ask them unseen.
  defp reopen_tx(tx, %Thread{resolved_at: %DateTime{}} = thread, %{ended?: false}) do
    {_count, _rows} =
      Thread |> where([t], t.id == ^thread.id) |> Repo.update_all(set: [resolved_at: nil])

    Projects.threads_changed_tx(tx, thread.project_id)
  end

  defp reopen_tx(_tx, _thread, _settled), do: :ok

  # Whether Blip hears about this settle is decided by
  # `Photon.Signals.Rules` from the settled submissions' sources, in the
  # mode read in this commit; the signal names the thread and project as
  # they are now. In ambient mode the owner's finished run is a digest
  # item instead, which replaces an earlier finish of the same thread.
  defp signal_tx(tx, thread, settled, text) do
    case SignalRules.thread_update(signal_facts(settled, text), Signals.mode_tx(tx)) do
      nil ->
        :ok

      :digest ->
        Signals.collect_tx(tx, %{
          kind: "finished",
          thread_id: thread.id,
          project_id: thread.project_id,
          note: State.note("done", text)
        })

      kind ->
        case Projects.get(thread.project_id) do
          %Project{} = project -> post_tx(tx, kind, settled, text, place(thread, project))
          nil -> :ok
        end
    end
  end

  defp signal_facts(settled, text) do
    outcome = Map.get(settled, :outcome)

    %{
      outcome: outcome,
      asked?: outcome == "done" and State.asks?(text),
      ended?: Map.get(settled, :ended?) == true,
      sources: settled |> settled_submissions() |> Enum.map(&submission_source/1)
    }
  end

  defp post_tx(tx, kind, settled, text, place) do
    key = settle_key(settled)
    ref = SignalRules.update_ref(kind, key, place)
    detail = if kind == :failed, do: text, else: State.note("done", text)
    # The signal's submission is written in this commit; the hook has
    # nothing to do with it, and `post_tx/2` returns no error.
    _carrier = Signals.post_tx(tx, %{key: key, text: SignalText.update(ref, detail), ref: ref})
    :ok
  end

  defp settle_key(settled) do
    ids = for %Submission{id: id} <- settled_submissions(settled), do: id
    SignalRules.key({:settle, ids, settled_task_id(settled)})
  end

  defp settled_submissions(settled), do: List.wrap(Map.get(settled, :submissions))

  defp submission_source(%Submission{content: %{"source" => source}}), do: source
  defp submission_source(_submission), do: nil

  defp settled_task_id(%{task: %{id: id}}) when is_binary(id), do: id
  defp settled_task_id(_settled), do: "unknown"

  defp place(thread, project) do
    %{
      thread_id: thread.id,
      title: thread.title,
      project_id: project.id,
      slug: project.slug,
      project: project.name
    }
  end

  # The text a run's end is noted from: the answer for `"done"`, the
  # reason otherwise; nil when the answer entry is missing.
  defp run_text(thread_id, %{outcome: "done", answer_entry_id: entry_id})
       when is_binary(entry_id) do
    case Durable.entry(thread_id, entry_id) do
      %Entry{data: %{"message" => message}} -> PhotonCore.Message.text_of(message)
      _missing -> nil
    end
  end

  defp run_text(_thread_id, settled), do: Map.get(settled, :reason)

  # The project of thread `thread_id`. A thread whose row or project is
  # missing can't run: the generation or tool call fails with this message.
  defp project!(thread_id) do
    Project
    |> join(:inner, [p], t in Thread, on: t.project_id == p.id)
    |> where([_p, t], t.id == ^thread_id)
    |> Repo.one() || raise "This thread's project no longer exists."
  end
end

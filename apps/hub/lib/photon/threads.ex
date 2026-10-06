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
  Every thread belongs to a project. The user starts threads; a thread
  can't start one, schedule anything or touch Blip's memory, and its prompt
  says nothing about the user.

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
    * functional core (pure): `Photon.Threads.Rules` (titles, and how the
      tools describe files), `Photon.Threads.Prompt` (the system prompt),
      `Photon.Threads.MockScript` (the scripted model)
    * boundary: the tools in `Photon.Threads.Tools`: the context-file
      tools, which write through `Photon.Projects` inside the commit that
      records their result, and `load_skill`, which reads through
      `Photon.Skills` the same way

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

  There is no process here: the harness runs the conversations, and the
  rows hold the rest.
  """

  use Boundary,
    deps: [
      Photon.ChatGPT,
      Photon.Durable,
      Photon.MachineTools,
      Photon.Projects,
      Photon.Repo,
      Photon.Settings,
      Photon.Skills,
      Photon.Transcript,
      PhotonCore,
      PhotonCore.LLM,
      Ecto
    ],
    exports: [Thread]

  @behaviour Photon.Durable.Profile

  import Ecto.Query

  alias Photon.{Durable, MachineTools, Projects, Repo, Settings, Skills, Transcript}
  alias Photon.Durable.{Entry, Submission, Tx}
  alias Photon.Projects.Project
  alias Photon.Threads.{Prompt, Rules, Thread, Titling, Tools}

  @profile "thread"

  # How many of a thread's newest assistant messages `latest_answer/1` looks
  # through for one with text (the others only call tools).
  @answer_lookback 20

  @tools [
    Tools.ListContextFiles,
    Tools.ReadContextFile,
    Tools.WriteContextFile,
    Tools.EditContextFile,
    Tools.LoadSkill
  ]

  @typedoc "A project as the sidebar shows it, with its most recently active threads."
  @type sidebar_project :: %{
          project: %{id: String.t(), slug: String.t(), name: String.t()},
          threads: [%{id: String.t(), title: String.t(), running?: boolean()}],
          more: non_neg_integer()
        }

  ## Starting and talking to threads

  @doc """
  Starts a thread in project `project_id` with the user's first message:
  the thread's row, its conversation, the message and the task that names
  the thread after its first run, in one commit. The first title comes
  from the message. Errors: `:blank` when the message has no
  text, `:not_found` when the project doesn't exist; either makes nothing.
  """
  @spec start(String.t(), String.t()) :: {:ok, Thread.t()} | {:error, :blank | :not_found}
  def start(project_id, text), do: Durable.commit(&start_tx(&1, project_id, text, []))

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
        active_at: DateTime.utc_now()
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
  `active_at`, in one commit. The options are `send_tx/4`'s.
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
      _thread = Repo.update!(Ecto.Changeset.change(thread, active_at: DateTime.utc_now()))
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
  recent first, each with `running?`), and `more`, how many threads it has
  besides those.
  """
  @spec sidebar(pos_integer()) :: [sidebar_project()]
  def sidebar(limit) do
    running = Durable.busy_in_profile(@profile)
    by_project = limit |> listed(MapSet.to_list(running)) |> Enum.group_by(& &1.project_id)

    for project <- Projects.list() do
      rows = Map.get(by_project, project.id, [])

      %{
        project: %{id: project.id, slug: project.slug, name: project.name},
        threads:
          Enum.map(rows, &%{id: &1.id, title: &1.title, running?: MapSet.member?(running, &1.id)}),
        more: total(rows) - length(rows)
      }
    end
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

  # The project of thread `thread_id`. A thread whose row or project is
  # missing can't run: the generation or tool call fails with this message.
  defp project!(thread_id) do
    Project
    |> join(:inner, [p], t in Thread, on: t.project_id == p.id)
    |> where([_p, t], t.id == ^thread_id)
    |> Repo.one() || raise "This thread's project no longer exists."
  end
end

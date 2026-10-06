defmodule Photon.Durable do
  @moduledoc """
  The hub's durable agent harness, after Earendil's pi-durable, and its API.

  Conversations, model turns, tool calls and their own state are committed to
  SQLite before anything is shown, through one line of atomic commits
  (`Photon.Durable.Store`). Work runs as durable tasks
  (`Photon.Durable.Scheduler`): state machines that checkpoint at every step,
  so if the hub stops mid-turn, the next boot picks the work up where it
  stopped.

  One answered input, as entries and tasks:

      submit(input) -> "user" entry
        generation task -> "assistant" entry (with tool calls)
          tool task x n -> "tool_result" entry x n (owned by the generation, which waits)
        generation task -> "assistant" entry (the answer) -> submission done

  Input that arrives while a conversation is busy waits in its inbox, as a
  steer (joins the run after the current tool round) or a follow-up (starts
  the next run once this one answers). See `submit/3`.

  What a conversation runs with (model, system prompt, tools, and optionally
  the working directory its tools use on machines) comes from its profile, a
  `Photon.Durable.Profile` module named in config:

      config :photon, Photon.Durable, profiles: %{"assistant" => Photon.Assistant}

  Task kinds beyond the built-in `"generation"` and `"tool"` are registered
  the same way, under `:kinds`.

  ## Layers

  Behind this API, after *Designing Elixir Systems with OTP*:

    * data: the Ecto schemas `Photon.Durable.Conversation`, `Entry`, `Doc`,
      `TaskRecord`, `Submission` and `Signal`
    * functional core (pure): `Photon.Durable.Context` (model input),
      `Photon.Durable.Schema` (argument checks), `Photon.Durable.Inbox`
      (submission rules), `Photon.Durable.Policy` (the scheduler's rules),
      `Photon.Durable.Turn` (what a generation's answer leads to),
      `Photon.Durable.ToolCall` (what a tool call runs and records),
      `Photon.Durable.Changes` (what a commit announces) and
      `Photon.Durable.Queries` (the reads, as queries)
    * boundary: this module; `Photon.Durable.Store` (the commit line) with
      `Photon.Durable.Tx` (the writes a commit can make);
      `Photon.Durable.Scheduler`, the server that runs tasks; and
      `Photon.Durable.Runtime` and `Photon.Durable.ToolAPI`, what steps and
      tools get to work with
    * workers: one step process per running task, running a task kind
      (`Photon.Durable.Generation`, `Photon.Durable.ToolTask`, and the
      assistant's kinds) under `Photon.Durable.TaskSupervisor`
    * lifecycle: `Photon.Durable.Supervisor`
  """

  # Callers see this API, the data it returns, and the contracts and
  # capabilities task kinds and tools work with. The store, the scheduler,
  # the built-in task kinds and the functional core stay inside.
  use Boundary,
    deps: [
      Photon.Events,
      Photon.Repo,
      PhotonCore,
      PhotonCore.LLM,
      PhotonCore.LLM.Error,
      Ecto,
      Jason
    ],
    exports: [
      Conversation,
      Doc,
      Entry,
      Profile,
      Runtime,
      Signal,
      Submission,
      Supervisor,
      TaskKind,
      TaskRecord,
      Tool,
      ToolAPI,
      Tx
    ]

  alias Photon.Durable.{
    Conversation,
    Doc,
    Entry,
    Inbox,
    Queries,
    Store,
    Submission,
    TaskRecord,
    Tx
  }

  alias Photon.{Events, Repo}

  @builtin_kinds %{
    "generation" => Photon.Durable.Generation,
    "tool" => Photon.Durable.ToolTask
  }

  @doc "The module for a task kind, or nil."
  @spec kind(String.t()) :: module() | nil
  def kind(name) do
    @builtin_kinds |> Map.merge(config(:kinds, %{})) |> Map.get(name)
  end

  @doc "The module for a conversation profile."
  @spec profile(String.t()) :: module()
  def profile(name), do: Map.fetch!(config(:profiles, %{}), name)

  defp config(key, default) do
    :photon |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end

  @doc false
  # Whether `module` defines an optional callback. function_exported?/3 alone
  # is false for a module that isn't loaded yet, which in an interactive VM
  # is any kind or tool nothing has used since it started.
  @spec implements?(module(), atom(), arity()) :: boolean()
  def implements?(module, function, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, function, arity)

  ## Reading

  @spec conversation(String.t()) :: Conversation.t() | nil
  def conversation(id), do: Repo.get(Conversation, id)

  @doc "A conversation's entries in order; `after_seq` limits them to newer ones."
  @spec entries(String.t(), non_neg_integer()) :: [Entry.t()]
  def entries(conversation_id, after_seq \\ 0),
    do: Repo.all(Queries.entries(conversation_id, after_seq))

  @doc "One of a conversation's entries by its ID, or nil."
  @spec entry(String.t(), String.t()) :: Entry.t() | nil
  def entry(conversation_id, id), do: Repo.get_by(Entry, conversation_id: conversation_id, id: id)

  @spec doc(String.t(), String.t(), map()) :: map()
  def doc(scope, kind, default \\ %{}) do
    case Repo.get_by(Doc, scope: scope, kind: kind) do
      nil -> default
      doc -> doc.data
    end
  end

  @spec task(String.t()) :: TaskRecord.t() | nil
  def task(id), do: Repo.get(TaskRecord, id)

  @doc "Live tasks, for a task panel."
  @spec live_tasks() :: [TaskRecord.t()]
  def live_tasks, do: Repo.all(Queries.live_tasks())

  @doc "Live tasks of one kind, oldest first."
  @spec live_tasks(String.t()) :: [TaskRecord.t()]
  def live_tasks(kind), do: Repo.all(Queries.live_tasks(kind))

  @doc "Whether the conversation has a run in progress."
  @spec busy?(String.t()) :: boolean()
  def busy?(conversation_id), do: Repo.one(Queries.active_run(conversation_id)) != nil

  @doc """
  Which of `conversation_ids` have a run in progress (`busy?/1` for many,
  in one query).
  """
  @spec busy([String.t()]) :: MapSet.t(String.t())
  def busy([]), do: MapSet.new()
  def busy(conversation_ids), do: conversation_ids |> Queries.busy() |> Repo.all() |> MapSet.new()

  @doc "Which conversations with `profile` have a run in progress, in one query."
  @spec busy_in_profile(String.t()) :: MapSet.t(String.t())
  def busy_in_profile(profile),
    do: profile |> Queries.busy_in_profile() |> Repo.all() |> MapSet.new()

  @doc "A conversation's newest `limit` entries of `kind`, newest first."
  @spec last_entries(String.t(), String.t(), pos_integer()) :: [Entry.t()]
  def last_entries(conversation_id, kind, limit),
    do: Repo.all(Queries.last_entries(conversation_id, kind, limit))

  @doc "The conversation's inbox: queued submissions, oldest first."
  @spec queued(String.t()) :: [Submission.t()]
  def queued(conversation_id), do: Repo.all(Queries.queued(conversation_id))

  ## Watching

  @doc """
  Subscribes to a conversation: `{:durable, id, changes}` after each commit
  that touches it, and `{:live, id, event}` for streaming partial output,
  which is never stored.
  """
  @spec subscribe(String.t()) :: :ok
  def subscribe(conversation_id), do: Events.subscribe("durable:" <> conversation_id)

  @doc "Subscribes to global docs and task changes: `{:durable_tasks, tasks}`."
  @spec subscribe_global() :: :ok
  def subscribe_global, do: Events.subscribe("durable:global")

  @doc false
  # Partial output is a broadcast per event, never stored or acknowledged:
  # watchers that fall behind only miss intermediate text, and the finished
  # response is committed.
  @spec live(String.t(), map()) :: :ok
  def live(conversation_id, event),
    do: Events.broadcast("durable:" <> conversation_id, {:live, conversation_id, event})

  ## Writing

  @spec commit((Tx.t() -> result)) :: result | {:rolled_back, term()} when result: term()
  def commit(fun), do: Store.commit(fun)

  @spec create_conversation(String.t(), map() | keyword()) :: Conversation.t()
  def create_conversation(profile, attrs \\ %{}) do
    Store.commit(&Tx.create_conversation(&1, Map.put(Map.new(attrs), :profile, profile)))
  end

  @spec put_doc(String.t(), String.t(), map()) :: map()
  def put_doc(scope, kind, data), do: Store.commit(&Tx.put_doc(&1, scope, kind, data))

  @spec update_doc(String.t(), String.t(), map(), (map() -> map())) :: map()
  def update_doc(scope, kind, default, fun) do
    Store.commit(&Tx.update_doc(&1, scope, kind, default, fun))
  end

  @spec create_task(map() | keyword()) :: TaskRecord.t()
  def create_task(attrs), do: Store.commit(&Tx.create_task(&1, attrs))

  @doc "A recorded signal's payload, or nil if it hasn't fired."
  @spec signal_payload(String.t()) :: map() | nil
  def signal_payload(key) do
    case Repo.get(Photon.Durable.Signal, key) do
      nil -> nil
      signal -> signal.payload
    end
  end

  @doc "Records a signal; tasks waiting on `key` wake."
  @spec signal(String.t(), map()) :: :ok
  def signal(key, payload \\ %{}), do: Store.commit(&Tx.signal(&1, key, payload))

  @doc "Aborts a task and the foreground work it owns."
  @spec abort_task(String.t(), keyword()) :: TaskRecord.t() | :ok
  def abort_task(id, opts \\ []) do
    Store.commit(fn tx ->
      case Tx.get_task(tx, id) do
        nil -> :ok
        task -> Tx.request_abort(tx, task, opts)
      end
    end)
  end

  @doc """
  Hands input to a conversation. `content` is message content (text or
  parts). Options:

    * `:request_id` - a retried submission with the same ID returns the
      existing one instead of submitting twice
    * `:when_busy` - `"follow_up"` (default), `"steer"`, or `"reject"`
      (returns `{:error, :busy}`)
    * `:source` - where it came from, stored with the entry for display

  Returns `{:ok, submission}`.
  """
  @spec submit(String.t(), PhotonCore.Message.content(), keyword()) ::
          {:ok, Submission.t()} | {:error, :busy}
  def submit(conversation_id, content, opts \\ []) do
    case Store.commit(&submit_tx(&1, conversation_id, content, opts)) do
      {:rolled_back, :busy} -> {:error, :busy}
      %Submission{} = submission -> {:ok, submission}
    end
  end

  @doc "`submit/3` inside a commit; returns the submission."
  @spec submit_tx(Tx.t(), String.t(), PhotonCore.Message.content(), keyword()) :: Submission.t()
  def submit_tx(tx, conversation_id, content, opts \\ []) do
    existing =
      (opts[:request_id] && Tx.find_submission(tx, conversation_id, opts[:request_id])) || nil

    busy? = existing == nil and Tx.active_run(tx, conversation_id) != nil
    when_busy = Keyword.get(opts, :when_busy, "follow_up")
    attrs = Inbox.submission(conversation_id, content, opts)

    case Inbox.submit_action(existing, busy?, when_busy) do
      {:existing, submission} ->
        submission

      :reject ->
        Tx.rollback(:busy)

      :queue ->
        Tx.insert_submission(tx, attrs)

      :start_run ->
        submission = place(tx, Tx.insert_submission(tx, attrs))
        _run = Tx.create_task(tx, Inbox.run(conversation_id, [submission.id]))
        submission
    end
  end

  @doc false
  # Places a queued submission into the transcript as a user entry.
  @spec place(Tx.t(), Submission.t()) :: Submission.t()
  def place(tx, %Submission{} = submission) do
    entry = Tx.append(tx, submission.conversation_id, "user", Inbox.user_entry(submission))
    Tx.update_submission(tx, submission, status: "placed", entry_id: entry.id)
  end

  @doc "Withdraws a queued submission."
  @spec withdraw(String.t()) :: Submission.t() | nil
  def withdraw(submission_id) do
    Store.commit(fn tx ->
      submission = Tx.get_submission(tx, submission_id)

      if Inbox.withdrawable?(submission),
        do: Tx.update_submission(tx, submission, status: "withdrawn"),
        else: submission
    end)
  end

  @doc """
  Stops a conversation: withdraws its queued input and aborts the current
  run with everything it owns. Background work is left alone. Options:

    * `:withdraw` - a function that picks which queued submissions to
      withdraw (default: all of them)

  Input still queued once the run has been aborted starts the next run.
  """
  @spec abort(String.t(), keyword()) :: TaskRecord.t() | :idle
  def abort(conversation_id, opts \\ []) do
    withdraw? = Keyword.get(opts, :withdraw, fn _submission -> true end)

    Store.commit(fn tx ->
      tx
      |> Tx.queued(conversation_id)
      |> Enum.filter(withdraw?)
      |> Enum.each(&Tx.update_submission(tx, &1, status: "withdrawn"))

      case Tx.active_run(tx, conversation_id) do
        nil -> :idle
        task -> Tx.request_abort(tx, task)
      end
    end)
  end

  @doc false
  # The inbox's next input: every queued steer, else the oldest follow-up.
  @spec next_input([Submission.t()]) :: [Submission.t()]
  defdelegate next_input(queued), to: Inbox

  @doc false
  # After a conversation's run ended without handing its inbox on (it failed
  # or was aborted), the next queued input starts a new run, as
  # `submit_tx/4` would have started it on an idle conversation.
  @spec continue_inbox(Tx.t(), TaskRecord.t()) :: :ok
  def continue_inbox(tx, %TaskRecord{owner_task_id: nil, background: false} = run)
      when is_binary(run.conversation_id) do
    with nil <- Tx.active_run(tx, run.conversation_id),
         [_ | _] = next <- Inbox.next_input(Tx.queued(tx, run.conversation_id)) do
      placed = for s <- next, do: place(tx, s).id
      _run = Tx.create_task(tx, Inbox.run(run.conversation_id, placed))
      :ok
    else
      _busy_or_empty -> :ok
    end
  end

  def continue_inbox(_tx, _task), do: :ok

  @doc "Starts a fresh context: the model stops seeing older entries, which stay stored."
  @spec reset(String.t(), String.t() | nil) :: Entry.t()
  def reset(conversation_id, handoff \\ nil) do
    Store.commit(&Tx.append(&1, conversation_id, "reset", %{"handoff" => handoff}))
  end
end

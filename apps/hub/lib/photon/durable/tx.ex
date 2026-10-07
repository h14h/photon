defmodule Photon.Durable.Tx do
  @moduledoc """
  Operations available inside `Photon.Durable.Store.commit/1`. Each one writes
  through the open transaction (so later reads in the same commit see it) and
  records the change for announcement once the commit is stored.

  A `%Tx{}` names one open commit. Only `run/1`, which `Photon.Durable.Store`
  calls, makes one; a write through a `Tx` that isn't the open commit of the
  calling process raises instead of writing a change nobody would announce.
  Reads only need the transaction, and work with any `Tx`.

  The change list lives in the calling process's dictionary for the length
  of the commit. That is this module's detail: `run/1` sets it up and hands
  the changes back, in the order they were made.
  """

  alias Photon.Durable.{Conversation, Doc, Queries, Signal, Submission, TaskRecord}
  alias Photon.Repo

  @enforce_keys [:commit]
  defstruct [:commit]

  @opaque t :: %__MODULE__{commit: reference()}

  @typedoc "A change, as `Photon.Durable.Changes` announces it."
  @type change ::
          {:entry, Photon.Durable.Entry.t()}
          | {:doc, Doc.t()}
          | {:submission, Submission.t()}
          | {:task, TaskRecord.t()}
          | {:signal, String.t()}
          | {:announce, String.t(), term()}

  @typedoc "A step's transition; see `transition/4`."
  @type transition ::
          {:next, String.t(), map()}
          | {:wait, map(), String.t(), map()}
          | {:done, map()}
          | {:fail, term()}

  @changes :photon_durable_changes

  @doc false
  # Runs `fun.(tx)` in a database transaction with a fresh change list.
  # Exceptions propagate (nothing is stored); `rollback/1` ends it early.
  @spec run((t() -> result)) :: {:ok, result, [change()]} | {:rolled_back, term()}
        when result: term()
  def run(fun) when is_function(fun, 1) do
    tx = %__MODULE__{commit: make_ref()}
    Process.put(@changes, {tx.commit, []})

    try do
      case Repo.transaction(fn -> fun.(tx) end) do
        {:ok, result} ->
          {_commit, changes} = Process.get(@changes)
          {:ok, result, Enum.reverse(changes)}

        {:error, {:durable_rollback, value}} ->
          {:rolled_back, value}

        {:error, other} ->
          {:rolled_back, other}
      end
    after
      Process.delete(@changes)
    end
  end

  @doc "Aborts the commit; `Store.commit/1` returns `{:rolled_back, value}`."
  @spec rollback(term()) :: no_return()
  def rollback(value), do: Repo.rollback({:durable_rollback, value})

  # Every write calls open!/1 before it touches the database.
  defp record(%__MODULE__{commit: commit}, change) do
    {^commit, changes} = Process.get(@changes)
    Process.put(@changes, {commit, [change | changes]})
  end

  defp now, do: DateTime.utc_now()

  ## Conversations and entries

  @spec create_conversation(t(), map()) :: Conversation.t()
  def create_conversation(%__MODULE__{} = tx, attrs) do
    open!(tx)
    now = now()

    conversation =
      struct!(
        Conversation,
        Map.merge(%{id: PhotonCore.ID.new("c_"), inserted_at: now, updated_at: now}, attrs)
      )

    Repo.insert!(conversation)
  end

  @spec get_conversation(t(), String.t()) :: Conversation.t() | nil
  def get_conversation(%__MODULE__{}, id), do: Repo.get(Conversation, id)

  @doc "Appends an entry to a conversation and returns it."
  @spec append(t(), String.t(), String.t(), map()) :: Photon.Durable.Entry.t()
  def append(%__MODULE__{} = tx, conversation_id, kind, data) do
    open!(tx)
    seq = Repo.one(Queries.last_seq(conversation_id)) || 0

    entry =
      Repo.insert!(%Photon.Durable.Entry{
        id: PhotonCore.ID.new("e_"),
        conversation_id: conversation_id,
        seq: seq + 1,
        kind: kind,
        data: data,
        inserted_at: now()
      })

    record(tx, {:entry, entry})
    entry
  end

  @spec entries(t(), String.t()) :: [Photon.Durable.Entry.t()]
  def entries(%__MODULE__{}, conversation_id), do: Repo.all(Queries.entries(conversation_id))

  ## Documents

  @spec get_doc(t(), String.t(), String.t(), map()) :: map()
  def get_doc(%__MODULE__{}, scope, kind, default \\ %{}) do
    case Repo.get_by(Doc, scope: scope, kind: kind) do
      nil -> default
      doc -> doc.data
    end
  end

  @spec put_doc(t(), String.t(), String.t(), map()) :: map()
  def put_doc(%__MODULE__{} = tx, scope, kind, data) do
    open!(tx)
    doc = %Doc{scope: scope, kind: kind, data: data, updated_at: now()}

    Repo.insert!(doc,
      on_conflict: [set: [data: data, updated_at: doc.updated_at]],
      conflict_target: [:scope, :kind]
    )

    record(tx, {:doc, doc})
    data
  end

  @spec update_doc(t(), String.t(), String.t(), map(), (map() -> map())) :: map()
  def update_doc(%__MODULE__{} = tx, scope, kind, default, fun) do
    put_doc(tx, scope, kind, fun.(get_doc(tx, scope, kind, default)))
  end

  ## Tasks

  @doc """
  Creates a task. Attributes: `:kind`, `:conversation_id`, `:owner_task_id`,
  `:input`, and optionally `:phase` (default `"start"`), `:background`,
  `:request_id` (a task with the same request ID is returned instead of a
  second one) and `:waiting` (start out waiting rather than pending).
  """
  @spec create_task(t(), map() | keyword()) :: TaskRecord.t()
  def create_task(%__MODULE__{} = tx, attrs) do
    open!(tx)
    attrs = Map.new(attrs)

    case existing_task(attrs[:request_id]) do
      %TaskRecord{} = existing -> existing
      nil -> insert_task(tx, attrs)
    end
  end

  defp existing_task(nil), do: nil
  defp existing_task(request_id), do: Repo.get_by(TaskRecord, request_id: request_id)

  defp insert_task(tx, attrs) do
    now = now()

    task =
      Repo.insert!(%TaskRecord{
        id: PhotonCore.ID.new("t_"),
        kind: Map.fetch!(attrs, :kind),
        conversation_id: attrs[:conversation_id],
        owner_task_id: attrs[:owner_task_id],
        background: attrs[:background] || false,
        status: if(attrs[:waiting], do: "waiting", else: "pending"),
        phase: attrs[:phase] || "start",
        input: attrs[:input] || %{},
        checkpoint: attrs[:checkpoint] || %{},
        waiting: attrs[:waiting] && stringify(attrs[:waiting]),
        runs: 0,
        request_id: attrs[:request_id],
        inserted_at: now,
        updated_at: now
      })

    record(tx, {:task, task})
    task
  end

  @spec get_task(t(), String.t()) :: TaskRecord.t() | nil
  def get_task(%__MODULE__{}, id), do: Repo.get(TaskRecord, id)

  @spec update_task(t(), TaskRecord.t(), map() | keyword()) :: TaskRecord.t()
  def update_task(%__MODULE__{} = tx, %TaskRecord{} = task, changes) do
    open!(tx)

    task =
      task
      |> Ecto.Changeset.change(Map.put(Map.new(changes), :updated_at, now()))
      |> Repo.update!()

    record(tx, {:task, task})
    task
  end

  @doc "Tasks owned by `task_id` that haven't finished."
  @spec live_owned(t(), String.t()) :: [TaskRecord.t()]
  def live_owned(%__MODULE__{}, task_id), do: Repo.all(Queries.live_owned(task_id))

  @doc """
  The conversation's current run: its unfinished, conversation-owned,
  foreground task, if any. A conversation with one is busy.
  """
  @spec active_run(t(), String.t()) :: TaskRecord.t() | nil
  def active_run(%__MODULE__{}, conversation_id),
    do: Repo.one(Queries.active_run(conversation_id))

  @doc """
  Marks a task and everything it owns (except background work) for abort.
  The scheduler stops them, deepest first. `background: true` marks
  background work too.
  """
  @spec request_abort(t(), TaskRecord.t(), keyword()) :: TaskRecord.t()
  def request_abort(tx, task, opts \\ [])

  def request_abort(%__MODULE__{} = tx, %TaskRecord{} = task, opts) do
    if TaskRecord.terminal?(task),
      do: task,
      else: mark_for_abort(tx, task, opts)
  end

  defp mark_for_abort(tx, task, opts) do
    tx
    |> live_owned(task.id)
    |> Enum.filter(&(opts[:background] || not &1.background))
    |> Enum.each(&request_abort(tx, &1, opts))

    if task.abort_requested, do: task, else: update_task(tx, task, abort_requested: true)
  end

  @doc """
  Applies a step's transition to a running task:

    * `{:next, phase, checkpoint}` - run `phase` next
    * `{:wait, waiting, phase, checkpoint}` - resume in `phase` once
      `waiting` is satisfied: `"on"` (task IDs, with `"policy"`
      `"all_settled"` or `"fail_fast"`), `"until"` (Unix milliseconds) or
      `"signal"` (a key); `"until"` with either of the others is a timeout
    * `{:done, outcome}` or `{:fail, reason}` - finish

  Finishing aborts unfinished foreground work the task owns. A task that was
  aborted meanwhile is left alone; returns `:ignored` then.

  `started` fences out stale steps: given the task as the step got it when
  the scheduler started it, the transition only applies while the task is
  still `running` and unchanged since that start (same `updated_at`, which
  every task update moves, unlike `runs`, which resets with each phase). A
  step left over from before a scheduler restart (its task was reset and
  started again) is ignored, so a phase's work is committed once.
  """
  @spec transition(t(), String.t(), transition(), TaskRecord.t() | nil) ::
          TaskRecord.t() | :ignored
  def transition(%__MODULE__{} = tx, task_id, transition, started \\ nil) do
    case get_task(tx, task_id) do
      %TaskRecord{status: status} when status in ["done", "failed", "aborted"] ->
        :ignored

      %TaskRecord{abort_requested: true} ->
        :ignored

      %TaskRecord{} = task when started != nil ->
        if task.status == "running" and
             DateTime.compare(task.updated_at, started.updated_at) == :eq,
           do: apply_transition(tx, task, transition),
           else: :ignored

      task ->
        apply_transition(tx, task, transition)
    end
  end

  defp apply_transition(tx, task, {:next, phase, checkpoint}) do
    update_task(tx, task,
      status: "pending",
      phase: phase,
      checkpoint: stringify(checkpoint),
      waiting: nil,
      runs: if(phase == task.phase, do: task.runs, else: 0)
    )
  end

  defp apply_transition(tx, task, {:wait, waiting, phase, checkpoint}) do
    update_task(tx, task,
      status: "waiting",
      phase: phase,
      checkpoint: stringify(checkpoint),
      waiting: stringify(waiting),
      runs: 0
    )
  end

  defp apply_transition(tx, task, {:done, outcome}) do
    finish(tx, task, "done", Map.put(stringify(outcome), "status", "done"))
  end

  defp apply_transition(tx, task, {:fail, reason}) do
    finish(tx, task, "failed", %{"status" => "failed", "reason" => to_string(reason)})
  end

  @doc false
  @spec finish(t(), TaskRecord.t(), String.t(), map()) :: TaskRecord.t()
  def finish(tx, task, status, outcome) do
    tx
    |> live_owned(task.id)
    |> Enum.reject(& &1.background)
    |> Enum.each(&request_abort(tx, &1))

    update_task(tx, task, status: status, outcome: outcome, waiting: nil)
  end

  ## Submissions

  @spec insert_submission(t(), map()) :: Submission.t()
  def insert_submission(%__MODULE__{} = tx, attrs) do
    open!(tx)
    now = now()

    submission =
      Repo.insert!(
        struct!(
          Submission,
          Map.merge(%{id: PhotonCore.ID.new("s_"), inserted_at: now, updated_at: now}, attrs)
        )
      )

    record(tx, {:submission, submission})
    submission
  end

  @spec update_submission(t(), Submission.t(), map() | keyword()) :: Submission.t()
  def update_submission(%__MODULE__{} = tx, %Submission{} = submission, changes) do
    open!(tx)

    submission =
      submission
      |> Ecto.Changeset.change(Map.put(Map.new(changes), :updated_at, now()))
      |> Repo.update!()

    record(tx, {:submission, submission})
    submission
  end

  @spec get_submission(t(), String.t()) :: Submission.t() | nil
  def get_submission(%__MODULE__{}, id), do: Repo.get(Submission, id)

  @spec find_submission(t(), String.t(), String.t()) :: Submission.t() | nil
  def find_submission(%__MODULE__{}, conversation_id, request_id) do
    Repo.get_by(Submission, conversation_id: conversation_id, request_id: request_id)
  end

  @doc "Queued submissions, oldest first; `mode` limits them to steers or follow-ups."
  @spec queued(t(), String.t(), String.t() | nil) :: [Submission.t()]
  def queued(%__MODULE__{}, conversation_id, mode \\ nil),
    do: Repo.all(Queries.queued(conversation_id, mode))

  @doc """
  How many `"ok"` results of the tools in `names` the conversation has
  after its last user entry whose source kind is one of `source_kinds`
  (`Photon.Durable.Queries.count_tool_results_since/3`).
  """
  @spec count_tool_results_since(t(), String.t(), [String.t()], [String.t()]) ::
          non_neg_integer()
  def count_tool_results_since(%__MODULE__{}, conversation_id, names, source_kinds),
    do: Repo.one(Queries.count_tool_results_since(conversation_id, names, source_kinds))

  ## Signals

  @doc "Records a signal (once per key) and wakes tasks waiting on it."
  @spec signal(t(), String.t(), map()) :: :ok
  def signal(%__MODULE__{} = tx, key, payload \\ %{}) do
    open!(tx)

    Repo.insert!(%Signal{key: key, payload: stringify(payload), inserted_at: now()},
      on_conflict: :nothing,
      conflict_target: :key
    )

    record(tx, {:signal, key})
    :ok
  end

  @spec get_signal(t(), String.t()) :: Signal.t() | nil
  def get_signal(%__MODULE__{}, key), do: Repo.get(Signal, key)

  ## Announcements

  @doc """
  Announces `message` on `topic` (through `Photon.Events`) once the commit is
  stored, after its `durable:*` announcements. A commit that rolls back or
  raises announces nothing. For contexts whose writes go through this
  commit line (a thread's file write lands in its tool call's commit), so
  pages hear of a change only when it is stored.
  """
  @spec announce(t(), String.t(), term()) :: :ok
  def announce(%__MODULE__{} = tx, topic, message) when is_binary(topic) do
    open!(tx)
    record(tx, {:announce, topic, message})
    :ok
  end

  @doc false
  # Stored maps use string keys, so values read back the way they were written.
  @spec stringify(term()) :: term()
  def stringify(nil), do: nil

  def stringify(map) when is_map(map) and not is_struct(map),
    do: map |> Jason.encode!() |> Jason.decode!()

  def stringify(other), do: other

  # A write checks before it touches the database, so a stray Tx can't
  # write at all, rather than write a change nobody announces.
  defp open!(%__MODULE__{commit: commit}) do
    case Process.get(@changes) do
      {^commit, _} ->
        :ok

      _ ->
        raise ArgumentError,
              "a Photon.Durable.Tx write ran outside its commit; " <>
                "write inside Photon.Durable.Store.commit/1"
    end
  end
end

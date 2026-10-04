defmodule Photon.Durable.Queries do
  @moduledoc """
  The durable harness's reads, as Ecto queries. Building a query is pure;
  the caller runs it: `Photon.Durable` outside a commit, `Photon.Durable.Tx`
  inside one (through the commit's transaction), and the scheduler while it
  reconciles. One definition per question keeps those three in agreement
  about what "busy" or "queued" means.
  """

  # Functional core: no processes, no I/O.
  use Boundary,
    type: :strict,
    deps: [
      Photon.Durable.Entry,
      Photon.Durable.Signal,
      Photon.Durable.Submission,
      Photon.Durable.TaskRecord,
      Ecto
    ]

  import Ecto.Query

  alias Photon.Durable.{Entry, Signal, Submission, TaskRecord}

  @doc "A conversation's entries after `after_seq`, in order."
  @spec entries(String.t(), non_neg_integer()) :: Ecto.Query.t()
  def entries(conversation_id, after_seq \\ 0) do
    from(e in Entry,
      where: e.conversation_id == ^conversation_id and e.seq > ^after_seq,
      order_by: [asc: e.seq]
    )
  end

  @doc "The highest entry `seq` in a conversation (nil when it has none)."
  @spec last_seq(String.t()) :: Ecto.Query.t()
  def last_seq(conversation_id) do
    from(e in Entry, where: e.conversation_id == ^conversation_id, select: max(e.seq))
  end

  @doc "Unfinished tasks, oldest first."
  @spec live_tasks() :: Ecto.Query.t()
  def live_tasks do
    from(t in TaskRecord,
      where: t.status not in ^TaskRecord.terminal_statuses(),
      order_by: [asc: t.inserted_at]
    )
  end

  @doc "Unfinished tasks of one kind, oldest first."
  @spec live_tasks(String.t()) :: Ecto.Query.t()
  def live_tasks(kind) do
    from(t in TaskRecord,
      where: t.kind == ^kind and t.status not in ^TaskRecord.terminal_statuses(),
      order_by: [asc: t.inserted_at]
    )
  end

  @doc "Unfinished tasks in no particular order (what the scheduler reconciles)."
  @spec unfinished_tasks() :: Ecto.Query.t()
  def unfinished_tasks do
    from(t in TaskRecord, where: t.status not in ^TaskRecord.terminal_statuses())
  end

  @doc "Unfinished tasks owned by `task_id`."
  @spec live_owned(String.t()) :: Ecto.Query.t()
  def live_owned(task_id) do
    from(t in TaskRecord,
      where: t.owner_task_id == ^task_id and t.status not in ^TaskRecord.terminal_statuses()
    )
  end

  @doc """
  The conversation's current run: its unfinished, conversation-owned,
  foreground task, if any.
  """
  @spec active_run(String.t()) :: Ecto.Query.t()
  def active_run(conversation_id) do
    from(t in TaskRecord,
      where:
        t.conversation_id == ^conversation_id and is_nil(t.owner_task_id) and
          t.background == false and t.status not in ^TaskRecord.terminal_statuses(),
      limit: 1
    )
  end

  @doc "Queued submissions, oldest first; `mode` limits them to steers or follow-ups."
  @spec queued(String.t(), String.t() | nil) :: Ecto.Query.t()
  def queued(conversation_id, mode \\ nil) do
    query =
      from(s in Submission,
        where: s.conversation_id == ^conversation_id and s.status == "queued",
        order_by: [asc: s.inserted_at, asc: s.id]
      )

    if mode, do: where(query, [s], s.mode == ^mode), else: query
  end

  @doc "The status of each of `ids` that exists, as `{id, status}`."
  @spec statuses([String.t()]) :: Ecto.Query.t()
  def statuses(ids) do
    from(t in TaskRecord, where: t.id in ^ids, select: {t.id, t.status})
  end

  @doc "Which of the signal `keys` are recorded."
  @spec recorded_signals([String.t()]) :: Ecto.Query.t()
  def recorded_signals(keys), do: from(s in Signal, where: s.key in ^keys, select: s.key)

  @doc "Pending tasks that aren't marked for abort, oldest first."
  @spec startable() :: Ecto.Query.t()
  def startable do
    from(t in TaskRecord,
      where: t.status == "pending" and t.abort_requested == false,
      order_by: [asc: t.inserted_at]
    )
  end

  @doc "What every waiting task waits on."
  @spec waiting_conditions() :: Ecto.Query.t()
  def waiting_conditions do
    from(t in TaskRecord, where: t.status == "waiting", select: t.waiting)
  end

  @doc "Tasks a stopped process left `running`."
  @spec running() :: Ecto.Query.t()
  def running, do: from(t in TaskRecord, where: t.status == "running")
end

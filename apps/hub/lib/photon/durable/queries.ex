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
      Photon.Durable.Conversation,
      Photon.Durable.Entry,
      Photon.Durable.Signal,
      Photon.Durable.Submission,
      Photon.Durable.TaskRecord,
      Ecto
    ]

  import Ecto.Query

  alias Photon.Durable.{Conversation, Entry, Signal, Submission, TaskRecord}

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

  @recent_kinds ~w(user assistant tool_result)

  @doc """
  A conversation's newest `limit` entries of kinds `"user"`, `"assistant"`
  and `"tool_result"`, oldest first.
  """
  @spec recent_entries(String.t(), pos_integer()) :: Ecto.Query.t()
  def recent_entries(conversation_id, limit) do
    newest =
      from(e in Entry,
        where: e.conversation_id == ^conversation_id and e.kind in ^@recent_kinds,
        order_by: [desc: e.seq],
        limit: ^limit
      )

    from(e in subquery(newest), order_by: [asc: e.seq])
  end

  @doc """
  How many of a conversation's `"tool_result"` entries with status `"ok"`
  are of a tool in `names` and come after its last `"user"` entry whose
  source kind is one of `source_kinds` (after its start when it has none).
  One query, which selects the count.
  """
  @spec count_tool_results_since(String.t(), [String.t()], [String.t()]) :: Ecto.Query.t()
  def count_tool_results_since(conversation_id, names, source_kinds) do
    since =
      from(u in Entry,
        where:
          u.conversation_id == ^conversation_id and u.kind == "user" and
            u.data["source"]["kind"] in ^source_kinds,
        select: max(u.seq)
      )

    from(e in Entry,
      where:
        e.conversation_id == ^conversation_id and e.kind == "tool_result" and
          e.data["status"] == "ok" and e.data["name"] in ^names and
          e.seq > coalesce(subquery(since), 0),
      select: count(e.id)
    )
  end

  @doc "A conversation's newest `limit` entries of `kind`, newest first."
  @spec last_entries(String.t(), String.t(), pos_integer()) :: Ecto.Query.t()
  def last_entries(conversation_id, kind, limit) do
    from(e in Entry,
      where: e.conversation_id == ^conversation_id and e.kind == ^kind,
      order_by: [desc: e.seq],
      limit: ^limit
    )
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

  @doc """
  Which of `conversation_ids` are busy, as `conversation_id`s: those with a
  current run (as `active_run/1` defines it).
  """
  @spec busy([String.t()]) :: Ecto.Query.t()
  def busy(conversation_ids) do
    from(t in runs(), where: t.conversation_id in ^conversation_ids)
  end

  @doc "Which conversations with `profile` are busy, as `conversation_id`s."
  @spec busy_in_profile(String.t()) :: Ecto.Query.t()
  def busy_in_profile(profile) do
    from(t in runs(),
      join: c in Conversation,
      on: c.id == t.conversation_id,
      where: c.profile == ^profile
    )
  end

  # Current runs (unfinished, conversation-owned, foreground), one row per
  # conversation that has one.
  defp runs do
    from(t in TaskRecord,
      where:
        is_nil(t.owner_task_id) and t.background == false and
          t.status not in ^TaskRecord.terminal_statuses(),
      select: t.conversation_id,
      distinct: true
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

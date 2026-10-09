defmodule Photon.Durable.Store do
  @moduledoc """
  The one line of atomic commits every durable change goes through.

  `commit/1` runs a function of `Photon.Durable.Tx` writes in this process
  inside a database transaction: all of it is stored or none of it. Only
  after the transaction commits are its changes announced
  (`Photon.Durable.Changes` says what): on `"durable:" <> conversation_id`
  as `{:durable, conversation_id, changes}`, on `"durable:global"` for
  global docs and every task change, each `Tx.announce/3` on its own topic
  in commit order, and to `Photon.Durable.Scheduler`. So nothing is shown
  before it is stored. Commit functions run serially and must not do slow
  work: do that first, then commit the result.

  Why a process: it holds no state. It is the lock that makes the commits
  one line, which SQLite needs (one writer at a time) and the harness relies
  on (a commit reads what the previous one wrote). `commit/1` is a call, so
  writers get back pressure from the database.
  """

  use GenServer

  alias Photon.Durable.{Changes, Scheduler, Tx}
  alias Photon.Events

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Runs `fun.(tx)` atomically and returns its result. Raises in the caller if
  `fun` raises (nothing is stored). `Tx.rollback/1` aborts the commit and
  makes this return `{:rolled_back, value}`.
  """
  @spec commit((Tx.t() -> result), timeout()) :: result | {:rolled_back, term()}
        when result: term()
  def commit(fun, timeout \\ 60_000) when is_function(fun, 1) do
    case GenServer.call(__MODULE__, {:commit, fun}, timeout) do
      {:ok, result} -> result
      {:rolled_back, value} -> {:rolled_back, value}
      {:raise, exception, stacktrace} -> reraise exception, stacktrace
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:commit, fun}, _from, state) do
    reply =
      try do
        case Tx.run(fun) do
          {:ok, result, changes} ->
            announce(Changes.summarize(changes))
            {:ok, result}

          {:rolled_back, value} ->
            {:rolled_back, value}
        end
      rescue
        exception -> {:raise, exception, __STACKTRACE__}
      end

    {:reply, reply, state}
  end

  defp announce(changes) do
    Enum.each(changes.scopes, fn {scope, summary} ->
      Events.broadcast("durable:" <> scope, {:durable, scope, summary})
    end)

    if changes.tasks != [],
      do: Events.broadcast("durable:global", {:durable_tasks, changes.tasks})

    Enum.each(changes.announcements, fn {topic, message} -> Events.broadcast(topic, message) end)

    if Changes.wakes_scheduler?(changes), do: Scheduler.notify(changes.tasks, changes.signals)
    :ok
  end
end

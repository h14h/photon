defmodule Photon.Durable.Supervisor do
  @moduledoc """
  The durable harness's processes, in start order:

    * `Photon.Durable.TaskSupervisor` (`Task.Supervisor`): one task per
      running step, started by the scheduler with `async_nolink`, so a step
      that crashes fails its task instead of the scheduler. Shutting down
      kills the steps; their tasks are reset to pending on the next boot.
    * `Photon.Durable.Store`: the commit line. It holds no state, so a
      restart loses nothing; a caller whose commit was in flight gets an
      exit, and nothing of that commit is stored.
    * `Photon.Durable.Scheduler`

  The strategy is `:one_for_one`, on purpose. A scheduler restart leaves
  the steps it started running; the new scheduler starts their tasks again,
  and the old steps' commits are fenced out (`Photon.Durable.Tx.transition/4`),
  which `specs/tla/Durable.tla` checks as a Scheduler-only crash. A Store
  restart needs nothing from the others. Workers use the default 5 second
  shutdown; the task supervisor, being a supervisor, waits for its steps.

  Not started under `config :photon, start_durable: false`; tests start
  `children/0` themselves.
  """

  use Supervisor

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The child specs, in start order."
  @spec children() :: [Supervisor.child_spec() | {module(), term()} | module()]
  def children do
    [
      {Task.Supervisor, name: Photon.Durable.TaskSupervisor},
      Photon.Durable.Store,
      Photon.Durable.Scheduler
    ]
  end

  @impl true
  def init(_opts), do: Supervisor.init(children(), strategy: :one_for_one)
end

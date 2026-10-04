defmodule PhotonNode.Harness.Ops.Job do
  @moduledoc """
  The worker for operations that do one piece of work and finish
  (`view_image`, `skill_use`). It runs the job off the coordinator, since a
  job can read a large file, reports the terminal snapshot the job returns,
  and stops.

  It is registered by operation ID like every operation process, so
  `PhotonNode.Harness.Ops.add/2` finds it while it runs. It has nothing to
  resend or cancel, so it ignores those requests.

  A job is a module with `run/1`: it takes the operation and returns its
  terminal snapshot. Jobs read files, so they are boundary code, but they
  run as plain functions and are tested without a process.
  """

  use GenServer, restart: :temporary

  alias PhotonNode.Harness.{Coordinator, Operation, Ops}

  @doc "Does the operation's work and returns its terminal snapshot."
  @callback run(Operation.t()) :: Operation.t()

  @spec start_link({module(), Operation.t(), String.t()}) :: GenServer.on_start()
  def start_link({job, op, session_id}),
    do: GenServer.start_link(__MODULE__, {job, op, session_id}, name: Ops.via(op["id"]))

  @impl true
  def init({job, op, session_id}),
    do: {:ok, %{job: job, op: op, session_id: session_id}, {:continue, :run}}

  @impl true
  def handle_continue(:run, state) do
    op = state.job.run(state.op)
    Coordinator.report_op(state.session_id, op)
    {:stop, :normal, %{state | op: op}}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}
end

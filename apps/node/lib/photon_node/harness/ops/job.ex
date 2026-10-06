defmodule PhotonNode.Harness.Ops.Job do
  @moduledoc """
  The worker for operations that do one piece of work and finish
  (`view_image`, `skill_use`). It runs the job off its owner
  (`PhotonNode.Harness.Ops.Owner`), since a job can read a large file,
  reports the terminal snapshot the job returns to the owner, and stops.

  It is registered by operation ID like every operation process, so
  `PhotonNode.Harness.Ops.add/2` finds it while it runs. It has nothing to
  resend or cancel, so it ignores those requests.

  A job is a module with `run/1`: it takes the operation and returns its
  terminal snapshot. Jobs read files, so they are boundary code, but they
  run as plain functions and are tested without a process.
  """

  use GenServer, restart: :temporary

  alias PhotonCore.Operation
  alias PhotonNode.Harness.Ops
  alias PhotonNode.Harness.Ops.Owner

  @doc "Does the operation's work and returns its terminal snapshot."
  @callback run(Operation.t()) :: Operation.t()

  @spec start_link({module(), Operation.t(), Owner.t()}) :: GenServer.on_start()
  def start_link({job, op, owner}),
    do: GenServer.start_link(__MODULE__, {job, op, owner}, name: Ops.via(op["id"]))

  @impl true
  def init({job, op, owner}),
    do: {:ok, %{job: job, op: op, owner: owner}, {:continue, :run}}

  @impl true
  def handle_continue(:run, state) do
    op = state.job.run(state.op)
    # :down means no owner took the result. The owner's monitor sees this
    # process exit before a terminal snapshot it stored, and decides.
    _ = Owner.report(state.owner, op)
    {:stop, :normal, %{state | op: op}}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}
end

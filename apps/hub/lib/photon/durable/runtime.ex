defmodule Photon.Durable.Runtime do
  @moduledoc """
  What a task step works with: its own task record, and commits that carry
  the step's transition atomically with whatever else it writes.
  """

  alias Photon.Durable.{Store, Tx}

  @enforce_keys [:task]
  defstruct [:task]

  @type t :: %__MODULE__{task: Photon.Durable.TaskRecord.t()}

  @doc """
  Commits `fun.(tx)`, whose return value is the step's transition (see
  `Photon.Durable.Tx.transition/4`), together with everything `fun` wrote.
  Returns the transition, or `:ignored` if the task was aborted meanwhile, or
  was started again since this step began (a scheduler restart), in which
  case nothing `fun` wrote is kept.
  """
  @spec commit(t(), (Tx.t() -> Tx.transition())) :: Tx.transition() | :ignored
  def commit(%__MODULE__{task: task}, fun) do
    result =
      Store.commit(fn tx ->
        transition = fun.(tx)

        case Tx.transition(tx, task.id, transition, task) do
          :ignored -> Tx.rollback(:ignored)
          _ -> transition
        end
      end)

    case result do
      {:rolled_back, :ignored} -> :ignored
      other -> other
    end
  end

  @doc "Commits only a transition."
  @spec transition(t(), Tx.transition()) :: Tx.transition() | :ignored
  def transition(%__MODULE__{} = runtime, transition),
    do: commit(runtime, fn _tx -> transition end)
end

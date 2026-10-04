defmodule Photon.Durable.TaskKind do
  @moduledoc """
  A kind of durable task. `step/3` runs one phase: it does its work, then
  commits its transition with `Photon.Durable.Runtime.commit/2`. A step may run
  again after a crash (the task's `runs` is then above 1), so it must either
  be safe to repeat or check.

  `on_abort/2` and `on_fail/3` run inside the commit that ends the task that
  way, to undo or record its effects. `on_fail/3` may instead return
  `:retry` to run the phase again (the task's `runs` says how many times it
  has started).
  """

  alias Photon.Durable.{Runtime, TaskRecord, Tx}

  @callback step(phase :: String.t(), TaskRecord.t(), Runtime.t()) :: any()
  @callback on_abort(TaskRecord.t(), Tx.t()) :: any()
  @callback on_fail(TaskRecord.t(), reason :: String.t(), Tx.t()) :: :retry | any()

  @optional_callbacks on_abort: 2, on_fail: 3
end

defmodule Photon.MachineTools.Wait do
  @moduledoc """
  How a machine tool call waits for its op, as pure functions (sections
  3.2 and 3.3 of `docs/plans/step-1-machine-tools.md`).

  A call parks until its op's signal fires or its next check comes due.
  While the machine is online, it checks once per `check_ms` and asks for
  the op to be pushed again. While the machine is offline, the call
  remembers when it first saw that (`"offline_since"`, kept in the parked
  call's state so it survives a hub restart) and gives up once the machine
  has been offline for `offline_limit_ms`. A check never wakes later than
  that limit. The count is approximate: a machine that drops and returns
  between two checks never counts as offline.

  The op ID comes from the tool task's ID (`t_<suffix>` becomes
  `op_<suffix>`), so a call that reruns after a hub restart finds the op it
  started instead of starting another (hub rule 1). The time and the limits
  are arguments; nothing here reads the clock or the config.

  `offline_message/3` picks what the model is told when a call gives up,
  from what `Photon.Machines.abandon_tx/2` found inside the commit that
  ends it: only an op that was never pushed and never confirmed certainly
  didn't run (hub rule 7, section 2.4).
  """

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: []

  @typedoc "Unix time in milliseconds."
  @type ms :: integer()

  @typedoc "How often a parked call checks, and how long a machine may stay offline."
  @type limits :: %{check_ms: pos_integer(), offline_limit_ms: non_neg_integer()}

  @typedoc ~s{A parked call's state; this module reads and sets `"offline_since"`.}
  @type state :: %{optional(String.t()) => term()}

  @typedoc "What `Photon.Machines.abandon_tx/2` found when the call gave up."
  @type facts :: %{pushed: boolean(), confirmed: boolean(), online: boolean()}

  @doc "The op ID for a tool task: `t_<suffix>` becomes `op_<suffix>`."
  @spec op_id(String.t()) :: String.t()
  def op_id("t_" <> suffix) when suffix != "", do: "op_" <> suffix

  @doc """
  When a call that has just started its op should wake, and its
  `"offline_since"`: `now` if the machine is offline, nil if online.
  """
  @spec first(boolean(), ms(), limits()) :: {ms(), ms() | nil}
  def first(true = _online?, now, limits), do: {now + limits.check_ms, nil}
  def first(false, now, limits), do: {offline_until(now, now, limits), now}

  @doc """
  What a parked call does at a check that found its op still open: park
  until the next check, with `"offline_since"` cleared if the machine is
  online and set at the first offline sighting, or give up once the machine
  has been offline for the limit.
  """
  @spec next(state(), boolean(), ms(), limits()) :: {:park, ms(), state()} | :give_up
  def next(state, true = _online?, now, limits),
    do: {:park, now + limits.check_ms, Map.put(state, "offline_since", nil)}

  def next(state, false, now, limits) do
    since = state["offline_since"] || now

    if now - since >= limits.offline_limit_ms,
      do: :give_up,
      else: {:park, offline_until(since, now, limits), Map.put(state, "offline_since", since)}
  end

  # The next check, but never past the moment the offline limit runs out.
  defp offline_until(since, now, limits),
    do: min(now + limits.check_ms, since + limits.offline_limit_ms)

  @doc """
  What the model is told when a call on `machine` gives up after the
  machine was offline for `limit_ms`, given what the commit that ended the
  call found. It says the command didn't run only when the op was never
  pushed and never confirmed; otherwise it may have run, and the text says
  what happens to it.
  """
  @spec offline_message(String.t(), facts(), non_neg_integer()) :: String.t()
  def offline_message(machine, %{pushed: false, confirmed: false}, limit_ms),
    do:
      "#{machine} has been offline for #{duration(limit_ms)}, so the command didn't run. " <>
        "It won't run when #{machine} comes back."

  def offline_message(machine, %{online: false}, limit_ms),
    do:
      "#{machine} went offline after the command was sent and hasn't been back for " <>
        "#{duration(limit_ms)}. The command may have run, and may still be running there; " <>
        "if it is, it will be stopped when #{machine} reconnects."

  def offline_message(machine, %{online: true}, limit_ms),
    do:
      "#{machine} was offline for #{duration(limit_ms)} and has just come back. " <>
        "The command may have started; it is being stopped."

  # "10 minutes", "1 minute", "30 seconds" or "250 milliseconds".
  defp duration(ms) when ms >= 60_000 and rem(ms, 60_000) == 0,
    do: count(div(ms, 60_000), "minute")

  defp duration(ms) when ms >= 1_000 and rem(ms, 1_000) == 0, do: count(div(ms, 1_000), "second")
  defp duration(ms), do: count(ms, "millisecond")

  defp count(1, unit), do: "1 #{unit}"
  defp count(n, unit), do: "#{n} #{unit}s"
end

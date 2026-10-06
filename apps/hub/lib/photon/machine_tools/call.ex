defmodule Photon.MachineTools.Call do
  @moduledoc """
  One `shell` or `view_image` call, which `Photon.MachineTools.Shell` and
  `Photon.MachineTools.ViewImage` share (section 3.2 of
  `docs/plans/step-1-machine-tools.md`).

  `execute/3` checks the arguments (`Photon.MachineTools.Translate`),
  derives the op ID from the call's task (`Photon.MachineTools.Wait`),
  asks `Photon.Machines` about the machine, commits the op and parks on
  the op's signal. A rerun after a hub restart that finds the op's row
  already there skips the machine check and parks again (hub rule 10): the
  op may be running, whatever the machine looks like now.

  `resume/2` runs when the signal fires or a check comes due. A finished op
  is claimed in the commit that records the result (hub rule 8). An open
  one waits on: while the machine is online the call asks for the op to be
  pushed again at each check (hub rule 11); while it is offline the call
  counts how long, and gives up past the limit, canceling the op in the
  same commit and saying what may have happened (hub rule 7). `resume/2`
  only reads before its final commit, so a rerun is harmless.

  Every error result from the op ID on, and every interruption
  (`on_interrupt/2`: Stop, a failed task, or a raise), cancels the op in
  the commit that ends the call (`Photon.Machines.cancel_tx/2`, a no-op
  without a row), so no op is left for the next join to start after the
  model was told the call failed.

  The check interval and the offline limit come from `config :photon,
  Photon.MachineTools, check_ms: ..., offline_limit_ms: ...`.
  """

  alias Photon.Durable.{Tool, ToolAPI, Tx}
  alias Photon.Machines
  alias Photon.MachineTools.{Translate, Wait}

  @check_ms 60_000
  @offline_limit_ms 600_000

  @doc "Runs a call of `kind` (shell or view_image) with the model's `args`."
  @spec execute(String.t(), map(), ToolAPI.t()) :: Tool.result()
  def execute(kind, args, api) do
    case op_args(kind, args) do
      {:ok, op_args} -> start(kind, args["machine"], op_args, api)
      {:error, message} -> {:error, message}
    end
  end

  defp op_args("shell", args), do: Translate.shell_args(args)
  defp op_args("view_image", args), do: Translate.view_image_args(args)

  defp start(kind, machine, op_args, api) do
    op_id = Wait.op_id(ToolAPI.task_id(api))

    with :ok <- check(machine, op_id),
         :ok <- Machines.start(new(op_id, kind, machine, op_args, api)) do
      park(op_id, kind, machine, op_args)
    else
      {:error, :stopped} -> fail(op_id, "The call was stopped before it reached #{machine}.")
      {:error, message} -> fail(op_id, message)
    end
  end

  # A rerun whose op is already recorded skips the machine check.
  defp check(machine, op_id) do
    if Machines.op_state(op_id) == :none, do: check(machine), else: :ok
  end

  defp check(machine) do
    case Machines.status(machine) do
      status when status in [:online, :offline] ->
        :ok

      :outdated ->
        {:error, Translate.outdated_machine(machine)}

      :unknown ->
        {:error, Translate.unknown_machine(machine, Enum.map(Machines.roster(), & &1.id))}
    end
  end

  defp new(op_id, kind, machine, op_args, api) do
    %{
      id: op_id,
      machine: machine,
      kind: kind,
      args: op_args,
      task_id: ToolAPI.task_id(api),
      conversation_id: api.conversation_id,
      call_id: ToolAPI.call_id(api)
    }
  end

  defp park(op_id, kind, machine, op_args) do
    {until, offline_since} = Wait.first(online?(machine), now(), limits())

    state = %{
      "op_id" => op_id,
      "machine" => machine,
      "kind" => kind,
      "summary" => op_args["command"] || op_args["path"],
      "offline_since" => offline_since
    }

    wait(state, until)
  end

  defp wait(state, until),
    do: {:wait, %{"signal" => Machines.signal_key(state["op_id"]), "until" => until}, state}

  @doc "Continues a parked call: claims its result, waits on, or gives up."
  @spec resume(map(), ToolAPI.t()) :: Tool.result()
  def resume(%{"op_id" => op_id} = state, _api) do
    case Machines.op_state(op_id) do
      {:finished, _snapshot} -> {:commit, &claim(&1, state)}
      {:open, _confirmed?} -> check_again(state)
      :closed -> fail(op_id, delivered())
      :none -> fail(op_id, "The hub has no record of this operation on #{state["machine"]}.")
    end
  end

  defp check_again(%{"op_id" => op_id, "machine" => machine} = state) do
    online? = online?(machine)
    limits = limits()

    case Wait.next(state, online?, now(), limits) do
      {:park, until, state} ->
        # Offline or gone since is fine: the next check sees it, and a join
        # pushes every open op anyway.
        _ = if online?, do: Machines.repush(op_id)
        wait(state, until)

      :give_up ->
        {:commit, &abandon(&1, state, limits)}
    end
  end

  defp claim(tx, %{"op_id" => op_id} = state) do
    case Machines.claim_tx(tx, op_id) do
      nil -> canceled(tx, op_id, delivered())
      snapshot -> result(state, snapshot)
    end
  end

  defp abandon(tx, %{"op_id" => op_id, "machine" => machine} = state, limits) do
    case Machines.abandon_tx(tx, op_id) do
      {:claimed, snapshot} ->
        result(state, snapshot)

      {:abandoned, facts} ->
        {:error, Wait.offline_message(machine, facts, limits.offline_limit_ms)}
    end
  end

  defp result(%{"kind" => kind, "machine" => machine}, snapshot),
    do:
      {:ok, Translate.result(kind, snapshot, machine), Translate.details(kind, snapshot, machine)}

  defp delivered, do: "This result was already delivered."

  @doc """
  Cancels the call's op in the commit that ends the call without a result
  from the tool: Stop, a failed task, or a raise (hub rule 7).
  """
  @spec on_interrupt(ToolAPI.t(), Tx.t()) :: :ok
  def on_interrupt(api, tx), do: Machines.cancel_tx(tx, Wait.op_id(ToolAPI.task_id(api)))

  # An error result whose commit also cancels the op, if there is one (hub
  # rule 10).
  defp fail(op_id, message), do: {:commit, &canceled(&1, op_id, message)}

  defp canceled(tx, op_id, message) do
    :ok = Machines.cancel_tx(tx, op_id)
    {:error, message}
  end

  defp online?(machine), do: Machines.status(machine) == :online

  defp now, do: System.system_time(:millisecond)

  defp limits do
    config = Application.get_env(:photon, Photon.MachineTools, [])

    %{
      check_ms: Keyword.get(config, :check_ms, @check_ms),
      offline_limit_ms: Keyword.get(config, :offline_limit_ms, @offline_limit_ms)
    }
  end
end

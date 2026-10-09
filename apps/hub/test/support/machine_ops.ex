defmodule Photon.MachineOps do
  @moduledoc """
  Builders for tests of `Photon.Machines` and the node channel's operation
  messages: a live tool task to hang an op on, the op that task would start,
  and snapshot payloads as a node sends them.
  """

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  alias Photon.Durable
  alias Photon.Durable.Tx

  @doc """
  An unfinished task in a fresh conversation, waiting on a signal that
  never fires, so the scheduler leaves it alone. Ops may be inserted for it.
  """
  def live_task do
    conversation = Durable.create_conversation("test")

    Durable.commit(
      &Tx.create_task(&1, %{
        kind: "generation",
        conversation_id: conversation.id,
        phase: "after_tools",
        waiting: %{"signal" => "never"}
      })
    )
  end

  @doc "The op ID a tool task derives: `t_<suffix>` becomes `op_<suffix>`."
  def op_id("t_" <> suffix), do: "op_" <> suffix

  @doc "The op a shell call in `task` would start on `machine`."
  def new_op(task, machine, command \\ "echo hi") do
    %{
      id: op_id(task.id),
      machine: machine,
      kind: "shell",
      args: %{"command" => command, "directory" => nil, "max_output_length" => 40_000},
      task_id: task.id,
      conversation_id: task.conversation_id,
      call_id: "call_" <> task.id
    }
  end

  @doc "A live task and its op on `machine`, started with `Photon.Machines.start/1`."
  def started(machine) do
    task = live_task()
    op = new_op(task, machine)
    :ok = Photon.Machines.start(op)
    {task, op}
  end

  @doc "An `op.snapshot` payload for op `id` with `status`."
  def snapshot(id, status, state \\ %{}) do
    %{
      "op" => %{
        "id" => id,
        "type" => "shell",
        "version" => 1,
        "status" => status,
        "max_output_length" => 40_000,
        "state" => state
      }
    }
  end

  @doc "Registers the calling process as `machine`'s connection, speaking the op protocol."
  def connect(machine, capabilities \\ ["ops:2"]),
    do:
      Photon.Machines.register(machine, %{"hostname" => machine, "capabilities" => capabilities})

  @doc """
  Registers the calling process as `machine`, a connected machine that takes
  commands and never answers, so a shell call on it waits until it is
  stopped. Registering again from the same process changes nothing.
  """
  def fake_machine(machine) do
    case Registry.lookup(Photon.MachineRegistry, machine) do
      [{owner, _info}] when owner == self() ->
        :ok

      _other ->
        Photon.Machines.register(machine, %{
          "platform" => "test",
          "workspace" => "/w",
          "version" => "0",
          "capabilities" => ["ops:2"]
        })
    end
  end
end

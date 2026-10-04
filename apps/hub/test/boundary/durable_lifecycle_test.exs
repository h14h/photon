defmodule Photon.DurableLifecycleTest do
  @moduledoc """
  The durable harness's processes under `Photon.Durable.Supervisor`, as the
  application starts them: which children run, and what a crash restarts.
  """

  use Photon.DataCase, async: false

  import Photon.Eventually

  alias Photon.Durable.{Scheduler, Store}

  setup do
    %{supervisor: start_supervised!(Photon.Durable.Supervisor)}
  end

  test "runs the task supervisor, the store and the scheduler", %{supervisor: supervisor} do
    ids = for {id, pid, _, _} <- Supervisor.which_children(supervisor), is_pid(pid), do: id

    assert Enum.sort(ids) == [
             Photon.Durable.Scheduler,
             Photon.Durable.Store,
             Photon.Durable.TaskSupervisor
           ]
  end

  test "a scheduler crash restarts the scheduler alone; work goes on" do
    store = Process.whereis(Store)
    scheduler = Process.whereis(Scheduler)
    ref = Process.monitor(scheduler)

    Process.exit(scheduler, :kill)
    assert_receive {:DOWN, ^ref, :process, ^scheduler, :killed}

    assert eventually(fn ->
             pid = Process.whereis(Scheduler)
             pid != scheduler && pid
           end)

    assert Process.whereis(Store) == store

    c = Durable.create_conversation("test").id
    Durable.subscribe(c)
    {:ok, s} = Durable.submit(c, "hello")
    assert %{status: "done"} = await_settled(c, s.id)
  end
end

defmodule Photon.SessionsTest do
  use ExUnit.Case

  alias Photon.Sessions

  setup do
    File.rm_rf!(Photon.Paths.data_dir())
    :ets.delete_all_objects(Sessions.counts_table())
    :ok
  end

  test "ingests events in offset order, once" do
    %{"id" => id} = Sessions.create("t", "n1")
    Phoenix.PubSub.subscribe(Photon.PubSub, Sessions.topic(id))

    assert Sessions.ingest(id, "n1", 0, %{"a" => 0}) == :ok
    assert_receive {:runner_event, ^id, %{"a" => 0}}
    assert Sessions.ingest(id, "n1", 0, %{"a" => 0}) == :duplicate
    assert Sessions.ingest(id, "n1", 2, %{"a" => 2}) == {:gap, 1}
    assert Sessions.ingest(id, "n1", 1, %{"a" => 1}) == :ok
    assert Sessions.events(id) == [%{"a" => 0}, %{"a" => 1}]
    assert Sessions.sync_for("n1") == %{id => 2}
  end

  test "ignores events for unknown sessions or from other nodes" do
    %{"id" => id} = Sessions.create("t", "n1")
    assert Sessions.ingest(id, "n2", 0, %{}) == :ignored
    assert Sessions.ingest("00000000-0000-4000-8000-000000000000", "n1", 0, %{}) == :ignored
  end

  test "assigns pre-node sessions to the local node, offsetting their history" do
    %{"id" => id} = Sessions.create("old", "local")
    Sessions.append_events(id, [%{"old" => 1}, %{"old" => 2}])
    path = Path.join([Photon.Paths.sessions_dir(), id, "meta.json"])

    File.write!(
      path,
      path
      |> File.read!()
      |> Jason.decode!()
      |> Map.drop(["node", "event_base"])
      |> Jason.encode!()
    )

    assert %{"node" => "local", "event_base" => 2} = Sessions.get(id)
    assert Sessions.sync_for("local") == %{id => 0}
    assert Sessions.ingest(id, "local", 0, %{"new" => 1}) == :ok
    assert length(Sessions.events(id)) == 3
  end
end

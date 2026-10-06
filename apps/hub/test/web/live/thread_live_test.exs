defmodule PhotonWeb.ThreadLiveTest do
  @moduledoc "A project's threads: starting one and its conversation."

  use PhotonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Photon.{Projects, Threads}

  @moduletag :durable

  setup do
    {:ok, project} =
      Projects.create(%{"purpose" => "Keep the garden watered.", "name" => "Garden"})

    %{project: project}
  end

  # Starts a thread and waits until it has answered, so no run outlives the test.
  defp idle_thread!(project, text) do
    {:ok, thread} = Threads.start(project.id, text)
    :ok = Threads.subscribe(thread.id)

    if Threads.busy?(thread.id),
      do: await_change(thread.id, fn _changes -> not Threads.busy?(thread.id) end)

    thread
  end

  test "the new-thread page mounts", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/threads/new")
    assert view |> element("#thread-new-heading") |> render() =~ "New thread in Garden"
    assert has_element?(view, ~s(#thread-project[href="/projects/garden"]))
  end

  test "a thread's page shows its title", %{conn: conn, project: project} do
    thread = idle_thread!(project, "Fix the pump")
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/threads/#{thread.id}")
    assert view |> element("#thread-title") |> render() =~ "Fix the pump"
  end

  test "an unknown project or thread, or a thread under another project, goes home",
       %{conn: conn, project: project} do
    {:ok, other} = Projects.create(%{"purpose" => "Plan the trip.", "name" => "Trip"})
    thread = idle_thread!(project, "Fix the pump")

    for {path, message} <- [
          {~p"/projects/orchard/threads/new", "There's no project called orchard."},
          {~p"/projects/orchard/threads/#{thread.id}", "There's no project called orchard."},
          {~p"/projects/#{project.slug}/threads/c_none", "There's no such thread in Garden."},
          {~p"/projects/#{other.slug}/threads/#{thread.id}", "There's no such thread in Trip."}
        ] do
      assert {:error, {:live_redirect, %{to: "/", flash: flash}}} = live(conn, path)
      assert flash["error"] == message
    end
  end
end

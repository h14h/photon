defmodule PhotonWeb.ProjectTextTest do
  @moduledoc "The project pages' words for times, sizes and who changed a file."

  use Photon.Case, async: true

  alias Photon.Projects.ContextFile
  alias PhotonWeb.ProjectText

  @now ~U[2026-10-06 12:00:00Z]

  defp before(seconds), do: DateTime.add(@now, -seconds)

  test "ago/2 counts minutes, hours and days, then names the date" do
    assert ProjectText.ago(before(10), @now) == "just now"
    assert ProjectText.ago(before(60), @now) == "1 minute ago"
    assert ProjectText.ago(before(5 * 60), @now) == "5 minutes ago"
    assert ProjectText.ago(before(3 * 3600), @now) == "3 hours ago"
    assert ProjectText.ago(before(30 * 3600), @now) == "yesterday"
    assert ProjectText.ago(before(4 * 86_400), @now) == "4 days ago"
    assert ProjectText.ago(~U[2026-03-04 09:00:00Z], @now) == "on Mar 4"
    assert ProjectText.ago(~U[2025-03-04 09:00:00Z], @now) == "on Mar 4, 2025"
    assert ProjectText.ago(DateTime.add(@now, 30), @now) == "just now"
  end

  test "changed/3 names the user, or the thread the change was made in" do
    file = %ContextFile{updated_by: "owner", updated_at: before(5 * 60)}
    assert ProjectText.changed(file, %{}, @now) == "changed 5 minutes ago by you"

    by_thread = %{file | updated_by: "c_1"}

    assert ProjectText.changed(by_thread, %{"c_1" => "Fix the pump"}, @now) ==
             "changed 5 minutes ago in Fix the pump"

    assert ProjectText.writer(by_thread, %{"c_1" => "Fix the pump"}) ==
             {:in, %{id: "c_1", title: "Fix the pump"}}

    assert ProjectText.changed(by_thread, %{}, @now) == "changed 5 minutes ago by a thread"
    assert ProjectText.writer(by_thread, %{}) == {:by, "a thread"}
    assert ProjectText.changed_at(by_thread, @now) == "changed 5 minutes ago"
  end

  test "changed/3 names Blip, without looking it up as a thread" do
    file = %ContextFile{updated_by: "blip", updated_at: before(5 * 60)}

    assert ProjectText.changed(file, %{}, @now) == "changed 5 minutes ago by Blip"
    assert ProjectText.writer(file, %{"blip" => "Not Blip"}) == {:by, "Blip"}
  end

  test "size/1 in bytes, KB and MB" do
    assert ProjectText.size("") == "Empty"
    assert ProjectText.size("hello") == "5 B"
    assert ProjectText.size(String.duplicate("a", 4_200)) == "4.2 KB"
    assert ProjectText.size(String.duplicate("a", 42_000)) == "42 KB"
    assert ProjectText.size(String.duplicate("a", 1_100_000)) == "1.1 MB"
  end
end

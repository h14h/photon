defmodule Photon.AttachmentsTest do
  use ExUnit.Case, async: true

  alias Photon.Attachments

  test "names uploads safely inside .attachments" do
    path = Attachments.workspace_path("../../My Screen Shot (2).PNG", "3")
    assert path =~ ~r/\A\.attachments\/\d{8}-\d{6}-3-My-Screen-Shot-2\.png\z/
    assert Attachments.valid_path?(path)
    assert Attachments.workspace_path("weird.exe", 0) =~ ~r/\.png\z/
  end

  test "rejects anything that could leave the attachments directory" do
    for bad <- [
          "../x.png",
          ".attachments/../x.png",
          ".attachments/a/b.png",
          "/etc/x.png",
          ".attachments/x.sh"
        ] do
      refute Attachments.valid_path?(bad), bad
    end
  end

  test "adds a note for the agent, and splits it back out for display" do
    paths = [".attachments/20260923-120000-0-cat.png", ".attachments/20260923-120000-1-dog.jpg"]
    prompt = Attachments.with_note("What's in these?", paths)

    assert prompt =~ "open them with ViewImage"
    assert Attachments.split(prompt) == {"What's in these?", paths}
    assert Attachments.split(Attachments.with_note("", paths)) == {"", paths}
    assert Attachments.with_note("plain", []) == "plain"
    assert Attachments.split("no note here") == {"no note here", []}
  end
end

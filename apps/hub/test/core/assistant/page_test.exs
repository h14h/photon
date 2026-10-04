defmodule Photon.Assistant.PageTest do
  @moduledoc "The page the user had open when they wrote to Blip."

  use Photon.Case, async: true

  @session %{id: "ns_1", node_id: "kepler", title: "Nightly backup"}

  test "a node session's page names it; other pages name nothing" do
    assert Page.session_id("/sessions/ns_1") == "ns_1"

    for path <- ["/", "/nodes", "/sessions/", "/sessions/ns_1/edit"],
        do: assert(Page.session_id(path) == nil)
  end

  test "reads as the node and the session's title" do
    assert Page.label(Page.of_session(@session)) == "kepler / Nightly backup"
    assert Page.label(Page.of_session(%{@session | title: nil})) == "kepler"
  end

  test "goes in front of the message as a note, and comes off again" do
    page = Page.of_session(@session)
    noted = Page.note("why did this fail?", page)

    assert noted ==
             "[Looking at kepler's session \"Nightly backup\" (session ns_1)]\n\nwhy did this fail?"

    assert Page.strip(noted) == "why did this fail?"
    assert Page.note("hi", nil) == "hi"
  end

  test "strips only a note it put there" do
    assert Page.strip("plain\n\ntext") == "plain\n\ntext"
    assert Page.strip("[Looking at nothing]") == "[Looking at nothing]"
  end

  test "the transcript shows a message from a page as it was typed" do
    noted = Page.note("this one", Page.of_session(@session))

    assert Transcript.typed(noted, %{"kind" => "user", "page" => %{}}) == "this one"
    assert Transcript.typed(noted, %{"kind" => "user"}) == noted
    assert Transcript.typed("hi", nil) == "hi"
  end
end

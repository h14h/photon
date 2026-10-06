defmodule Photon.Threads.MockTitleTest do
  @moduledoc "The scripted model's titles for threads (section 2.4)."

  use Photon.Case, async: true

  alias Photon.Threads.{MockTitle, Rules}

  defp title(first_message) do
    first_message
    |> Rules.title_request("Done.")
    |> MockTitle.respond()
    |> Message.text_of()
  end

  test "names the work in the scripted thread's phrasings" do
    assert title("machines") == "Check your machines"
    assert title("files") == "Check the context files"
    assert title("read notes.md") == "Read notes.md"
    assert title("write plan.md: # Plan\nWater daily.") == "Write plan.md"
    assert title("edit notes.md: 71% => 64%") == "Edit notes.md"
    assert title("on mm1: look at shots/pump.png") == "Look at pump.png on mm1"
  end

  test "names a command by the first program it runs" do
    assert title("on local: $ df -h /; for i in 1 2 3; do echo ok; done") == "Run df on local"
    assert title("on mm1: $ sudo /usr/bin/apt update && apt upgrade") == "Run apt on mm1"
    assert title("on mm1: $ for i in $(seq 1 60); do echo tick; done") == "Run echo on mm1"
    assert title("on mm1: $ LANG=C ls") == "Run ls on mm1"
    assert title("on mm1: $ for x in a; do") == "Run a command on mm1"
  end

  test "names a schedule's prompt as it names the same message typed" do
    assert title("[Scheduled] on local: $ df -h /") == "Run df on local"
    assert title("[Scheduled] read notes.md") == "Read notes.md"
  end

  test "otherwise takes the first five words, capitalized" do
    assert title("fix the pump in zone 2 before Friday\nthanks") == "Fix the pump in zone"
    assert title("## `API` keys rotate") == "API keys rotate"
  end

  test "answers nothing but a title request" do
    assert {:error, _} = MockTitle.respond(%{messages: [Message.user("read notes.md")]})
    assert {:error, _} = MockTitle.respond(%{})
  end
end

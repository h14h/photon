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

  test "names a command by what it runs, past sudo and variable settings" do
    assert title("on local: $ df -h /") == "Run df on local"
    assert title("on mm1: $ sudo /usr/bin/apt update && apt upgrade") == "Run apt on mm1"
    assert title("on mm1: $ LANG=C ls") == "Run ls on mm1"
    assert title("on mm1: $ FOO=1") == "Run a command on mm1"
  end

  test "names a loop or a condition as a whole, not what runs inside it" do
    assert title("on local: $ for i in 1 2 3; do echo $i; done") == "Run a for loop on local"
    assert title("on mm1: $ for i in $(seq 1 60); do echo tick; done") == "Run a for loop on mm1"
    assert title("on mm1: $ for x in a; do") == "Run a for loop on mm1"
    assert title("on mm1: $ while true; do date; sleep 1; done") == "Run a while loop on mm1"
    assert title("on mm1: $ until ping -c1 nas; do sleep 5; done") == "Run an until loop on mm1"

    assert title("on mm1: $ if [ -f /etc/hosts ]; then cat /etc/hosts; fi") ==
             "Run an if statement on mm1"

    assert title("on mm1: $ case $1 in a) echo a;; esac") == "Run a case statement on mm1"

    # Nested: the outer loop is what runs.
    assert title("on mm1: $ for a in 1 2; do for b in 3 4; do echo $a$b; done; done; uptime") ==
             "Run a for loop and uptime on mm1"
  end

  test "names what a pipeline or a chain runs, each once" do
    assert title("on mm1: $ ps aux | grep beam") == "Run ps and grep on mm1"
    assert title("on mm1: $ cd /srv && git pull && make") == "Run cd, git and more on mm1"
    assert title("on mm1: $ cat log | grep x | grep -v y") == "Run cat and grep on mm1"

    assert title("on local: $ df -h /; for i in 1 2 3; do echo ok; done") ==
             "Run df and a for loop on local"

    assert title("on mm1: $ ls | while read f; do echo $f; done") ==
             "Run ls and a while loop on mm1"
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

  test "names the run endings and questions for Blip" do
    assert title("ask me: which zone should I water first?") ==
             "Ask you about which zone should I water"

    assert title("ask me: valves?") == "Ask you about valves"

    assert title("ask blip: which deploy branch should I use?") ==
             "Ask Blip about which deploy branch should I"

    assert title("[Scheduled] ask blip: gate?") == "Ask Blip about gate"
    assert title("fail: the pump is unplugged") == "Fail on purpose"
  end
end

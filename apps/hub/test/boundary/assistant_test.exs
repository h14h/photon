defmodule Photon.AssistantTest do
  @moduledoc """
  The assistant through its API (`Photon.Assistant`) with its mock model:
  its tools (a connected node is played by the test process, which
  registers under the node's name), schedules, and the page under Blip.
  """

  use Photon.DataCase, async: false

  import Photon.ConversationHelpers
  import Photon.ProjectHelpers
  import Photon.MachineOps, only: [fake_machine: 1]

  @moduletag :durable

  alias Photon.{Assistant, Projects, Schedules}
  alias Photon.Durable.Submission
  alias Photon.Schedules.Schedule

  setup do
    conversation = Assistant.conversation_id()
    Durable.subscribe(conversation)
    {:ok, conversation: conversation}
  end

  test "conversation_id/0 is Blip's conversation, which Photon.Signals finds", %{
    conversation: c
  } do
    assert Photon.Signals.blip_conversation_id() == c
    assert Assistant.conversation_id() == c
    assert %Photon.Durable.Conversation{profile: "assistant"} = Durable.conversation(c)
  end

  describe "ambient mode" do
    defp ambient!(on?),
      do: _doc = Durable.commit(&Photon.Signals.put_ambient_doc_tx(&1, %{"on" => on?}))

    # The prompt up to its time, which names the hour.
    defp prompt, do: hd(String.split(Assistant.system_prompt(nil), "\n\n## Now"))

    test "the prompt has the Ambient mode section only while it is on; the tools stay" do
      off_prompt = prompt()
      off_tools = Enum.map(Assistant.tools(nil), & &1.name())
      refute off_prompt =~ "## Ambient mode"

      ambient!(true)
      on_prompt = prompt()
      assert on_prompt =~ "## Ambient mode"
      assert on_prompt =~ ~s(A message starting with "[Digest]")
      assert Enum.map(Assistant.tools(nil), & &1.name()) == off_tools

      ambient!(false)
      assert prompt() == off_prompt
    end
  end

  describe "tools" do
    test "lists machines", %{conversation: c} do
      fake_machine("box")
      {:ok, s} = Assistant.send("machines")
      await_settled(c, s.id)
      assert [result] = texts(c, "tool_result")
      assert result =~ "- box: online, test, workspace /w, photon-node 0"
    end

    test "remembers facts", %{conversation: c} do
      {:ok, s} = Assistant.send("remember the NAS is mp1")
      await_settled(c, s.id)
      assert Assistant.memory() =~ "the NAS is mp1"
      assert Assistant.system_prompt(nil) =~ "the NAS is mp1"
    end

    test "searches the web itself: the model gets OpenAI's web search", %{conversation: c} do
      llm = Assistant.llm(%{id: c})
      assert llm.config.hosted_tools == [%{"type" => "web_search"}]
      assert llm.cache_key == c
    end

    test "schedules fire into the conversation", %{conversation: c} do
      {:ok, s} = Assistant.send("in 0 minutes: machines")
      await_settled(c, s.id)

      entry = await_entry(c, &(&1.data["source"]["kind"] == "routine"), 10_000)
      assert PhotonCore.Message.text_of(entry.data["message"]) == "[Scheduled] machines"
    end

    test "without consent to use the plan while away, a schedule leaves a note instead", %{
      conversation: c
    } do
      Photon.TestConfig.put_env(:photon, :mock_model, false)

      now = System.system_time(:millisecond)

      {:ok, schedule} =
        Durable.commit(
          &Schedules.tool_schedule_tx(
            &1,
            {:blip, c},
            %{"prompt" => "check disks", "in_minutes" => 0},
            %{asked_by: "owner", request_id: "schedule:t_x", now: now}
          )
        )

      note = await_entry(c, &(&1.kind == "error"), 10_000)
      assert note.data["notice"]
      assert note.data["message"] =~ ~s{Skipped "check disks"}
      refute Enum.any?(Durable.entries(c), &(&1.data["source"]["kind"] == "routine"))
      assert %{last_outcome: "skipped_consent"} = Repo.get!(Schedule, schedule.id)
    end

    test "Stop withdraws the user's queued messages and keeps scheduled prompts, signals and answers",
         %{conversation: c} do
      fake_machine("box")
      {:ok, first} = Assistant.send("on box: $ sleep 30")
      assert Durable.busy?(c)

      {:ok, mine} = Assistant.send("and also this")

      {:ok, scheduled} =
        Durable.submit(c, "[Scheduled] hello",
          source: %{"kind" => "routine", "schedule_id" => "sc_hello"}
        )

      {:ok, signal} =
        Durable.submit(c, "[Thread update] Garden / \"Fix the pump\" (c_1) finished.",
          source: %{"kind" => "signal", "signals" => [%{"kind" => "thread_update"}]}
        )

      {:ok, answer} =
        Durable.submit(c, "green", source: %{"kind" => "answer", "question_id" => "q_1"})

      kept = [scheduled, signal, answer]
      assert Enum.map([mine | kept], & &1.status) == List.duplicate("queued", 4)
      assert Enum.all?(kept, &Submission.background?/1)
      refute Submission.background?(mine)

      Assistant.stop()
      assert %{status: "unanswered"} = await_settled(c, first.id)
      assert Repo.get!(Submission, mine.id).status == "withdrawn"

      # The kept input runs once the stopped run has ended, one at a time.
      for submission <- kept, do: assert(%{status: "done"} = await_settled(c, submission.id))
    end
  end

  describe "the page under Blip" do
    setup do
      garden = garden!()

      {:ok, shed} = Projects.create(%{"name" => "Shed", "purpose" => "Fix the shed roof."})

      {:ok, _file} =
        Projects.create_file(garden.id, %{"name" => "notes.md", "content" => "Zone 2."})

      thread = idle_thread!(garden, "Fix the pump")
      %{garden: garden, shed: shed, thread: thread}
    end

    test "page_at/1 gives a project's page, a file's and a thread's", %{garden: g, thread: t} do
      assert %{"kind" => "project", "project_id" => id, "label" => "Garden"} =
               Assistant.page_at("/projects/garden")

      assert id == g.id
      assert Assistant.page_at("/projects/garden/threads/new")["label"] == "Garden"
      assert Assistant.page_at("/projects/garden/files/new")["label"] == "Garden"

      # Found case-insensitively, labelled with its own name.
      assert %{"kind" => "file", "file" => "notes.md", "label" => "Garden / notes.md"} =
               Assistant.page_at("/projects/garden/files/NOTES.md")

      assert %{"kind" => "thread", "thread_id" => thread_id, "label" => "Garden / Fix the pump"} =
               Assistant.page_at("/projects/garden/threads/#{t.id}")

      assert thread_id == t.id
    end

    test "page_at/1 gives nil for what doesn't exist, and outside projects", %{thread: t} do
      assert Assistant.page_at("/projects/garden/files/missing.md") == nil
      assert Assistant.page_at("/projects/shed/threads/#{t.id}") == nil
      assert Assistant.page_at("/projects/nowhere") == nil
      assert Assistant.page_at("/projects/nowhere/threads/#{t.id}") == nil
      assert Assistant.page_at("/projects/new") == nil
      assert Assistant.page_at("/nodes") == nil
    end

    test "send/2 with a page sends its note, then the message, with the page in source", %{
      conversation: c,
      thread: t
    } do
      page = Assistant.page_at("/projects/garden/threads/#{t.id}")
      {:ok, s} = Assistant.send("here", page: page)
      await_settled(c, s.id)

      user = Enum.find(Durable.entries(c), &(&1.kind == "user"))
      assert [%{"text" => note}, %{"text" => "here"}] = user.data["message"]["content"]
      assert user.data["source"] == %{"kind" => "user", "page" => page}

      [first | rest] = String.split(note, "\n")

      assert first ==
               ~s([Looking at the thread "Fix the pump" in the project "Garden", folder "garden" in each machine's workspace])

      assert "Purpose: Keep the garden watered." in rest
      assert "Context files: notes.md" in rest
      assert Enum.any?(rest, &String.starts_with?(&1, "The thread is idle. Its latest answer:"))

      # The scripted model reads only what was typed, and says the note's first line.
      assert texts(c, "assistant") == [first]
    end

    test "send/2 reads a file's page fresh, with the content as last saved", %{
      conversation: c,
      garden: g
    } do
      page = Assistant.page_at("/projects/garden/files/notes.md")
      {:ok, _} = Projects.save_file(g.id, "notes.md", "Zone 2 valve: replaced.", 1)
      {:ok, _} = Projects.update(g.id, %{"name" => "Back garden", "purpose" => g.purpose})

      {:ok, s} = Assistant.send("what's missing?", page: page)
      await_settled(c, s.id)

      user = Enum.find(Durable.entries(c), &(&1.kind == "user"))
      assert [%{"text" => note}, %{"text" => "what's missing?"}] = user.data["message"]["content"]
      assert note =~ "-----\nZone 2 valve: replaced.\n-----"
      assert note =~ ~s(in the project "Back garden")
      assert user.data["source"]["page"]["label"] == "Back garden / notes.md"
    end

    test "send/2 without a page sends the message alone", %{conversation: c} do
      {:ok, s} = Assistant.send("here", page: nil)
      await_settled(c, s.id)

      user = Enum.find(Durable.entries(c), &(&1.kind == "user"))
      assert [%{"text" => "here"}] = user.data["message"]["content"]
      assert user.data["source"] == %{"kind" => "user"}
      assert texts(c, "assistant") == ["I don't know which page you're on."]
    end
  end
end

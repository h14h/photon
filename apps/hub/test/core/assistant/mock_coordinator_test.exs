defmodule Photon.Assistant.MockCoordinatorTest do
  @moduledoc """
  The scripted Blip's phrasings for its tools over projects and threads
  (section 8.2 of `docs/plans/step-4-blip-as-coordinator.md`), on their
  own and through `Photon.Assistant.MockScript`, which tries them.
  """

  use Photon.Case, async: true

  alias Photon.Assistant.{MockCoordinator, MockScript}

  defp ask(text), do: MockScript.respond(%{messages: [Message.user(text)]})

  defp calls(message), do: Enum.map(Message.tool_calls(message), &{&1["name"], args(&1)})

  defp args(call) do
    {:ok, args} = Message.arguments(call)
    args
  end

  test "the read phrasings call the read tools" do
    for {text, call} <- [
          {"projects", {"list_projects", %{}}},
          {"list projects", {"list_projects", %{}}},
          {"project garden", {"read_project", %{"project" => "garden"}}},
          {"threads", {"list_threads", %{}}},
          {"threads in garden", {"list_threads", %{"project" => "garden"}}},
          {"read thread c_123", {"read_thread", %{"thread" => "c_123"}}}
        ] do
      assert calls(ask(text)) == [call], text
    end
  end

  test "the phrasings that start and stop work call their tools" do
    for {text, call} <- [
          {"start project: Keep the beds watered.",
           {"start_project", %{"purpose" => "Keep the beds watered."}}},
          {"start thread in garden: on local: $ echo hi",
           {"start_thread", %{"project" => "garden", "message" => "on local: $ echo hi"}}},
          {"tell c_123: check the pump again",
           {"message_thread", %{"thread" => "c_123", "message" => "check the pump again"}}},
          {"stop thread c_123", {"stop_thread", %{"thread" => "c_123"}}}
        ] do
      assert calls(ask(text)) == [call], text
    end
  end

  test "the file phrasings name a project and a file, and call the file tools" do
    for {text, call} <- [
          {"files in garden", {"list_context_files", %{"project" => "garden"}}},
          {"read garden/notes.md",
           {"read_context_file", %{"project" => "garden", "name" => "notes.md"}}},
          {"write garden/notes.md: # Beds\n\nWater zone 2.",
           {"write_context_file",
            %{"project" => "garden", "name" => "notes.md", "content" => "# Beds\n\nWater zone 2."}}},
          {"edit garden/notes.md: zone 2 => zone 3",
           {"edit_context_file",
            %{
              "project" => "garden",
              "name" => "notes.md",
              "old_text" => "zone 2",
              "new_text" => "zone 3"
            }}}
        ] do
      assert calls(ask(text)) == [call], text
    end

    # A thread is read by its ID, never as a file.
    assert calls(ask("read thread c_123")) == [{"read_thread", %{"thread" => "c_123"}}]
  end

  test "the schedule and skill phrasings name a project" do
    for {text, call} <- [
          {"in 5 minutes in garden: check the pump",
           {"schedule", %{"prompt" => "check the pump", "in_minutes" => 5, "project" => "garden"}}},
          {"every 60 minutes in garden: water zone 2",
           {"schedule",
            %{"prompt" => "water zone 2", "every_minutes" => 60, "project" => "garden"}}},
          {"schedules in garden", {"list_schedules", %{"project" => "garden"}}},
          {"cancel schedule sc_9", {"cancel_schedule", %{"schedule_id" => "sc_9"}}},
          {"all skills", {"list_skills", %{}}},
          {"turn on pdf-forms in garden",
           {"set_project_skill", %{"project" => "garden", "skill" => "pdf-forms", "on" => true}}},
          {"turn off pdf-forms in garden",
           {"set_project_skill", %{"project" => "garden", "skill" => "pdf-forms", "on" => false}}}
        ] do
      assert calls(ask(text)) == [call], text
    end

    # Blip's own schedules stay the script's.
    assert calls(ask("in 5 minutes: check the pump")) ==
             [{"schedule", %{"prompt" => "check the pump", "in_minutes" => 5}}]

    assert calls(ask("schedules")) == [{"list_schedules", %{}}]
  end

  test "each phrasing matches the whole message" do
    for text <- [
          "projects please",
          "project",
          "threads in",
          "read thread",
          "the threads",
          "start project",
          "start thread in garden",
          "tell c_123",
          "stop thread",
          "stop thread c_1 now",
          "files in",
          "read notes.md",
          "read garden/notes.md now",
          "write garden: hello",
          "edit garden/notes.md: zone 2",
          "schedules in",
          "all skills now",
          "turn on pdf-forms",
          "turn up pdf-forms in garden"
        ] do
      assert calls(ask(text)) == [], text
    end
  end

  test "a scheduled prompt can use them too" do
    assert calls(ask("[Scheduled] threads in garden")) ==
             [{"list_threads", %{"project" => "garden"}}]
  end

  test "the phrasings are a list of patterns with replies, and the help lists them" do
    for {pattern, reply} <- MockCoordinator.phrasings(%{}) do
      assert %Regex{} = pattern
      assert is_function(reply, 1)
    end

    help = Message.text_of(ask("what can you do?"))
    assert help =~ "`projects` lists the projects"
    assert help =~ "`read thread <id>` reads one"
    assert help =~ "`start thread in <slug>: <message>` starts a thread there"
    assert help =~ "`stop thread <id>` stops one"
    assert help =~ "`write <slug>/<name>: <text>` writes a whole file"
    assert help =~ "`schedules in <slug>` lists a project's schedules"
    assert help =~ "`turn on <skill> in <slug>`"
    assert help =~ MockCoordinator.help()
  end

  describe "questions" do
    @system "You are Blip.\n\n## Memory\n\n- the NAS is mp1\n- deploy branch: staging\n- ab: never\n\n## Now\n\nIt's about noon."

    defp question(id, title, text),
      do: ~s{[Question #{id} from Garden / "#{title}" (c_1)]\n#{text}}

    defp unasked(texts, system \\ @system),
      do:
        MockScript.respond(%{
          system: system,
          messages: [Message.user(Enum.map(texts, &Message.text/1))]
        })

    test "a question its memory settles is answered with the memory's value" do
      reply = unasked([question("q_1", "Deploy", "Which Deploy Branch should I use?")])

      assert calls(reply) == [
               {"answer_question", %{"question_id" => "q_1", "answer" => "staging"}}
             ]

      assert Message.text_of(reply) == ~s{Answering "Deploy" from memory.}
    end

    test "a question its memory doesn't settle goes to the owner, in Blip's words" do
      reply = unasked([question("q_2", "Gate", "What colour should the gate be?")])

      assert calls(reply) == [
               {"ask_owner",
                %{
                  "question_id" => "q_2",
                  "question" => "What colour should the gate be?"
                }}
             ]

      # With no memory at all, the same.
      assert [{"ask_owner", _args}] =
               calls(unasked([question("q_2", "Gate", "Which deploy branch?")], "No memory."))
    end

    test "a key shorter than three characters never matches" do
      assert [{"ask_owner", _args}] =
               calls(unasked([question("q_3", "Lab", "Should the lab be locked?")]))
    end

    test "several questions in one message make one call each, in one answer" do
      reply =
        unasked([
          question("q_1", "Deploy", "Which deploy branch?"),
          question("q_2", "Gate", "What colour should the gate be?")
        ])

      assert [
               {"answer_question", %{"question_id" => "q_1"}},
               {"ask_owner", %{"question_id" => "q_2"}}
             ] =
               calls(reply)
    end

    test "a question ending in (prose) gets a plain reply and no call" do
      reply = unasked([question("q_4", "Gate", "Is the gate locked? (prose)")])
      assert calls(reply) == []
      assert Message.text_of(reply) == ~s{I'm not sure what to tell "Gate".}
    end

    test "answer <id>: answers a question by its ID" do
      assert calls(ask("answer q_9: the second one")) ==
               [{"answer_question", %{"question_id" => "q_9", "answer" => "the second one"}}]
    end

    test "answer: answers the last question it asked the owner about, if there is one" do
      asked = fn id ->
        Message.assistant("", [
          %{
            "id" => "call_#{id}",
            "name" => "ask_owner",
            "arguments" => Jason.encode!(%{"question_id" => id, "question" => "?"})
          }
        ])
      end

      request = %{
        messages: [
          asked.("q_1"),
          Message.tool_result("call_q_1", "Asked the user."),
          asked.("q_2"),
          Message.tool_result("call_q_2", "Asked the user."),
          Message.user("answer: green")
        ]
      }

      assert calls(MockScript.respond(request)) ==
               [{"answer_question", %{"question_id" => "q_2", "answer" => "green"}}]

      reply = ask("answer: green")
      assert calls(reply) == []
      assert Message.text_of(reply) == "I don't have a question waiting on you."
    end
  end

  describe "thread updates and answers" do
    test "updates get a line each, and no call" do
      reply =
        unasked([
          ~s{[Thread update] Garden / "Fix the pump" (c_1) finished. It said: Done.},
          ~s{[Thread update] Garden / "Plant list" (c_2) failed: HTTP 500: the pump is unplugged},
          ~s{[Thread update] House / "Paint" (c_3) is waiting on the user: Which colour?}
        ])

      assert calls(reply) == []

      assert Message.text_of(reply) ==
               "Fix the pump in Garden finished.\n" <>
                 "Plant list in Garden failed: HTTP 500: the pump is unplugged\n" <>
                 "Paint in House is waiting on you: Which colour?"
    end

    test "the owner's answer going by is noted" do
      reply =
        unasked([
          ~s{[Your answer to q_1 from Garden / "Gate" (c_1) went straight to the thread.]},
          "green"
        ])

      assert calls(reply) == []
      assert Message.text_of(reply) == "Noted."
    end

    test "a signal that isn't a question or an update goes to the phrasings" do
      assert calls(unasked(["threads in garden"])) == [{"list_threads", %{"project" => "garden"}}]

      assert MockCoordinator.unasked(["threads"], %{}) == nil
      assert MockCoordinator.unasked([], %{}) == nil
    end
  end

  test "relays what a read tool said" do
    listed = ~s(c_1 "Fix the pump" \(garden\): failed: the pump is unplugged)
    result = Message.tool_result("call_1", listed)
    request = %{messages: [Message.user("threads"), Message.assistant("", []), result]}
    assert Message.text_of(MockScript.respond(request)) == listed
  end
end

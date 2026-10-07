defmodule PhotonWeb.ConversationComponentsTest do
  @moduledoc """
  The conversation pieces Blip's panel and a thread page share: the
  context-file (a thread's and Blip's), `load_skill`, `ask_blip` and Blip's read, work,
  skill, schedule and question calls' lines, the ID prefix
  that keeps two conversations on one page apart, and images loaded from
  the page's own route.
  """

  use Photon.Case, async: true

  import Phoenix.LiveViewTest
  import Photon.Fixtures, only: [call: 3]

  alias PhotonCore.Message
  alias PhotonWeb.ConversationComponents

  defp image_path(entry_id, index), do: "/somewhere/#{entry_id}/#{index}"

  defp action(call, result, prefix \\ "") do
    assigns = [call: call, result: result, id_prefix: prefix, image_path: &image_path/2]
    LazyHTML.from_fragment(render_component(&ConversationComponents.action/1, assigns))
  end

  defp label(html), do: html |> LazyHTML.query("summary") |> LazyHTML.text() |> squish()

  defp squish(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  defp ok(call_id, text, details),
    do: %{
      "message" => Message.tool_result(call_id, text),
      "status" => "ok",
      "details" => details,
      "entry_id" => "e_1"
    }

  describe "a context-file call" do
    test "names the file it touched, in the present while it runs" do
      for {tool, running, done} <- [
            {"read_context_file", "Reading notes.md", "Read notes.md"},
            {"write_context_file", "Writing notes.md", "Wrote notes.md"},
            {"edit_context_file", "Editing notes.md", "Edited notes.md"}
          ] do
        call = call(tool, %{"name" => "notes.md"}, "c1")
        assert label(action(call, nil)) == running

        result = ok("c1", "Done.", %{"file" => "notes.md", "version" => 2})
        assert label(action(call, result)) == done
      end
    end

    test "names the file as stored, not as the model typed it" do
      call = call("write_context_file", %{"name" => "Notes"}, "c1")
      result = ok("c1", "Wrote notes.md.", %{"file" => "notes.md", "version" => 1})
      assert label(action(call, result)) == "Wrote notes.md"
    end

    test "listing reads as checking the files" do
      call = call("list_context_files", %{}, "c1")
      assert label(action(call, nil)) == "Checking the context files"
      assert label(action(call, ok("c1", "notes.md", %{}))) == "Checked the context files"
    end

    test "Blip's names the project, by its slug once the result is in" do
      for {tool, running, done} <- [
            {"read_context_file", "Reading notes.md in gardn", "Read notes.md in garden"},
            {"write_context_file", "Writing notes.md in gardn", "Wrote notes.md in garden"},
            {"edit_context_file", "Editing notes.md in gardn", "Edited notes.md in garden"}
          ] do
        call = call(tool, %{"project" => "gardn", "name" => "notes.md"}, "c1")
        assert label(action(call, nil)) == running

        details = %{"project_id" => "p_1", "slug" => "garden", "file" => "notes.md"}
        assert label(action(call, ok("c1", "Done.", details))) == done
      end

      list = call("list_context_files", %{"project" => "garden"}, "c1")
      assert label(action(list, nil)) == "Checking the context files in garden"

      listed = ok("c1", "notes.md", %{"project_id" => "p_1", "slug" => "garden"})
      assert label(action(list, listed)) == "Checked the context files in garden"
    end
  end

  describe "a load_skill call" do
    test "names the skill while it loads, once loaded, and when it couldn't" do
      call = call("load_skill", %{"name" => " pdf-forms "}, "c1")
      assert label(action(call, nil)) == "Loading the pdf-forms skill"

      result = ok("c1", "<skill ...>", %{"skill" => "pdf-forms", "version" => 2})
      html = action(call, result)
      assert label(html) == "Loaded the pdf-forms skill"
      assert html |> LazyHTML.query("summary .hero-book-open-micro") |> Enum.count() == 1

      error = %{
        "message" => Message.tool_result("c1", "Error: No skills are turned on here."),
        "status" => "error",
        "details" => %{},
        "entry_id" => "e_1"
      }

      call = call("load_skill", %{"name" => "pdf-form"}, "c1")
      assert label(action(call, error)) == "Couldn't load pdf-form"
    end
  end

  describe "an ask_blip call" do
    test "says it is asking while it waits, then that it asked, with the question" do
      call = call("ask_blip", %{"question" => "Which deploy\nbranch?"}, "c1")
      html = action(call, nil)
      assert label(html) == "Asking Blip: Which deploy branch?"

      assert html |> LazyHTML.query("summary [title]") |> LazyHTML.attribute("title") == [
               "Which deploy branch?"
             ]

      result =
        ok("c1", "Blip answered: staging", %{"question_id" => "q_1", "answered_by" => "blip"})

      html = action(call, result)
      assert label(html) == "Asked Blip: Which deploy branch?"

      assert html
             |> LazyHTML.query("summary .hero-chat-bubble-left-ellipsis-micro")
             |> Enum.count() == 1
    end

    test "a stopped call and one that couldn't ask say so" do
      call = call("ask_blip", %{"question" => "Which branch?"}, "c1")

      stopped = %{
        "message" => Message.tool_result("c1", "Stopped by the user before it finished."),
        "status" => "aborted",
        "details" => %{},
        "entry_id" => "e_1"
      }

      assert label(action(call, stopped)) == "Stopped asking Blip: Which branch?"

      error = %{
        "message" => Message.tool_result("c1", "Error: Ask one specific question."),
        "status" => "error",
        "details" => %{},
        "entry_id" => "e_1"
      }

      assert label(action(call, error)) == "Couldn't ask Blip: Which branch?"
      assert label(action(call("ask_blip", %{}, "c2"), nil)) == "Asking Blip"
    end
  end

  describe "Blip's read calls" do
    test "say what they look over, in the present while they run" do
      for {tool, args, details, running, done} <- [
            {"list_projects", %{}, %{}, "Looking over projects", "Looked over projects"},
            {"read_project", %{"project" => "garden"}, %{"slug" => "garden"},
             "Looking over garden", "Looked over garden"},
            {"list_threads", %{}, %{}, "Checking threads", "Checked threads"},
            {"list_threads", %{"project" => "garden"}, %{"slug" => "garden"},
             "Checking threads in garden", "Checked threads in garden"},
            {"read_thread", %{"thread" => "c_123"}, %{"title" => "Fix the pump"}, "Reading c_123",
             ~s(Read "Fix the pump")}
          ] do
        call = call(tool, args, "c1")
        assert label(action(call, nil)) == running
        assert label(action(call, ok("c1", "Text.", details))) == done
      end
    end

    test "a call that couldn't read, or was stopped, says so" do
      call = call("read_project", %{"project" => "gardn"}, "c1")

      error = %{
        "message" => Message.tool_result("c1", "Error: There's no project called gardn."),
        "status" => "error",
        "details" => %{},
        "entry_id" => "e_1"
      }

      assert label(action(call, error)) == "Couldn't look over gardn"

      stopped = %{error | "status" => "aborted"}

      assert label(action(call("read_thread", %{"thread" => "c_1"}, "c1"), stopped)) ==
               "Stopped reading c_1"
    end
  end

  describe "Blip's calls that start and stop work" do
    test "say what they act on, in the present while they run" do
      thread = %{"thread_id" => "c_9", "title" => "Fix the pump", "project_id" => "p_1"}

      for {tool, args, details, running, done} <- [
            {"start_project", %{"purpose" => "Water the beds."},
             %{"project_id" => "p_1", "slug" => "garden"}, "Starting a project",
             "Started the project garden"},
            {"start_thread", %{"project" => "garden", "message" => "files"},
             Map.put(thread, "slug", "garden"), "Starting a thread in garden",
             ~s(Started "Fix the pump" in garden)},
            {"message_thread", %{"thread" => "c_9", "message" => "again"}, thread,
             "Messaging c_9", ~s(Messaged "Fix the pump")},
            {"stop_thread", %{"thread" => "c_9"}, thread, "Stopping c_9",
             ~s(Stopped "Fix the pump")}
          ] do
        call = call(tool, args, "c1")
        assert label(action(call, nil)) == running
        assert label(action(call, ok("c1", "Text.", details))) == done
      end
    end

    test "a thread Blip started links to its page" do
      call = call("start_thread", %{"project" => "garden", "message" => "files"}, "c1")
      details = %{"thread_id" => "c_9", "title" => "Fix the pump", "slug" => "garden"}
      html = action(call, ok("c1", "Started.", details))

      assert html |> LazyHTML.query("summary a") |> LazyHTML.attribute("href") ==
               ["/projects/garden/threads/c_9"]

      running = action(call, nil)
      assert running |> LazyHTML.query("summary a") |> Enum.empty?()
    end

    test "a call that was refused, or stopped, says so" do
      error = %{
        "message" => Message.tool_result("c1", "Error: A thread's question can't start work."),
        "status" => "error",
        "details" => %{},
        "entry_id" => "e_1"
      }

      stopped = %{error | "status" => "aborted"}
      start = call("start_thread", %{"project" => "garden", "message" => "files"}, "c1")
      assert label(action(start, error)) == "Couldn't start a thread in garden"
      assert label(action(start, stopped)) == "Stopped starting a thread in garden"
      assert label(action(call("start_project", %{}, "c1"), error)) == "Couldn't start a project"

      assert label(action(call("message_thread", %{"thread" => "c_1"}, "c1"), error)) ==
               "Couldn't message c_1"

      assert label(action(call("stop_thread", %{"thread" => "c_1"}, "c1"), error)) ==
               "Couldn't stop c_1"

      assert label(action(call("stop_thread", %{"thread" => "c_1"}, "c1"), stopped)) ==
               "Didn't stop c_1"
    end
  end

  describe "Blip's skill and schedule calls" do
    test "say which skill and project, in the present while they run" do
      on =
        call(
          "set_project_skill",
          %{"project" => "garden", "skill" => "pdf-forms", "on" => true},
          "c1"
        )

      off =
        call(
          "set_project_skill",
          %{"project" => "garden", "skill" => "pdf-forms", "on" => false},
          "c1"
        )

      details = %{"project_id" => "p_1", "slug" => "garden", "skill" => "pdf-forms", "on" => true}

      assert label(action(on, nil)) == "Turning on pdf-forms for garden"

      assert label(action(on, ok("c1", "Turned on.", details))) ==
               "Turned on pdf-forms for garden"

      assert label(action(off, nil)) == "Turning off pdf-forms for garden"

      assert label(action(off, ok("c1", "Turned off.", %{details | "on" => false}))) ==
               "Turned off pdf-forms for garden"

      list = call("list_skills", %{}, "c1")
      assert label(action(list, nil)) == "Checking skills"
      assert label(action(list, ok("c1", "No skills yet.", %{}))) == "Checked skills"
    end

    test "a skill call that was refused, or stopped, says so" do
      error = %{
        "message" => Message.tool_result("c1", "Error: There's no skill called pdf-form."),
        "status" => "error",
        "details" => %{},
        "entry_id" => "e_1"
      }

      on =
        call(
          "set_project_skill",
          %{"project" => "garden", "skill" => "pdf-form", "on" => true},
          "c1"
        )

      assert label(action(on, error)) == "Couldn't turn on pdf-form for garden"

      assert label(action(on, %{error | "status" => "aborted"})) ==
               "Stopped turning on pdf-form for garden"
    end

    test "a project schedule names its project" do
      project = call("schedule", %{"prompt" => "Water zone 2", "project" => "garden"}, "c1")
      own = call("schedule", %{"prompt" => "Check the disks"}, "c1")

      assert label(action(project, ok("c1", "Scheduled.", %{}))) ==
               "Scheduled in garden: Water zone 2"

      assert label(action(own, ok("c1", "Scheduled.", %{}))) == "Scheduled: Check the disks"

      listed = call("list_schedules", %{"project" => "garden"}, "c1")
      assert label(action(listed, ok("c1", "Now.", %{}))) == "Checked the schedules in garden"
    end
  end

  describe "Blip's calls on a thread's question" do
    test "name the question while they run, then the thread, linked" do
      details = %{
        "question_id" => "q_4",
        "thread_id" => "c_9",
        "title" => "Fix the pump",
        "slug" => "garden"
      }

      for {tool, args, running, done} <- [
            {"answer_question", %{"question_id" => "q_4", "answer" => "staging"}, "Answering q_4",
             ~s(Answered "Fix the pump")},
            {"ask_owner", %{"question_id" => "q_4", "question" => "Which branch?"},
             "Asking you about q_4", ~s(Asked you about "Fix the pump")}
          ] do
        call = call(tool, args, "c1")
        assert label(action(call, nil)) == running
        html = action(call, ok("c1", "Text.", details))
        assert label(html) == done

        assert html |> LazyHTML.query("summary a") |> LazyHTML.attribute("href") ==
                 ["/projects/garden/threads/c_9"]
      end
    end

    test "a refused call says so" do
      error = %{
        "message" => Message.tool_result("c1", "Error: q_4 is with the user."),
        "status" => "error",
        "details" => %{},
        "entry_id" => "e_1"
      }

      assert label(action(call("answer_question", %{"question_id" => "q_4"}, "c1"), error)) ==
               "Couldn't answer q_4"

      assert label(action(call("ask_owner", %{"question_id" => "q_4"}, "c1"), error)) ==
               "Couldn't ask you about q_4"
    end
  end

  describe "a machine call" do
    defp action(call, result, prefix, tail) do
      assigns = [
        call: call,
        result: result,
        tail: tail,
        id_prefix: prefix,
        image_path: &image_path/2
      ]

      LazyHTML.from_fragment(render_component(&ConversationComponents.action/1, assigns))
    end

    defp classes(html, selector),
      do: html |> LazyHTML.query(selector) |> LazyHTML.attribute("class") |> Enum.join(" ")

    test "cuts a long command short, never the verb or the machine" do
      command = "df -h /; for i in 1 2 3 4 5; do sleep 1; echo \"check $i ok\"; done"
      html = action(call("shell", %{"machine" => "local", "command" => command}, "c1"), nil)

      assert label(html) == "Running #{command} on local"
      assert classes(html, "summary code") =~ "truncate"
      assert html |> LazyHTML.query("summary code") |> LazyHTML.attribute("title") == [command]
      assert classes(html, "summary [data-machine=local]") =~ "shrink-0"
      refute classes(html, "summary [data-machine=local]") =~ "truncate"
    end

    test "a stopped call says so and keeps the output it printed before the stop" do
      call = call("shell", %{"machine" => "local", "command" => "make test"}, "c1")

      stopped = %{
        "message" => Message.tool_result("c1", "Stopped by the user before it finished."),
        "status" => "aborted",
        "details" => %{},
        "entry_id" => "e_1"
      }

      html = action(call, stopped, "", "tick 1\ntick 2\n")
      assert label(html) == "Stopped make test on local"
      assert html |> LazyHTML.query("#action-c1-tail pre") |> LazyHTML.text() =~ "tick 2"

      done = ok("c1", "tick 1", %{"machine" => "local", "status" => "completed"})
      html = action(call, done, "", "tick 1\n")
      assert label(html) == "Ran make test on local"
      assert Enum.empty?(LazyHTML.query(html, "#action-c1-tail"))
    end
  end

  describe "IDs and images" do
    test "a prefix goes on every ID, and an image loads from the page's route" do
      call = call("view_image", %{"machine" => "mm1", "path" => "shot.png"}, "c1")

      result = %{
        "message" => Message.tool_result("c1", [Message.image("image/png", Base.encode64("a"))]),
        "status" => "ok",
        "details" => %{"machine" => "mm1"},
        "entry_id" => "e_7"
      }

      html = action(call, result, "thread-")
      assert [_] = Enum.to_list(LazyHTML.query(html, "#thread-action-c1"))
      assert [_] = Enum.to_list(LazyHTML.query(html, "#thread-action-c1-details"))

      assert html |> LazyHTML.query("#thread-action-c1-image-0") |> LazyHTML.attribute("src") ==
               ["/somewhere/e_7/0"]

      assert label(html) == "Looked at shot.png on mm1"
    end

    test "the composer's IDs take the prefix, and without one stay Blip's" do
      assigns = [
        form: Phoenix.Component.to_form(%{"text" => ""}, as: :message),
        busy: true,
        mode: "follow_up",
        queued: []
      ]

      composer = &ConversationComponents.composer/1

      thread =
        LazyHTML.from_fragment(render_component(composer, [id_prefix: "thread-"] ++ assigns))

      for id <-
            ~w(thread-composer thread-composer-input thread-mode-toggle thread-stop thread-send),
          do: assert([_] = Enum.to_list(LazyHTML.query(thread, "##{id}")))

      blip = LazyHTML.from_fragment(render_component(composer, assigns))

      for id <- ~w(composer composer-input mode-toggle stop send),
          do: assert([_] = Enum.to_list(LazyHTML.query(blip, "##{id}")))
    end
  end
end

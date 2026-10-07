defmodule PhotonWeb.ConversationComponentsTest do
  @moduledoc """
  The conversation pieces Blip's panel and a thread page share: the
  context-file, `load_skill` and `ask_blip` calls' lines, the ID prefix
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

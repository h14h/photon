defmodule PhotonWeb.ConversationComponentsTest do
  @moduledoc """
  The conversation pieces Blip's panel and a thread page share: the
  context-file calls' lines, the ID prefix that keeps two conversations on
  one page apart, and images loaded from the page's own route.
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

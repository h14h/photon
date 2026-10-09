defmodule PhotonWeb.ConversationImageControllerTest do
  @moduledoc "The images in a conversation, served one per request."

  use PhotonWeb.ConnCase, async: false

  import Photon.ConversationHelpers
  import Photon.ProjectHelpers

  alias Photon.{Assistant, Durable}
  alias PhotonCore.Message

  @moduletag :durable

  defp result(content, conversation \\ Assistant.conversation_id()) do
    Durable.commit(
      &Durable.Tx.append(&1, conversation, "tool_result", %{
        "message" => Message.tool_result("c1", content),
        "name" => "view_image",
        "status" => "ok",
        "details" => %{}
      })
    )
  end

  describe "Blip's images" do
    test "serves an image by its entry and place, and lets the browser keep it", %{conn: conn} do
      entry =
        result([
          Message.text("2 images"),
          Message.image("image/gif", Base.encode64("a")),
          Message.image("image/webp", Base.encode64("b"))
        ])

      conn = get(conn, ~p"/blip/images/#{entry.id}/1")
      assert response(conn, 200) == "b"
      assert get_resp_header(conn, "content-type") == ["image/webp"]
      assert get_resp_header(conn, "cache-control") == ["private, max-age=31536000, immutable"]
    end

    test "anything else is not found", %{conn: conn} do
      entry = result([Message.image("image/png", Base.encode64("a"))])

      elsewhere = Durable.create_conversation("assistant").id

      other =
        Durable.commit(
          &Durable.Tx.append(&1, elsewhere, "tool_result", %{
            "message" =>
              Message.tool_result("c1", [Message.image("image/png", Base.encode64("x"))])
          })
        )

      for path <- [
            ~p"/blip/images/#{entry.id}/1",
            ~p"/blip/images/#{entry.id}/-1",
            ~p"/blip/images/#{entry.id}/first",
            ~p"/blip/images/e_none/0",
            # An entry in another conversation.
            ~p"/blip/images/#{other.id}/0"
          ],
          do: assert(response(get(conn, path), 404) == "No such image.\n")
    end
  end

  describe "a thread's images" do
    setup do
      project = garden!()

      # Let the first answer finish, so the images land after it.
      thread = idle_thread!(project, "Look at the pump")

      %{thread: thread}
    end

    test "serves an image in the thread's conversation", %{conn: conn, thread: thread} do
      entry =
        result(
          [Message.text("1 image"), Message.image("image/png", Base.encode64("pump"))],
          thread.id
        )

      conn = get(conn, ~p"/threads/#{thread.id}/images/#{entry.id}/0")
      assert response(conn, 200) == "pump"
      assert get_resp_header(conn, "content-type") == ["image/png"]
    end

    test "an entry from Blip or another thread, or no thread, is not found",
         %{conn: conn, thread: thread} do
      ours = result([Message.image("image/png", Base.encode64("a"))], thread.id)
      blip = result([Message.image("image/png", Base.encode64("b"))])

      for path <- [
            # A Blip entry asked for under a thread's route.
            ~p"/threads/#{thread.id}/images/#{blip.id}/0",
            # The thread's entry under a thread that doesn't exist.
            ~p"/threads/c_none/images/#{ours.id}/0",
            ~p"/threads/#{thread.id}/images/#{ours.id}/1"
          ],
          do: assert(response(get(conn, path), 404) == "No such image.\n")

      # And a thread's entry under Blip's route.
      assert response(get(conn, ~p"/blip/images/#{ours.id}/0"), 404) == "No such image.\n"
    end
  end
end

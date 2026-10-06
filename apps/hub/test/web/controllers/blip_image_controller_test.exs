defmodule PhotonWeb.BlipImageControllerTest do
  @moduledoc "The images in Blip's conversation, served one per request."

  use PhotonWeb.ConnCase, async: false

  alias Photon.{Assistant, Durable}
  alias PhotonCore.Message

  @moduletag :durable

  defp result(content) do
    conversation = Assistant.conversation_id()

    Durable.commit(
      &Durable.Tx.append(&1, conversation, "tool_result", %{
        "message" => Message.tool_result("c1", content),
        "name" => "view_image",
        "status" => "ok",
        "details" => %{}
      })
    )
  end

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
          "message" => Message.tool_result("c1", [Message.image("image/png", Base.encode64("x"))])
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

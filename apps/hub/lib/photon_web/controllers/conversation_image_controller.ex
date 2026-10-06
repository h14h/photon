defmodule PhotonWeb.ConversationImageController do
  @moduledoc """
  Serves the images in a conversation (what `view_image` calls returned),
  one per request, so a page can show them with plain `<img src>` instead
  of carrying their data in its state and its renders. Behind the same
  check as every GUI page (`PhotonWeb.Auth`).

  `blip/2` serves Blip's conversation, through `Photon.Assistant.image/2`,
  which only finds entries in it; `thread/2` serves a thread's, through
  `Photon.Threads.image/3`, which only finds entries in that thread. Each
  conversation gets its own action and route, so an entry ID from one
  can't be read through another's.

  An entry never changes, so a browser may keep an image for good.
  """

  use PhotonWeb, :controller

  alias Photon.{Assistant, Threads}

  @doc "An image in Blip's conversation, by its entry and place."
  @spec blip(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def blip(conn, %{"entry_id" => entry_id, "index" => index}),
    do: serve(conn, index, &Assistant.image(entry_id, &1))

  @doc "An image in a thread's conversation, by the thread, the entry and its place."
  @spec thread(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def thread(conn, %{"thread_id" => thread_id, "entry_id" => entry_id, "index" => index}),
    do: serve(conn, index, &Threads.image(thread_id, entry_id, &1))

  defp serve(conn, index, read) do
    with {index, ""} when index >= 0 <- Integer.parse(index),
         {:ok, mime, bytes} <- read.(index) do
      conn
      |> put_resp_content_type(mime, nil)
      |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
      |> send_resp(200, bytes)
    else
      _not_an_image -> send_resp(conn, 404, "No such image.\n")
    end
  end
end

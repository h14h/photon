defmodule PhotonWeb.BlipImageController do
  @moduledoc """
  Serves the images in Blip's conversation (what `view_image` calls
  returned), one per request, so `PhotonWeb.BlipLive` can show them with
  plain `<img src>` instead of carrying their data in its state and its
  renders. Behind the same check as every GUI page (`PhotonWeb.Auth`).

  An entry never changes, so a browser may keep an image for good.
  """

  use PhotonWeb, :controller

  alias Photon.Assistant

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"entry_id" => entry_id, "index" => index}) do
    with {index, ""} when index >= 0 <- Integer.parse(index),
         {:ok, mime, bytes} <- Assistant.image(entry_id, index) do
      conn
      |> put_resp_content_type(mime, nil)
      |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
      |> send_resp(200, bytes)
    else
      _not_an_image -> send_resp(conn, 404, "No such image.\n")
    end
  end
end

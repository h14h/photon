defmodule PhotonWeb.AttachmentController do
  @moduledoc "Serves the hub's copies of images attached to messages (behind the GUI password)."

  use PhotonWeb, :controller

  def show(conn, %{"session_id" => session_id, "name" => name}) do
    case Photon.Attachments.hub_file(session_id, name) do
      {:ok, path} ->
        conn
        |> put_resp_content_type(Photon.Attachments.mime(path))
        |> put_resp_header("cache-control", "private, max-age=86400")
        |> send_file(200, path)

      :error ->
        send_resp(conn, 404, "Not found")
    end
  end
end

defmodule PhotonWeb.NodeInstallController do
  @moduledoc """
  Serves the node installer and packaged binaries, for
  `curl -fsSL <hub>/node/install.sh | PHOTON_NODE_TOKEN=... sh`.

  Neither is secret: the script takes the token from its environment.
  """

  use PhotonWeb, :controller

  alias Photon.NodeDist

  def script(conn, _params) do
    # The address the machine fetched this from is one it can reach.
    base = Application.get_env(:photon, :public_url) || request_base(conn)

    conn
    |> put_resp_content_type("text/x-shellscript")
    |> send_resp(200, NodeDist.install_script(String.trim_trailing(base, "/")))
  end

  def download(conn, %{"file" => "photon-node-" <> target}) do
    case NodeDist.binary(target) do
      {:ok, path} ->
        conn
        |> put_resp_content_type("application/octet-stream")
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="photon-node-#{target}")
        )
        |> send_file(200, path)

      {:error, :not_built} ->
        send_resp(
          conn,
          404,
          "No #{target} build on this hub. Build it: mix photon.package --targets #{NodeDist.package_target(target)}\n"
        )

      {:error, :unknown_target} ->
        send_resp(conn, 404, "Unknown target #{target}\n")
    end
  end

  def download(conn, _params), do: send_resp(conn, 404, "Not found\n")

  # Behind a TLS-terminating proxy (Fly), the request arrives as plain HTTP;
  # X-Forwarded-Proto says what the machine actually used.
  defp request_base(conn) do
    case get_req_header(conn, "x-forwarded-proto") do
      ["https" | _] ->
        "https://#{conn.host}"

      _ ->
        default_port? = {conn.scheme, conn.port} in [{:http, 80}, {:https, 443}]
        port = if default_port?, do: "", else: ":#{conn.port}"
        "#{conn.scheme}://#{conn.host}#{port}"
    end
  end
end

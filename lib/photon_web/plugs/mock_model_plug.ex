defmodule PhotonWeb.MockModelPlug do
  @moduledoc "Serves `Photon.MockModel` at `POST /mock/v1/responses`, streamed as SSE."

  import Plug.Conn

  def init(opts), do: opts

  def call(%{method: "POST", path_info: ["responses"]} = conn, _opts) do
    response = Photon.MockModel.respond(conn.body_params)

    if conn.body_params["stream"] == false do
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(response))
    else
      events = [
        {"response.created",
         %{
           "type" => "response.created",
           "response" => %{response | "status" => "in_progress", "output" => []}
         }},
        {"response.completed", %{"type" => "response.completed", "response" => response}}
      ]

      body =
        Enum.map(events, fn {name, data} ->
          ["event: ", name, "\ndata: ", Jason.encode!(data), "\n\n"]
        end)

      conn |> put_resp_content_type("text/event-stream") |> send_resp(200, body)
    end
  end

  def call(conn, _opts), do: conn |> send_resp(404, "not found") |> halt()
end

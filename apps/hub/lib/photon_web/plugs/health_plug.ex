defmodule PhotonWeb.HealthPlug do
  @moduledoc "Answers health checks at `/healthz`."
  import Plug.Conn

  @spec init(term()) :: term()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call(conn, _opts), do: conn |> put_resp_content_type("text/plain") |> send_resp(200, "ok\n")
end

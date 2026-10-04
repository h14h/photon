defmodule PhotonWeb.Router do
  use PhotonWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug PhotonWeb.Auth
    plug :fetch_live_flash
    plug :put_root_layout, html: {PhotonWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", PhotonWeb do
    pipe_through :browser

    live_session :gui, on_mount: [PhotonWeb.Auth, PhotonWeb.Shell] do
      live "/", AssistantLive
      live "/sessions/:id", SessionLive
      live "/nodes", NodesLive
      live "/settings", SettingsLive
    end
  end

  # For the platform's health checks; needs no password.
  get "/healthz", PhotonWeb.HealthPlug, []

  # The node installer, packaged binaries, and the model proxy nodes use (the
  # node websocket itself is mounted in the endpoint at /node/websocket).
  scope "/node", PhotonWeb do
    get "/install.sh", NodeInstallController, :script
    get "/download/:file", NodeInstallController, :download
    post "/llm/v1/chat/completions", ModelProxyController, :chat
  end
end

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

    get "/sessions/:session_id/attachments/:name", AttachmentController, :show

    live_session :gui, on_mount: PhotonWeb.Auth do
      live "/", PlaygroundLive
      live "/s/:id", PlaygroundLive
    end
  end

  # For the platform's health checks; needs no password.
  get "/healthz", PhotonWeb.HealthPlug, []

  # The node installer and packaged binaries (the node websocket itself is
  # mounted in the endpoint at /node/websocket).
  scope "/node", PhotonWeb do
    get "/install.sh", NodeInstallController, :script
    get "/download/:file", NodeInstallController, :download
  end

  # A fake Responses API endpoint the runner talks to when the "mock"
  # provider is selected.
  forward "/mock/v1", PhotonWeb.MockModelPlug
end

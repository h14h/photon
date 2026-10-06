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
      live "/", OverviewLive
      # `/projects/new` before `/projects/:slug`; `new` is a reserved slug,
      # and file names end in `.md`, so neither `new` below is a file or thread.
      live "/projects/new", ProjectNewLive
      live "/projects/:slug", ProjectLive
      live "/projects/:slug/files/new", ContextFileLive, :new
      live "/projects/:slug/files/:name", ContextFileLive, :edit
      live "/projects/:slug/threads/new", ThreadLive, :new
      live "/projects/:slug/threads/:id", ThreadLive, :show
      live "/projects/:slug/schedules/new", ScheduleLive, :new
      live "/projects/:slug/schedules/:id", ScheduleLive, :edit
      # `/skills/new` and `/skills/install` before `/skills/:name`; `new`
      # and `install` are reserved skill names.
      live "/skills", SkillsLive
      live "/skills/new", SkillLive, :new
      live "/skills/install", SkillInstallLive
      live "/skills/:name", SkillLive, :edit
      live "/nodes", NodesLive
      live "/settings", SettingsLive
    end
  end

  # Images a conversation's page loads on their own; checked like the pages.
  pipeline :gui_files do
    plug :fetch_session
    plug PhotonWeb.Auth
    plug :put_secure_browser_headers
  end

  scope "/blip", PhotonWeb do
    pipe_through :gui_files

    get "/images/:entry_id/:index", ConversationImageController, :blip
  end

  scope "/threads", PhotonWeb do
    pipe_through :gui_files

    get "/:thread_id/images/:entry_id/:index", ConversationImageController, :thread
  end

  # For the platform's health checks; needs no password.
  get "/healthz", PhotonWeb.HealthPlug, []

  # The node installer and packaged binaries (the node websocket itself is
  # mounted in the endpoint at /node/websocket).
  scope "/node", PhotonWeb do
    get "/install.sh", NodeInstallController, :script
    get "/download/:file", NodeInstallController, :download
  end
end

defmodule PhotonWeb do
  @moduledoc """
  The web layer's `use PhotonWeb, :controller` (`:html`, `:live_view`,
  ...) entrypoint. The quoted definitions run in every such module, so
  they hold only imports, uses and aliases: functions go in their own
  modules, imported here.
  """

  # The web layer: LiveViews, the node channel and controllers, which may
  # use only what `Photon` exports (the contexts) and never Ecto.
  use Boundary,
    deps: [Photon, Photon.Threads.State, PhotonCore],
    exports: [Endpoint, Telemetry],
    check: [apps: [:ecto, :ecto_sql, :photon_node]]

  @spec static_paths() :: [String.t()]
  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  @spec router() :: Macro.t()
  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  @spec channel() :: Macro.t()
  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  @spec controller() :: Macro.t()
  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  @spec live_view() :: Macro.t()
  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  @spec live_component() :: Macro.t()
  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  @spec html() :: Macro.t()
  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      import PhotonWeb.CoreComponents
      import PhotonWeb.Blip, only: [blip: 1]
      import PhotonWeb.TimeComponents

      alias Phoenix.LiveView.JS
      alias PhotonWeb.Layouts

      unquote(verified_routes())
    end
  end

  @spec verified_routes() :: Macro.t()
  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: PhotonWeb.Endpoint,
        router: PhotonWeb.Router,
        statics: PhotonWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end

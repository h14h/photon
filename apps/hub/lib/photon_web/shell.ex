defmodule PhotonWeb.Shell do
  @moduledoc """
  Keeps the app shell current on every page: connected nodes, recent node
  sessions, the node work the assistant has running, the model in use, and
  whether the hub is signed in with ChatGPT. Mounted for the whole
  `live_session` and by `PhotonWeb.BlipLive`; pages get it as `@shell`.

  It rebuilds on `:nodes_changed`, `:node_sessions_changed`,
  `{:settings_changed, _}`, `{:durable_tasks, _}` and `{:chatgpt_changed, _}`,
  and lets each message continue to the page, which may want it too.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias Photon.{Assistant, ChatGPT, Nodes, NodeSessions, Settings}

  @spec on_mount(:default, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Nodes.subscribe()
      NodeSessions.subscribe()
      Settings.subscribe()
      ChatGPT.subscribe()
      Assistant.subscribe_tasks()
    end

    {:cont,
     socket |> assign(:shell, build()) |> attach_hook(:shell, :handle_info, &handle_info/2)}
  end

  defp handle_info(message, socket)
       when message in [:nodes_changed, :node_sessions_changed] or
              (is_tuple(message) and
                 elem(message, 0) in [:settings_changed, :durable_tasks, :chatgpt_changed]) do
    {:cont, assign(socket, :shell, build())}
  end

  defp handle_info(_message, socket), do: {:cont, socket}

  @doc "The shell's data, read now."
  @spec build() :: map()
  def build do
    online = Nodes.list()
    chatgpt = ChatGPT.status()
    sessions = NodeSessions.list(nil, 60)
    settings = Settings.load()

    %{
      nodes: Nodes.roster(online, sessions),
      sessions: sessions,
      working: Enum.filter(sessions, &(&1.origin == "assistant" and &1.status == "running")),
      model: Settings.model_label(settings),
      chatgpt: chatgpt,
      model_ready: ChatGPT.ready?(chatgpt)
    }
  end
end

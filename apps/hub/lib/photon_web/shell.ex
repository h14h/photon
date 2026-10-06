defmodule PhotonWeb.Shell do
  @moduledoc """
  Keeps the app shell current on every page: the machines the hub knows and
  which are online, the model in use, and whether the hub is signed in with
  ChatGPT. Mounted for the whole `live_session` and by `PhotonWeb.BlipLive`;
  pages get it as `@shell`.

  The machines are `Photon.Machines.roster/0`: the connected nodes, and
  the known ones (a key that isn't revoked) offline. It rebuilds on
  `:nodes_changed`, `{:node_keys_changed, _}`, `{:settings_changed, _}`
  and `{:chatgpt_changed, _}`, and lets every message continue to the
  page, which may want it too. It also subscribes to the assistant's tasks
  (`{:durable_tasks, _}`) for the pages, though nothing in it depends on
  them.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias Photon.{Assistant, ChatGPT, Machines, NodeKeys, Settings}

  @spec on_mount(:default, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Machines.subscribe()
      NodeKeys.subscribe()
      Settings.subscribe()
      ChatGPT.subscribe()
      Assistant.subscribe_tasks()
    end

    {:cont,
     socket |> assign(:shell, build()) |> attach_hook(:shell, :handle_info, &handle_info/2)}
  end

  defp handle_info(message, socket)
       when message == :nodes_changed or
              (is_tuple(message) and
                 elem(message, 0) in [:node_keys_changed, :settings_changed, :chatgpt_changed]) do
    {:cont, assign(socket, :shell, build())}
  end

  defp handle_info(_message, socket), do: {:cont, socket}

  @doc "The shell's data, read now."
  @spec build() :: map()
  def build do
    chatgpt = ChatGPT.status()
    settings = Settings.load()

    %{
      nodes: Machines.roster(),
      model: Settings.model_label(settings),
      chatgpt: chatgpt,
      model_ready: ChatGPT.ready?(chatgpt)
    }
  end
end

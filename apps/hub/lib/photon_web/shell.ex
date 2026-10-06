defmodule PhotonWeb.Shell do
  @moduledoc """
  Keeps the app shell current on every page: the projects and their threads
  for the sidebar, the machines the hub knows and which are online, the
  model in use, and whether the hub is signed in with ChatGPT. Mounted for
  the whole `live_session` and by `PhotonWeb.BlipLive`; pages get it as
  `@shell`.

  The sidebar's data is `Photon.Threads.sidebar/1`: each project (by name)
  with its five most recently active threads, any other of its threads
  that is running, and how many more it has. `@shell.running` is the
  `MapSet` of the listed threads that are running. It is a plain assign,
  not a stream: it is bounded (five threads a project plus the running
  ones), and `@shell` is rendered by `Layouts.app`, outside each page's
  own template.

  The machines are `Photon.Machines.roster/0`: the connected nodes, and the
  known ones (a key that isn't revoked) offline.

  What rebuilds what:

    * `:nodes_changed`, `{:node_keys_changed, _}`, `{:settings_changed, _}`
      and `{:chatgpt_changed, _}` rebuild everything.
    * `{:projects_changed, _}` (a project created or changed, a thread
      started or sent a message) rebuilds the sidebar.
    * `{:durable_tasks, tasks}` rebuilds the sidebar only when one of
      `tasks` belongs to a listed thread, so a busy hub doesn't re-read it
      on every task change (rule 73). A thread that isn't listed can only
      start running through a message, which announces
      `{:projects_changed, _}` first.

  Every message continues to the page, which may want it too.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias Photon.{Assistant, ChatGPT, Machines, NodeKeys, Projects, Settings, Threads}

  # Threads listed under each project, besides the running ones.
  @threads_per_project 5

  @spec on_mount(:default, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Machines.subscribe()
      NodeKeys.subscribe()
      Settings.subscribe()
      ChatGPT.subscribe()
      Projects.subscribe()
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

  defp handle_info({:projects_changed, _project_id}, socket),
    do: {:cont, refresh_sidebar(socket)}

  defp handle_info({:durable_tasks, tasks}, socket) do
    if listed_task?(socket.assigns.shell, tasks),
      do: {:cont, refresh_sidebar(socket)},
      else: {:cont, socket}
  end

  defp handle_info(_message, socket), do: {:cont, socket}

  defp refresh_sidebar(socket),
    do: assign(socket, :shell, Map.merge(socket.assigns.shell, sidebar()))

  defp listed_task?(shell, tasks) do
    listed = for %{threads: threads} <- shell.projects, thread <- threads, do: thread.id
    Enum.any?(tasks, &(&1.conversation_id in listed))
  end

  @doc "The shell's data, read now."
  @spec build() :: map()
  def build do
    chatgpt = ChatGPT.status()
    settings = Settings.load()

    Map.merge(
      %{
        nodes: Machines.roster(),
        model: Settings.model_label(settings),
        chatgpt: chatgpt,
        model_ready: ChatGPT.ready?(chatgpt)
      },
      sidebar()
    )
  end

  defp sidebar do
    projects = Threads.sidebar(@threads_per_project)

    running =
      for %{threads: threads} <- projects,
          thread <- threads,
          thread.running?,
          into: MapSet.new(),
          do: thread.id

    %{projects: projects, running: running}
  end
end

defmodule PhotonWeb.ThreadLive do
  @moduledoc """
  A project's thread (sections 5.6 and 5.7 of
  `docs/plans/step-2-projects-and-threads.md`).

  `:new`, at `/projects/:slug/threads/new`, starts one: the project's
  purpose, and a composer for the first message. Sending it starts the
  thread (`Photon.Threads.start/2`) and goes to its page. Without a model
  the composer gives way to the ChatGPT sign-in, as in Blip's panel.

  `:show`, at `/projects/:slug/threads/:id`, is the conversation, shown the
  way Blip's panel shows its own: the shared `PhotonWeb.ConversationComponents`
  with the ID prefix `"thread-"` (Blip's panel is on the same document),
  images from the thread's own route, and `PhotonWeb.ConversationView`
  folding in what the page hears. Under it, the composer, with the steer or
  follow-up toggle, Stop and the queued messages while the thread runs.
  Stop is `Photon.Threads.stop/1`.

  What it hears, and from where:

    * `{:durable, id, changes}` and `{:live, id, event}`
      (`Photon.Threads.subscribe/1`): the thread's commits, and its
      in-flight answer and running commands' output
    * `{:projects_changed, id}` (through `PhotonWeb.Shell`'s subscription):
      for this project, reload it, since its name is in the header

  Everything else the shell passes on (`{:durable_tasks, _}` among them)
  is ignored.

  An unknown project or thread, or a thread under another project's slug,
  goes back to `/` with a flash.
  """

  use PhotonWeb, :live_view

  import PhotonWeb.ConversationComponents

  alias Photon.{Projects, Threads, Transcript}
  alias Photon.Projects.Project
  alias Photon.Threads.Thread
  alias PhotonWeb.ConversationView

  @impl true
  def mount(%{"slug" => slug} = params, _session, socket) do
    with {:ok, project} <- project(slug),
         {:ok, thread} <- thread(project, params, socket.assigns.live_action) do
      {:ok,
       socket
       |> assign(page_title: title(project, thread), project: project, thread: thread)
       |> conversation(thread)}
    else
      {:error, message} -> {:ok, gone(socket, message)}
    end
  end

  defp project(slug) do
    case Projects.get_by_slug(slug) do
      %Project{} = project -> {:ok, project}
      nil -> {:error, "There's no project called #{slug}."}
    end
  end

  defp thread(_project, _params, :new), do: {:ok, nil}

  defp thread(project, %{"id" => id}, :show) do
    case Threads.get(id) do
      %Thread{project_id: project_id} = thread when project_id == project.id -> {:ok, thread}
      _missing -> {:error, no_thread(project)}
    end
  end

  # A new thread has only the composer. A thread's conversation is read
  # after subscribing, so no commit falls between the two; one that's in
  # both is inserted twice into the stream, which keeps it once.
  defp conversation(socket, nil) do
    socket |> assign(busy: false, queued: []) |> ConversationView.reset_form()
  end

  defp conversation(socket, %Thread{id: id}) do
    if connected?(socket), do: Threads.subscribe(id)

    socket
    |> assign(image_path: fn entry, index -> ~p"/threads/#{id}/images/#{entry}/#{index}" end)
    |> ConversationView.mount_conversation(Threads.entries(id),
      busy: Threads.busy?(id),
      queued: Threads.queued(id),
      dom_id: &"thread-entry-#{&1.id}"
    )
  end

  defp no_thread(project), do: "There's no such thread in #{project.name}."

  defp title(project, nil), do: "New thread in #{project.name}"
  defp title(_project, thread), do: thread.title

  defp gone(socket, message), do: socket |> put_flash(:error, message) |> push_navigate(to: ~p"/")

  defp gone(socket), do: gone(socket, "There's no project called #{socket.assigns.project.slug}.")

  ## Events

  @impl true
  def handle_event("send", %{"message" => %{"text" => text}}, %{assigns: %{thread: nil}} = socket) do
    case Threads.start(socket.assigns.project.id, text) do
      {:ok, thread} ->
        {:noreply,
         push_navigate(socket,
           to: ~p"/projects/#{socket.assigns.project.slug}/threads/#{thread.id}"
         )}

      {:error, :blank} ->
        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, gone(socket)}
    end
  end

  def handle_event("send", %{"message" => %{"text" => text}}, socket) do
    %{thread: thread, mode: mode} = socket.assigns

    case Threads.send(thread.id, text, when_busy: mode) do
      {:ok, _submission} -> {:noreply, ConversationView.reset_form(socket)}
      {:error, :not_found} -> {:noreply, gone(socket, no_thread(socket.assigns.project))}
      # Blank, or `:busy`, which only "reject" gives: there's nothing to send.
      {:error, _blank} -> {:noreply, socket}
    end
  end

  def handle_event("toggle_mode", _params, socket) do
    {:noreply, update(socket, :mode, &if(&1 == "steer", do: "follow_up", else: "steer"))}
  end

  def handle_event("stop", _params, socket) do
    :ok = Threads.stop(socket.assigns.thread.id)
    {:noreply, socket}
  end

  def handle_event("withdraw", %{"id" => id}, socket) do
    :ok = withdraw(id, socket.assigns.queued)
    {:noreply, assign(socket, queued: Threads.queued(socket.assigns.thread.id))}
  end

  # Only a message queued for this thread: the ID comes from the browser.
  defp withdraw(id, queued) do
    if Enum.any?(queued, &(&1.id == id)), do: Threads.withdraw(id), else: :ok
  end

  ## Updates

  @impl true
  def handle_info({:durable, id, changes}, %{assigns: %{thread: %{id: id}}} = socket) do
    busy = Threads.busy?(id)
    {:noreply, ConversationView.apply_changes(socket, changes, busy, Threads.queued(id))}
  end

  def handle_info({:live, id, event}, %{assigns: %{thread: %{id: id}}} = socket),
    do: {:noreply, ConversationView.apply_live(socket, event)}

  def handle_info({:projects_changed, id}, %{assigns: %{project: %{id: id}}} = socket) do
    case Projects.get(id) do
      %Project{} = project ->
        {:noreply,
         assign(socket, project: project, page_title: title(project, socket.assigns.thread))}

      nil ->
        {:noreply, gone(socket)}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Rendering

  @impl true
  def render(%{live_action: :new} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} shell={@shell} socket={@socket} active={{:project, @project.slug}}>
      <div class="h-full overflow-y-auto">
        <div class="blip-clear-y pt-8 sm:pt-12">
          <div class="px-3 sm:px-4">
            <div class="mx-auto w-full max-w-3xl">
              <.back_to_project project={@project} />
              <h1 id="thread-new-heading" class="mt-3 text-xl font-semibold tracking-tight text-ink">
                New thread in {@project.name}
              </h1>
              <p
                id="thread-new-purpose"
                class="mt-2 line-clamp-3 text-[14px] leading-relaxed whitespace-pre-line text-ink-soft"
                title={@project.purpose}
              >
                {@project.purpose}
              </p>
            </div>
          </div>

          <.composer
            :if={@shell.model_ready}
            form={@form}
            busy={false}
            mode={@mode}
            queued={[]}
            id_prefix="thread-"
            placeholder="What should this thread work on?"
            class="mt-5"
            autofocus
          />
          <.sign_in_to_talk
            :if={!@shell.model_ready}
            chatgpt={@shell.chatgpt}
            who="A thread"
            id_prefix="thread-"
          />

          <div class="px-3 sm:px-4">
            <p
              id="thread-new-hint"
              class="mx-auto w-full max-w-3xl px-1 text-[12.5px] leading-relaxed text-ink-faint"
            >
              <.icon name="hero-folder-micro" class="mr-0.5 size-3.5 align-[-2px]" />
              It works in the folder <code class="font-mono text-ink-soft">{@project.slug}</code>
              on whichever machine you name, and can read and write this project's context files.
            </p>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    assigns =
      assign(assigns,
        mood: Transcript.mood(%{outcome: nil, live: assigns.live, busy: assigns.busy})
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      shell={@shell}
      socket={@socket}
      active={{:thread, @project.slug, @thread.id}}
    >
      <div class="flex h-full flex-col">
        <header class="shrink-0 border-b border-line bg-surface/70 px-3 py-3 backdrop-blur sm:px-4">
          <div class="mx-auto flex w-full max-w-3xl items-center gap-3">
            <div class="min-w-0 flex-1">
              <.back_to_project project={@project} />
              <h1
                id="thread-title"
                class="mt-0.5 truncate text-[17px] font-semibold tracking-tight text-ink"
                title={@thread.title}
              >
                {@thread.title}
              </h1>
            </div>
            <.status busy={@busy} />
          </div>
        </header>

        <div id="thread-conversation" phx-hook="PinToBottom" class="min-h-0 flex-1 overflow-y-auto">
          <div class="mx-auto w-full max-w-3xl px-4 pt-6 pb-4 sm:px-5">
            <div id="thread-entries" phx-update="stream" class="space-y-5">
              <%!-- An answer arrives already shown, streamed in: no rise. --%>
              <div
                :for={{dom_id, entry} <- @streams.entries}
                id={dom_id}
                class={entry.kind != "assistant" && "animate-rise"}
              >
                <.entry
                  entry={entry}
                  results={@results}
                  outputs={@outputs}
                  id_prefix="thread-"
                  image_path={@image_path}
                />
              </div>
            </div>

            <.live_output
              :if={@live || @mood == :thinking}
              live={@live}
              shown={@shown}
              mood={@mood}
              id_prefix="thread-"
            />
          </div>
          <.jump_to_latest />
        </div>

        <.composer
          :if={@shell.model_ready}
          form={@form}
          busy={@busy}
          mode={@mode}
          queued={@queued}
          id_prefix="thread-"
          placeholder="Message this thread..."
          class="blip-clear-x border-t border-line bg-canvas/90 pt-3 backdrop-blur"
        />
        <.sign_in_to_talk
          :if={!@shell.model_ready}
          chatgpt={@shell.chatgpt}
          who="This thread"
          id_prefix="thread-"
        />
      </div>
    </Layouts.app>
    """
  end

  attr :project, Project, required: true

  defp back_to_project(assigns) do
    ~H"""
    <.link
      id="thread-project"
      navigate={~p"/projects/#{@project.slug}"}
      class="inline-flex max-w-full items-center gap-1 text-[12.5px] text-ink-faint transition hover:text-ink"
    >
      <.icon name="hero-arrow-left-micro" class="size-4 shrink-0" />
      <span class="truncate">{@project.name}</span>
    </.link>
    """
  end

  attr :busy, :boolean, required: true

  # Whether the thread is working on something: a run, between its steps too.
  defp status(assigns) do
    ~H"""
    <span
      id="thread-status"
      data-state={if(@busy, do: "running", else: "idle")}
      class={[
        "inline-flex shrink-0 items-center gap-1.5 rounded-full px-2.5 py-1 text-[12px] font-medium",
        if(@busy, do: "bg-accent-soft text-accent-strong", else: "bg-sunken text-ink-soft")
      ]}
    >
      <.dot status={if(@busy, do: :busy, else: :off)} class="size-1.5" />
      {if(@busy, do: "Running", else: "Idle")}
    </span>
    """
  end
end

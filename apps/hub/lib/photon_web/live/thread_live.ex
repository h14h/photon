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
  Stop is `Photon.Threads.stop/1`. Without a model the composer gives way
  to the sign-in, and Stop moves to the header, so a running command can
  still be stopped.

  The thread's state (section 10.4 of
  `docs/plans/step-4-blip-as-coordinator.md`) is its board entry,
  `Photon.Threads.state/1`: a chip by the title (`#thread-state`, words
  from `PhotonWeb.ThreadText.state/1`), and `Resolve` while it isn't
  running and isn't resolved, `Reopen` once it is (`Photon.Threads.resolve/1`
  and `reopen/1`). Having the page open is the owner looking: on connected
  mount, and on each announcement for its project (a run ending among
  them), it calls `Photon.Threads.mark_seen/1` before reading the state,
  which writes and announces nothing unless the thread was unread.

  The entry's open `ask_blip` questions change the composer. While Blip
  has one, a line above the composer says what the thread asked
  (`#thread-asking-blip`) and a note under it says a message waits until
  Blip answers. While one is with the owner, the text box and Send give
  way to a banner per question (`#thread-question-<id>`) with its own
  answer form, which calls `Photon.Questions.answer/2`; Stop stays. A
  refusal shows under its form in the owner's words. Each form's text is
  kept in `drafts` by question ID as it is typed, so a re-read draws it
  again; a draft goes when its question closes. Only this thread's open
  questions are answered: the ID comes from the browser.

  What it hears, and from where:

    * `{:durable, id, changes}` and `{:live, id, event}`
      (`Photon.Threads.subscribe/1`): the thread's commits, and its
      in-flight answer and running commands' output. A commit that
      starts or ends its work also re-reads the state
    * `{:projects_changed, id}` (through `PhotonWeb.Shell`'s subscription):
      for this project, reload it and the thread's entry, since the
      project's name and the thread's title are in the header (the title
      changes when the model names the thread after its first run, or the
      owner renames it), and its state may have moved (a run ended, it was
      resolved or seen elsewhere)
    * `{:questions_changed, id}` (also through the shell, which subscribes
      with `Photon.Questions.subscribe/0`): for this thread, re-read its
      entry, whose open questions changed

  `Schedule` (`#thread-schedule`) beside the title opens a new schedule
  for the project with this thread as its target
  (`/projects/:slug/schedules/new?thread=<id>`), for a prompt that should
  wake the thread at set times.

  The pencil by the title opens it in a small form in its place
  (`#thread-rename-form`): Enter saves (`Photon.Threads.rename/2`), Esc
  or Cancel puts the title back. With Blip's floating panel open on a
  wide screen, the page keeps clear of it (`data-blip-room`, see app.css),
  so the conversation stays readable beside it.

  Everything else the shell passes on (`{:durable_tasks, _}` among them)
  is ignored.

  An unknown project or thread, or a thread under another project's slug,
  goes back to `/` with a flash.
  """

  use PhotonWeb, :live_view

  import PhotonWeb.ConversationComponents

  alias Photon.{Machines, Markdown, Projects, Questions, Threads, Transcript}
  alias Photon.Projects.Project
  alias Photon.Threads.Thread
  alias PhotonWeb.{ConversationView, ThreadText}

  @impl true
  def mount(%{"slug" => slug} = params, _session, socket) do
    with {:ok, project} <- project(slug),
         {:ok, thread} <- thread(project, params, socket.assigns.live_action) do
      {:ok,
       socket
       |> assign(page_title: title(project, thread), project: project, thread: thread)
       |> assign(title_form: nil, entry: nil, drafts: %{}, errors: %{})
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
      outputs: Machines.stopped_outputs(id),
      dom_id: &"thread-entry-#{&1.id}"
    )
    |> look()
  end

  # The owner has the page open, so a finished run is now seen; the state
  # is read after that, so the chip doesn't show Finished for a moment.
  # Only once connected: the first, static render isn't someone looking.
  defp look(%{assigns: %{thread: nil}} = socket), do: socket

  defp look(socket) do
    :ok = if connected?(socket), do: seen(socket.assigns.thread.id), else: :ok
    load_state(socket)
  end

  defp seen(thread_id) do
    # Threads aren't deleted; a missing one only leaves the state as it was.
    _seen = Threads.mark_seen(thread_id)
    :ok
  end

  # The thread's board entry: its state, and its open questions. The
  # thread row comes with it, for the title. Drafts and refusals of
  # questions no longer open go.
  defp load_state(socket) do
    case Threads.state(socket.assigns.thread.id) do
      nil ->
        socket

      entry ->
        open = Enum.map(entry.questions, & &1.id)

        socket
        |> assign(entry: entry, thread: entry.thread)
        |> assign(page_title: title(socket.assigns.project, entry.thread))
        |> update(:drafts, &Map.take(&1, open))
        |> update(:errors, &Map.take(&1, open))
    end
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

  # The title, edited in place: the pencil opens the form, Esc or Cancel
  # closes it.
  def handle_event("rename", _params, socket),
    do: {:noreply, assign(socket, title_form: title_form(socket.assigns.thread.title))}

  def handle_event("cancel_rename", _params, socket),
    do: {:noreply, assign(socket, title_form: nil)}

  def handle_event("save_title", %{"thread" => %{"title" => text}}, socket) do
    case Threads.rename(socket.assigns.thread.id, text) do
      {:ok, thread} ->
        {:noreply, retitled(socket, thread)}

      {:error, :blank} ->
        {:noreply, assign(socket, title_form: title_form(text, "Give it a title."))}

      {:error, :not_found} ->
        {:noreply, gone(socket, no_thread(socket.assigns.project))}
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

  def handle_event("resolve", _params, socket),
    do: {:noreply, resolved(socket, Threads.resolve(socket.assigns.thread.id))}

  def handle_event("reopen", _params, socket),
    do: {:noreply, resolved(socket, Threads.reopen(socket.assigns.thread.id))}

  def handle_event("draft", %{"question_id" => id, "answer" => %{"text" => text}}, socket),
    do: {:noreply, update(socket, :drafts, &Map.put(&1, id, text))}

  # Only one of this thread's open questions: the ID comes from the browser.
  def handle_event("answer", %{"question_id" => id, "answer" => %{"text" => text}}, socket) do
    if Enum.any?(socket.assigns.entry.questions, &(&1.id == id)),
      do: {:noreply, answer(socket, id, text)},
      else: {:noreply, load_state(socket)}
  end

  defp title_form(title, error \\ nil),
    do:
      to_form(%{"title" => title},
        as: :thread,
        errors: if(error, do: [title: {error, []}], else: [])
      )

  defp retitled(socket, thread) do
    assign(socket,
      thread: thread,
      title_form: nil,
      page_title: title(socket.assigns.project, thread)
    )
  end

  defp resolved(socket, :ok), do: load_state(socket)
  defp resolved(socket, {:error, :not_found}), do: gone(socket, no_thread(socket.assigns.project))

  # The answer goes straight to the thread; a refusal stays under the
  # form with what was typed, to be fixed.
  defp answer(socket, id, text) do
    case Questions.answer(id, text) do
      {:ok, _question} ->
        socket
        |> update(:drafts, &Map.delete(&1, id))
        |> update(:errors, &Map.delete(&1, id))
        |> load_state()

      {:error, message} ->
        socket
        |> update(:drafts, &Map.put(&1, id, text))
        |> update(:errors, &Map.put(&1, id, message))
        |> load_state()
    end
  end

  # Only a message queued for this thread: the ID comes from the browser.
  defp withdraw(id, queued) do
    if Enum.any?(queued, &(&1.id == id)), do: Threads.withdraw(id), else: :ok
  end

  ## Updates

  @impl true
  def handle_info({:durable, id, changes}, %{assigns: %{thread: %{id: id}}} = socket) do
    busy = Threads.busy?(id)
    socket = if busy == socket.assigns.busy, do: socket, else: load_state(socket)
    {:noreply, ConversationView.apply_changes(socket, changes, busy, Threads.queued(id))}
  end

  def handle_info({:live, id, event}, %{assigns: %{thread: %{id: id}}} = socket),
    do: {:noreply, ConversationView.apply_live(socket, event)}

  def handle_info({:projects_changed, id}, %{assigns: %{project: %{id: id}}} = socket) do
    case Projects.get(id) do
      %Project{} = project ->
        socket =
          assign(socket, project: project, page_title: title(project, socket.assigns.thread))

        {:noreply, look(socket)}

      nil ->
        {:noreply, gone(socket)}
    end
  end

  def handle_info({:questions_changed, id}, %{assigns: %{thread: %{id: id}}} = socket),
    do: {:noreply, load_state(socket)}

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
              <div
                id="thread-new-purpose"
                class="markdown-body mt-2 line-clamp-3 text-[14px] text-ink-soft"
                title={@project.purpose}
              >
                {raw(Markdown.to_html(@project.purpose))}
              </div>
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
    questions = assigns.entry.questions

    assigns =
      assign(assigns,
        mood: Transcript.mood(%{outcome: nil, live: assigns.live, busy: assigns.busy}),
        with_blip: Enum.filter(questions, &(&1.status == "asked")),
        with_owner: Enum.filter(questions, &(&1.status == "with_owner"))
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      shell={@shell}
      socket={@socket}
      active={{:thread, @project.slug, @thread.id}}
    >
      <%!-- data-blip-room: Blip's floating panel opens beside the thread, not over it (app.css). --%>
      <div id="thread-page" class="flex h-full flex-col" data-blip-room>
        <header class="shrink-0 border-b border-line bg-surface/70 px-3 py-3 backdrop-blur sm:px-4">
          <div class="mx-auto flex w-full max-w-3xl items-center gap-3">
            <div class="min-w-0 flex-1">
              <.back_to_project project={@project} />
              <.title_line :if={is_nil(@title_form)} title={@thread.title} />
              <.title_editor :if={@title_form} form={@title_form} />
            </div>
            <.button
              id="thread-schedule"
              size="sm"
              variant="ghost"
              navigate={~p"/projects/#{@project.slug}/schedules/new?#{[thread: @thread.id]}"}
              title="Schedule a prompt for this thread"
              class="shrink-0"
            >
              <.icon name="hero-clock-micro" class="size-4" />
              <span class="hidden sm:inline">Schedule</span>
            </.button>
            <.state_chip entry={@entry} />
            <.button
              :if={!@busy and is_nil(@thread.resolved_at)}
              type="button"
              id="thread-resolve"
              size="sm"
              variant="ghost"
              phx-click="resolve"
              title="Take it off Home's lists until it gets a new message"
              class="shrink-0"
            >
              <.icon name="hero-check-circle-micro" class="size-4" />
              <span class="hidden sm:inline">Resolve</span>
            </.button>
            <.button
              :if={@thread.resolved_at}
              type="button"
              id="thread-reopen"
              size="sm"
              variant="ghost"
              phx-click="reopen"
              title="Put it back on Home's lists"
              class="shrink-0"
            >
              <.icon name="hero-arrow-uturn-left-micro" class="size-4" />
              <span class="hidden sm:inline">Reopen</span>
            </.button>
            <%!-- Without a model the composer, and its Stop, give way to the sign-in. --%>
            <.button
              :if={@busy and !@shell.model_ready}
              type="button"
              id="thread-stop"
              variant="secondary"
              size="sm"
              phx-click="stop"
            >
              <.icon name="hero-stop-solid" class="size-3.5" /> Stop
            </.button>
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

        <%!-- A question with the owner takes the composer's place: they answer where it's asked. --%>
        <.owner_questions
          :if={@with_owner != []}
          questions={@with_owner}
          with_blip={@with_blip}
          drafts={@drafts}
          errors={@errors}
          queued={@queued}
          stop={@busy and @shell.model_ready}
        />
        <.composer
          :if={@with_owner == [] and @shell.model_ready}
          form={@form}
          busy={@busy}
          mode={@mode}
          queued={@queued}
          id_prefix="thread-"
          placeholder="Message this thread..."
          class="blip-clear-x border-t border-line bg-canvas/90 pt-3 backdrop-blur"
        >
          <:above :if={@with_blip != []}>
            <.asking_blip questions={@with_blip} />
          </:above>
          <:footer :if={@with_blip != []}>
            <p
              id="thread-composer-note"
              class="mt-2 flex items-start gap-1.5 px-1 text-[12px] leading-relaxed text-ink-faint"
            >
              <.icon name="hero-information-circle-micro" class="mt-px size-3.5 shrink-0" />
              Blip has this thread's question. What you send here reaches the thread after Blip answers.
            </p>
          </:footer>
        </.composer>
        <.sign_in_to_talk
          :if={@with_owner == [] and !@shell.model_ready}
          chatgpt={@shell.chatgpt}
          who="This thread"
          id_prefix="thread-"
          class="blip-clear-x"
        />
      </div>
    </Layouts.app>
    """
  end

  attr :questions, :list, required: true, doc: "the thread's questions Blip has"

  # What the thread is waiting on Blip for, above the composer.
  defp asking_blip(assigns) do
    ~H"""
    <div
      id="thread-asking-blip"
      class="mb-2 flex items-start gap-2 rounded-xl border border-accent/20 bg-accent-soft/50 px-3 py-2"
    >
      <.state_mark state={:asking} class="mt-0.5 size-4" />
      <div class="min-w-0 flex-1 space-y-0.5">
        <p
          :for={question <- @questions}
          id={"thread-asking-blip-#{question.id}"}
          class="line-clamp-2 text-[13px] leading-relaxed text-ink-soft"
          title={question.question}
        >
          <span class="font-medium text-accent-strong">Asking Blip:</span>
          {ThreadText.one_line(question.question)}
        </p>
      </div>
    </div>
    """
  end

  attr :questions, :list,
    required: true,
    doc: "the thread's questions with the owner, oldest first"

  attr :with_blip, :list, required: true
  attr :drafts, :map, required: true
  attr :errors, :map, required: true
  attr :queued, :list, required: true

  attr :stop, :boolean,
    required: true,
    doc: "whether Stop is here (without a model it's in the header)"

  # In the composer's place: each question with the owner, with its own
  # answer form, and Stop. The questions scroll inside at most 60% of the
  # screen, under the conversation, so a long question (or two) on a
  # phone can't push the forms or Stop off it; Stop stays below them.
  defp owner_questions(assigns) do
    ~H"""
    <div
      id="thread-questions"
      class="blip-clear-x flex max-h-[60dvh] shrink-0 flex-col border-t border-line bg-canvas/90 backdrop-blur"
    >
      <div
        id="thread-questions-list"
        class="min-h-0 flex-1 overflow-y-auto overscroll-contain px-3 pt-3 sm:px-4"
      >
        <div class={[
          "mx-auto w-full max-w-3xl space-y-2.5",
          if(@stop, do: "pb-2", else: "pb-3 sm:pb-4")
        ]}>
          <.asking_blip :if={@with_blip != []} questions={@with_blip} />
          <.queued_messages queued={@queued} id_prefix="thread-" />
          <.question_banner
            :for={question <- @questions}
            question={question}
            draft={Map.get(@drafts, question.id, "")}
            error={Map.get(@errors, question.id)}
          />
        </div>
      </div>
      <div :if={@stop} class="shrink-0 px-3 pt-1 pb-3 sm:px-4 sm:pb-4">
        <div class="mx-auto flex w-full max-w-3xl items-center gap-3 px-1">
          <p class="flex-1 text-[12px] leading-relaxed text-ink-faint">
            The thread is waiting for your answer.
          </p>
          <.button type="button" id="thread-stop" variant="secondary" size="sm" phx-click="stop">
            <.icon name="hero-stop-solid" class="size-3.5" /> Stop
          </.button>
        </div>
      </div>
    </div>
    """
  end

  attr :question, :map, required: true
  attr :draft, :string, required: true
  attr :error, :string, default: nil

  # One question with the owner: Blip's wording of it (or the thread's own
  # words when the hub passed it on), when, and the answer form.
  defp question_banner(assigns) do
    question = assigns.question
    hub? = question.passed_by == "hub" or is_nil(question.wording)

    assigns =
      assign(assigns,
        id: "thread-question-#{question.id}",
        hub?: hub?,
        text: if(hub?, do: question.question, else: question.wording),
        passed_at: question.passed_at || question.inserted_at,
        form: to_form(%{"text" => assigns.draft}, as: :answer)
      )

    ~H"""
    <div
      id={@id}
      class="animate-rise rounded-2xl border border-warn/40 bg-surface px-4 py-3.5 shadow-sm shadow-warn/5"
    >
      <div class="flex items-start gap-2.5">
        <span class="mt-1.5 flex size-3.5 shrink-0 items-center justify-center">
          <.state_mark state={:waiting} class="size-3.5" />
        </span>
        <div class="min-w-0 flex-1">
          <div class="flex items-baseline gap-3">
            <p class="text-[11px] font-semibold tracking-wider text-ink-faint uppercase">
              {if(@hub?, do: "The thread asks you", else: "Blip passed this on")}
            </p>
            <span :if={@passed_at} class="ml-auto shrink-0 text-[12px] text-ink-faint">
              <.local_time id={"#{@id}-at"} at={@passed_at} />
            </span>
          </div>
          <%!-- A long question scrolls on its own, so its answer box stays near. --%>
          <p
            id={"#{@id}-text"}
            class="mt-1 max-h-[30dvh] overflow-y-auto overscroll-contain text-[14.5px] leading-relaxed whitespace-pre-line text-ink"
          >
            {@text}
          </p>
          <p :if={@hub?} id={"#{@id}-note"} class="mt-1 text-[12.5px] text-ink-faint">
            In the thread's own words. Your answer goes straight to it.
          </p>
        </div>
      </div>
      <.form for={@form} id={"#{@id}-form"} phx-change="draft" phx-submit="answer" class="mt-3">
        <input type="hidden" name="question_id" value={@question.id} />
        <.answer_box field={@form[:text]} id={"#{@id}-answer"} />
        <div class="mt-2 flex items-center gap-3">
          <p :if={@error} id={"#{@id}-error"} class="flex items-center gap-1.5 text-[12.5px] text-bad">
            <.icon name="hero-exclamation-circle-micro" class="size-4 shrink-0" />
            {@error}
          </p>
          <.button id={"#{@id}-send"} type="submit" size="sm" variant="primary" class="ml-auto">
            Send <.icon name="hero-paper-airplane-micro" class="size-4" />
          </.button>
        </div>
      </.form>
    </div>
    """
  end

  attr :title, :string, required: true

  # The title, with a pencil to rename the thread.
  defp title_line(assigns) do
    ~H"""
    <div class="group/title mt-0.5 flex min-w-0 items-center gap-1.5">
      <h1
        id="thread-title"
        class="min-w-0 truncate text-[17px] font-semibold tracking-tight text-ink"
        title={@title}
      >
        {@title}
      </h1>
      <button
        type="button"
        id="thread-rename"
        phx-click="rename"
        class="shrink-0 rounded-md p-1 text-ink-faint opacity-60 transition group-hover/title:opacity-100 hover:bg-sunken hover:text-ink focus-visible:opacity-100"
        title="Rename"
        aria-label="Rename this thread"
      >
        <.icon name="hero-pencil-micro" class="size-3.5" />
      </button>
    </div>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true

  # The title in a box, in its place: Enter saves, Esc cancels.
  defp title_editor(assigns) do
    ~H"""
    <.form
      for={@form}
      id="thread-rename-form"
      phx-submit="save_title"
      class="mt-0.5 flex items-start gap-1.5"
    >
      <div class="min-w-0 flex-1">
        <.input
          field={@form[:title]}
          id="thread-title-input"
          maxlength="80"
          autocomplete="off"
          aria-label="Title"
          phx-mounted={JS.focus()}
          phx-keydown="cancel_rename"
          phx-key="Escape"
          class="block h-8 w-full rounded-lg border border-accent/60 bg-surface px-2.5 text-[15px] font-semibold tracking-tight text-ink shadow-xs outline-none focus:ring-3 focus:ring-accent/15"
        />
      </div>
      <.button type="submit" id="thread-rename-save" variant="primary" size="sm">Save</.button>
      <.button
        type="button"
        id="thread-rename-cancel"
        variant="ghost"
        size="sm"
        phx-click="cancel_rename"
      >
        Cancel
      </.button>
    </.form>
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

  attr :entry, :map, required: true, doc: "the thread's board entry (`Photon.Threads.state/1`)"

  # The thread's state, in the words and mark the sidebar and Home use.
  defp state_chip(assigns) do
    assigns = assign(assigns, state: assigns.entry.state)

    ~H"""
    <span
      id="thread-state"
      data-state={@state}
      class={[
        "inline-flex shrink-0 items-center gap-1.5 rounded-full px-2.5 py-1 text-[12px] font-medium",
        @state in [:running, :asking, :unread] && "bg-accent-soft text-accent-strong",
        @state == :waiting && "bg-warn-soft text-ink",
        @state == :failed && "bg-bad-soft text-bad",
        @state in [:quiet, :idle] && "bg-sunken text-ink-soft"
      ]}
    >
      <.state_mark state={@state} class="size-3.5" />
      <.icon :if={@state == :quiet} name="hero-pause-circle-micro" class="size-3.5 text-ink-faint" />
      <.dot :if={@state == :idle} status={:off} class="size-1.5" />
      {ThreadText.state(@entry)}
    </span>
    """
  end
end

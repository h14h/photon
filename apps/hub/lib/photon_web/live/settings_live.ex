defmodule PhotonWeb.SettingsLive do
  @moduledoc """
  Settings: sign in with ChatGPT (`Photon.ChatGPT`), the model and effort
  Blip uses on the owner's plan, ambient mode, what Blip should know
  about the owner, and below the form, Blip's memory
  (`Photon.Assistant.memory/0`) and a fresh start for the conversation.
  The form changes nothing until it is saved (`Photon.Settings.save/1`).

  Ambient mode is in the same form but saved by
  `Photon.Ambient.configure/1`, after the settings file: its setting is a
  durable doc, written in the commit that arms or retires its timers.
  The section shows whenever Blip can think, and while ambient mode is on
  even when it can't, so it can always be turned off. When it doesn't
  show, the form carries none of its fields and a Save leaves it as it
  was. The form starts from the saved settings merged with the setting's
  values (`PhotonWeb.AmbientText.form_values/1`), on mount and after
  every Save, so a Save sends the switch back as it is. A colocated hook
  fills in the browser's UTC offset, which the review's 09:00 follows.
  The run-now buttons show only with the scripted model; with a real
  sign-in nothing here spends the plan.
  """

  use PhotonWeb, :live_view

  alias Photon.{Ambient, Assistant, ChatGPT, Projects, Settings}
  alias PhotonWeb.AmbientText

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: subscribe()
    settings = Settings.load()
    status = ChatGPT.status()
    ambient = Ambient.status()

    {:ok,
     socket
     |> assign(
       page_title: "Settings",
       settings: settings,
       ambient: ambient,
       form: settings_form(settings, ambient),
       chatgpt: status,
       sign_in_url: nil,
       sign_in_form: to_form(%{"address" => ""}, as: :sign_in),
       sign_in_error: nil,
       models: [],
       models_error: nil,
       memory: Assistant.memory(),
       editing_memory: false
     )
     |> load_models(status)}
  end

  defp subscribe do
    :ok = ChatGPT.subscribe()
    :ok = Ambient.subscribe()
    :ok = Projects.subscribe()
  end

  # The form starts from the saved settings and ambient mode's saved values,
  # which live in a durable doc, not the settings file.
  defp settings_form(settings, ambient),
    do: to_form(Map.merge(settings, AmbientText.form_values(ambient)), as: :settings)

  # The model list needs the account's token, so it loads after sign-in, in
  # the background.
  defp load_models(socket, %{state: :signed_in}) do
    if connected?(socket), do: start_async(socket, :models, &ChatGPT.models/0), else: socket
  end

  defp load_models(socket, _status), do: assign(socket, models: [], models_error: nil)

  @impl true
  def handle_async(:models, {:ok, {:ok, models}}, socket),
    do: {:noreply, assign(socket, models: models, models_error: nil)}

  def handle_async(:models, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, models_error: reason)}

  def handle_async(:models, {:exit, reason}, socket),
    do: {:noreply, assign(socket, models_error: Exception.format_exit(reason))}

  ## Memory and the conversation

  @impl true
  def handle_event("edit_memory", _params, socket),
    do: {:noreply, assign(socket, editing_memory: true)}

  def handle_event("cancel_memory", _params, socket),
    do: {:noreply, assign(socket, editing_memory: false)}

  def handle_event("save_memory", %{"memory" => text}, socket) do
    Assistant.put_memory(text)
    {:noreply, assign(socket, memory: Assistant.memory(), editing_memory: false)}
  end

  def handle_event("fresh_start", _params, socket) do
    Assistant.fresh_start(Assistant.conversation_id())

    {:noreply,
     put_flash(
       socket,
       :info,
       "Started a fresh context. Earlier messages stay in the chat, but Blip won't see them."
     )}
  end

  ## Signing in

  def handle_event("begin_sign_in", _params, socket) do
    {:ok, url} = ChatGPT.begin_sign_in()
    {:noreply, assign(socket, sign_in_url: url, sign_in_error: nil)}
  end

  def handle_event("finish_sign_in", %{"sign_in" => %{"address" => address}}, socket) do
    case ChatGPT.finish_sign_in(address) do
      :ok ->
        {:noreply,
         socket
         |> assign(sign_in_url: nil, sign_in_form: to_form(%{"address" => ""}, as: :sign_in))
         |> put_flash(:info, "Signed in with ChatGPT. Blip is awake.")}

      # The address carries a one-time code, so it isn't kept on the page.
      {:error, reason} ->
        {:noreply,
         assign(socket,
           sign_in_error: reason,
           sign_in_form: to_form(%{"address" => ""}, as: :sign_in)
         )}
    end
  end

  def handle_event("cancel_sign_in", _params, socket) do
    :ok = ChatGPT.cancel_sign_in()

    {:noreply,
     assign(socket,
       sign_in_url: nil,
       sign_in_error: nil,
       sign_in_form: to_form(%{"address" => ""}, as: :sign_in)
     )}
  end

  def handle_event("sign_out", _params, socket) do
    :ok = ChatGPT.sign_out()
    {:noreply, put_flash(socket, :info, "Signed out of ChatGPT.")}
  end

  ## The settings form

  def handle_event("change", %{"settings" => params}, socket),
    do: {:noreply, assign(socket, form: to_form(params, as: :settings))}

  # Two writes, each whole: the settings file, then ambient mode's doc and
  # its timers in one commit. The form is rebuilt from both, so the switch
  # stays as saved.
  def handle_event("save", %{"settings" => params}, socket) do
    settings = Settings.save(params)
    :ok = Ambient.configure(params)
    ambient = Ambient.status()

    {:noreply,
     socket
     |> assign(settings: settings, ambient: ambient, form: settings_form(settings, ambient))
     |> put_flash(:info, "Saved. The next message uses these settings.")}
  end

  ## Ambient mode's run-now buttons (scripted model only)

  def handle_event("digest_now", _params, socket), do: run_now(socket, "digest")
  def handle_event("review_now", _params, socket), do: run_now(socket, "review")

  defp run_now(socket, job) do
    if socket.assigns.ambient.scripted? do
      result = if job == "digest", do: Ambient.digest_now(), else: Ambient.review_now()

      {:noreply,
       socket
       |> assign(ambient: Ambient.status())
       |> put_flash(AmbientText.ran_kind(result), AmbientText.ran(job, result))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:chatgpt_changed, status}, socket) do
    {:noreply,
     socket
     |> assign(chatgpt: status, ambient: Ambient.status())
     |> load_models(status)}
  end

  def handle_info({:durable, "global", changes}, socket) do
    if Enum.any?(changes.docs, &(&1.kind == "memory")),
      do: {:noreply, assign(socket, memory: Assistant.memory())},
      else: {:noreply, socket}
  end

  # A save, a firing, a collected item, or a thread opened or resolved
  # (which changes what is new to the owner): the status follows along.
  def handle_info({:ambient_changed}, socket),
    do: {:noreply, assign(socket, ambient: Ambient.status())}

  def handle_info({:projects_changed, _project_id}, socket),
    do: {:noreply, assign(socket, ambient: Ambient.status())}

  def handle_info(_message, socket), do: {:noreply, socket}

  # The account's models, with the one in use kept even if it isn't listed.
  defp model_options(models, current) do
    options = Enum.map(models, &{&1.name, &1.id})
    ids = Enum.map(models, & &1.id)

    if current in ids,
      do: options,
      else: [{Settings.model_label(current), current} | options]
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        model: Settings.model(assigns.settings),
        thinks?: ChatGPT.ready?(assigns.chatgpt)
      )

    ~H"""
    <Layouts.app flash={@flash} shell={@shell} socket={@socket} active={:settings}>
      <div class="h-full overflow-y-auto">
        <div class="blip-clear-y mx-auto w-full max-w-2xl px-4 py-8 sm:px-6">
          <.header>
            Settings
            <:subtitle>
              Blip runs on your ChatGPT plan, through this hub. Your machines never see the sign-in.
            </:subtitle>
          </.header>

          <section
            id="chatgpt"
            class="mt-8 space-y-4 rounded-2xl border border-line bg-surface p-5 shadow-xs"
          >
            <div class="flex items-center justify-between gap-3">
              <h2 class="text-[13px] font-semibold text-ink">ChatGPT</h2>
              <span
                :if={@chatgpt.state == :signed_in}
                class="flex items-center gap-1.5 text-[12px] text-ok"
              >
                <.icon name="hero-check-circle-micro" class="size-4" /> Signed in
              </span>
            </div>

            <%= if @chatgpt.state == :signed_in do %>
              <.signed_in chatgpt={@chatgpt} />
            <% else %>
              <.sign_in
                chatgpt={@chatgpt}
                url={@sign_in_url}
                form={@sign_in_form}
                error={@sign_in_error}
              />
            <% end %>
          </section>

          <.form
            for={@form}
            id="settings-form"
            phx-change="change"
            phx-submit="save"
            class="mt-8 space-y-8"
          >
            <section
              :if={@chatgpt.state == :signed_in}
              class="space-y-5 rounded-2xl border border-line bg-surface p-5 shadow-xs"
            >
              <h2 class="text-[13px] font-semibold text-ink">Model</h2>
              <.input
                field={@form[:model]}
                type="select"
                label="Model"
                value={@model}
                options={model_options(@models, @model)}
                hint={@models_error && "Couldn't load your plan's models: #{@models_error}"}
              />
              <.input
                field={@form[:reasoning]}
                type="select"
                label="Reasoning effort"
                options={[
                  {"Model default", ""},
                  {"Low", "low"},
                  {"Medium", "medium"},
                  {"High", "high"},
                  {"Extra high", "xhigh"}
                ]}
                hint="More effort is slower and uses more of your plan."
              />
              <div>
                <.input
                  field={@form[:scheduled_work]}
                  type="checkbox"
                  label="Let schedules use my plan while I'm away"
                />
                <p
                  id="scheduled-work-hint"
                  class="mt-1 pl-6.5 text-[12px] leading-relaxed text-ink-faint"
                >
                  Blip's schedules and your projects' schedules run on your plan without you there. Off, they skip their runs: Blip and threads say so in the conversation, and the project page shows it on the schedule.
                </p>
              </div>
            </section>

            <.ambient_section
              :if={@thinks? or @ambient.on?}
              form={@form}
              ambient={@ambient}
              thinks?={@thinks?}
            />

            <section class="space-y-5 rounded-2xl border border-line bg-surface p-5 shadow-xs">
              <h2 class="text-[13px] font-semibold text-ink">Blip</h2>
              <.input
                field={@form[:user_name]}
                label="Your name"
                placeholder="Henry"
                hint="What Blip calls you."
                autocomplete="off"
              />
              <.input
                field={@form[:timezone]}
                label="Your time zone"
                placeholder="America/Chicago"
                hint="So schedules and times make sense to you."
              />
              <.input
                field={@form[:instructions]}
                type="textarea"
                rows="5"
                label="Standing instructions"
                placeholder="How Blip should work with you: which machine to prefer, what to always check first..."
              />
            </section>

            <div class="flex justify-end">
              <.button type="submit" variant="primary" id="save-settings">Save settings</.button>
            </div>
          </.form>

          <section
            id="memory"
            class="mt-6 space-y-3 rounded-2xl border border-line bg-surface p-5 shadow-xs"
          >
            <div class="flex items-center justify-between">
              <h2 class="text-[13px] font-semibold text-ink">What Blip remembers</h2>
              <.button
                :if={!@editing_memory}
                id="edit-memory"
                size="sm"
                variant="ghost"
                phx-click="edit_memory"
              >
                Edit
              </.button>
            </div>
            <form :if={@editing_memory} id="memory-form" phx-submit="save_memory" class="space-y-2">
              <textarea
                name="memory"
                rows="8"
                class={[field_class(), "h-auto py-2 font-mono text-[12.5px] leading-relaxed"]}
              >{@memory}</textarea>
              <div class="flex justify-end gap-2">
                <.button type="button" size="sm" variant="ghost" phx-click="cancel_memory">
                  Cancel
                </.button>
                <.button type="submit" size="sm" variant="primary">Save</.button>
              </div>
            </form>
            <div
              :if={!@editing_memory}
              id="memory-text"
              class="rounded-lg bg-sunken px-3.5 py-3 text-[13px] leading-relaxed text-ink-soft"
            >
              <span phx-no-format class="whitespace-pre-wrap">{if(@memory == "", do: "Empty. Blip saves facts here as it learns them.", else: @memory)}</span>
            </div>
            <div class="flex items-center justify-between gap-3 border-t border-line pt-4">
              <p class="text-[12.5px] leading-relaxed text-ink-faint">
                A fresh context keeps the chat history and memory, but Blip stops seeing earlier messages.
              </p>
              <.button
                id="fresh-start"
                size="sm"
                phx-click="fresh_start"
                data-confirm="Start a fresh context? Blip stops seeing earlier messages (they stay in the chat). Memory is kept."
              >
                <.icon name="hero-arrow-path" class="size-4" /> Fresh context
              </.button>
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :form, :any, required: true
  attr :ambient, :map, required: true
  attr :thinks?, :boolean, required: true

  # Without a model, only the switch, the warning and the status: the
  # interval, the offset and the run-now buttons keep what was saved.
  defp ambient_section(assigns) do
    ~H"""
    <section id="ambient" class="space-y-5 rounded-2xl border border-line bg-surface p-5 shadow-xs">
      <div class="flex items-center justify-between gap-3">
        <h2 class="text-[13px] font-semibold text-ink">Ambient mode</h2>
        <span :if={@ambient.on?} id="ambient-on" class="flex items-center gap-1.5 text-[12px] text-ok">
          <.icon name="hero-signal-micro" class="size-4" /> On
        </span>
      </div>
      <div>
        <.input field={@form[:ambient]} type="checkbox" label="Let Blip follow along and speak up" />
        <p id="ambient-hint" class="mt-1 pl-6.5 text-[12px] leading-relaxed text-ink-faint">
          {AmbientText.hint()}
        </p>
      </div>
      <p
        :if={!@thinks?}
        id="ambient-needs-model"
        class="rounded-lg bg-warn-soft px-3 py-2 text-[13px] leading-relaxed text-ink"
      >
        {AmbientText.needs_model()}
      </p>
      <.input
        :if={@thinks?}
        field={@form[:ambient_every]}
        type="select"
        label="Digest"
        options={AmbientText.every_options(Ambient.every_options())}
      />
      <%!-- The browser's UTC offset, which the review's 09:00 follows. Empty
      until the hook runs, and an empty one keeps what was saved. --%>
      <input
        :if={@thinks?}
        type="hidden"
        id="settings_utc_offset"
        name="settings[utc_offset]"
        value=""
        phx-hook=".UtcOffset"
        phx-update="ignore"
      />
      <script :type={Phoenix.LiveView.ColocatedHook} name=".UtcOffset">
        // Minutes east of UTC, as the server counts them (getTimezoneOffset
        // counts west).
        export default {
          mounted() { this.el.value = String(-new Date().getTimezoneOffset()) }
        }
      </script>
      <p
        :if={@thinks? and AmbientText.needs_consent?(@ambient)}
        id="ambient-needs-consent"
        class="rounded-lg bg-warn-soft px-3 py-2 text-[13px] leading-relaxed text-ink"
      >
        {AmbientText.needs_consent()}
      </p>
      <.ambient_state :if={@ambient.on?} ambient={@ambient} />
      <div
        :if={@thinks? and @ambient.scripted?}
        id="ambient-try"
        class="flex flex-wrap items-center justify-between gap-3 border-t border-line pt-4"
      >
        <p class="text-[12.5px] leading-relaxed text-ink-faint">
          On the scripted model, try it without waiting for the timers.
        </p>
        <div class="flex items-center gap-1">
          <.button
            type="button"
            id="ambient-digest-now"
            size="sm"
            variant="ghost"
            phx-click="digest_now"
          >
            <.icon name="hero-newspaper-micro" class="size-4" /> Send a digest now
          </.button>
          <.button
            type="button"
            id="ambient-review-now"
            size="sm"
            variant="ghost"
            phx-click="review_now"
          >
            <.icon name="hero-sun-micro" class="size-4" /> Run the review now
          </.button>
        </div>
      </div>
    </section>
    """
  end

  attr :ambient, :map, required: true

  defp ambient_state(assigns) do
    assigns = assign(assigns, next: AmbientText.next(assigns.ambient))

    ~H"""
    <div
      id="ambient-state"
      class="space-y-2 rounded-lg bg-sunken px-3.5 py-3 text-[13px] leading-relaxed text-ink-soft"
    >
      <p :if={@next} id="ambient-next" class="flex items-start gap-2">
        <.icon name="hero-clock-micro" class="mt-0.5 size-4 shrink-0 text-ink-faint" />
        <span phx-no-format><%= for part <- @next do %><%= case part do %><% {:time, suffix, at} -> %><.local_time id={"ambient-next-" <> suffix} at={at} class="text-ink" /><% words -> %>{words}<% end %><% end %></span>
      </p>
      <p id="ambient-pending" class="flex items-start gap-2">
        <.icon name="hero-inbox-stack-micro" class="mt-0.5 size-4 shrink-0 text-ink-faint" />
        <span>{AmbientText.pending(@ambient.pending)}</span>
      </p>
      <.ambient_last :if={@ambient.last_digest} job="digest" result={@ambient.last_digest} />
      <.ambient_last :if={@ambient.last_review} job="review" result={@ambient.last_review} />
      <p :if={@ambient.stopped} id="ambient-stopped" class="flex items-start gap-2 text-bad">
        <.icon name="hero-exclamation-triangle-micro" class="mt-0.5 size-4 shrink-0" />
        <span>{AmbientText.stopped(@ambient.stopped)}</span>
      </p>
    </div>
    """
  end

  attr :job, :string, required: true
  attr :result, :map, required: true

  defp ambient_last(assigns) do
    ~H"""
    <p id={"ambient-last-#{@job}"} class="flex items-start gap-2">
      <.icon
        name={if(@job == "digest", do: "hero-newspaper-micro", else: "hero-sun-micro")}
        class="mt-0.5 size-4 shrink-0 text-ink-faint"
      />
      <span phx-no-format>{AmbientText.last_label(@job)} <.local_time id={"ambient-last-#{@job}-at"} at={@result.at} class="text-ink" />: {AmbientText.last(@job, @result)}</span>
    </p>
    """
  end

  attr :chatgpt, :map, required: true

  defp signed_in(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center justify-between gap-3">
      <p class="text-[14px] text-ink-soft">
        Signed in as <span id="chatgpt-account" class="font-medium text-ink">{@chatgpt.email || @chatgpt.name}</span>.
      </p>
      <.button
        type="button"
        size="sm"
        variant="ghost"
        id="sign-out"
        phx-click="sign_out"
        data-confirm="Sign out of ChatGPT? Blip stops until you sign in again."
      >
        Sign out
      </.button>
    </div>
    <p
      :if={!@chatgpt.plan_use}
      id="no-plan-use"
      class="rounded-lg bg-warn-soft px-3 py-2 text-[13px] leading-relaxed text-ink"
    >
      Photon wasn't allowed to use your plan, so Blip can't think yet. Sign out, sign in again, and allow it.
    </p>
    """
  end

  attr :chatgpt, :map, required: true
  attr :url, :string, default: nil
  attr :form, :any, required: true
  attr :error, :string, default: nil

  defp sign_in(assigns) do
    ~H"""
    <p :if={@chatgpt.state == :sign_in_again} class="text-[14px] leading-relaxed text-ink">
      Your ChatGPT sign-in lapsed. Sign in again to wake Blip up.
    </p>
    <p :if={@chatgpt.state == :signed_out} class="text-[14px] leading-relaxed text-ink-soft">
      Blip needs a model to think with. Sign in with ChatGPT and Photon uses your ChatGPT plan, nothing billed here.
    </p>

    <.button
      :if={is_nil(@url)}
      type="button"
      variant="primary"
      id="begin-sign-in"
      phx-click="begin_sign_in"
    >
      Sign in with ChatGPT
    </.button>

    <ol :if={@url} id="sign-in-steps" class="space-y-4">
      <li class="flex gap-3">
        <span class="grid size-6 shrink-0 place-items-center rounded-full bg-accent-soft text-[12px] font-semibold text-accent-strong">
          1
        </span>
        <div class="min-w-0 space-y-2 pt-0.5">
          <p class="text-[14px] text-ink">Approve Photon in ChatGPT.</p>
          <.button
            href={@url}
            target="_blank"
            rel="noopener"
            variant="primary"
            size="sm"
            id="open-sign-in"
          >
            Open ChatGPT <.icon name="hero-arrow-top-right-on-square-micro" class="size-4" />
          </.button>
        </div>
      </li>
      <li class="flex gap-3">
        <span class="grid size-6 shrink-0 place-items-center rounded-full bg-accent-soft text-[12px] font-semibold text-accent-strong">
          2
        </span>
        <div class="min-w-0 flex-1 space-y-2 pt-0.5">
          <p class="text-[14px] leading-relaxed text-ink">
            ChatGPT then sends you to a page that won't load. That's expected. Copy its whole address (it starts with <code class="rounded bg-sunken px-1 font-mono text-[12.5px]">http://127.0.0.1</code>)
            and paste it here.
          </p>
          <.form for={@form} id="finish-sign-in" phx-submit="finish_sign_in" class="space-y-2">
            <.input
              field={@form[:address]}
              placeholder="http://127.0.0.1:…/auth/callback?code=…"
              autocomplete="off"
            />
            <p :if={@error} id="sign-in-error" class="text-[13px] text-bad">{@error}</p>
            <div class="flex items-center gap-2">
              <.button type="submit" variant="primary" size="sm" id="finish-sign-in-button">
                Finish signing in
              </.button>
              <.button type="button" variant="ghost" size="sm" phx-click="cancel_sign_in">
                Cancel
              </.button>
            </div>
          </.form>
        </div>
      </li>
    </ol>
    """
  end
end

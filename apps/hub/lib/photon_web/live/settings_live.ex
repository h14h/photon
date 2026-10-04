defmodule PhotonWeb.SettingsLive do
  @moduledoc """
  The model Blip (the assistant) and nodes use, and what Blip should know
  about you: your name, your time zone, and your standing instructions. The form changes nothing until it is saved
  (`Photon.Settings.save/1`).
  """

  use PhotonWeb, :live_view

  alias Photon.Settings
  alias PhotonCore.LLM

  @impl true
  def mount(_params, _session, socket) do
    settings = Settings.load()

    {:ok,
     socket
     |> assign(page_title: "Settings", settings: settings, form: settings_form(settings))
     |> assign_provider()}
  end

  defp settings_form(settings), do: to_form(Map.put(settings, "api_key", ""), as: :settings)

  # What the form says about the provider it shows: its defaults and
  # whether a key is saved or set in the hub's environment.
  defp assign_provider(socket) do
    provider = socket.assigns.form[:provider].value || socket.assigns.settings["provider"]
    info = LLM.provider(provider) || %{}

    assign(socket,
      provider: provider,
      default_model: info[:default_model],
      default_base_url: info[:base_url],
      key_env: info[:key_env],
      env_key?: Settings.env_key?(provider),
      saved_key?:
        socket.assigns.settings["api_key"] != "" and
          socket.assigns.settings["provider"] == provider
    )
  end

  @impl true
  def handle_event("change", %{"settings" => params}, socket) do
    {:noreply, socket |> assign(form: to_form(params, as: :settings)) |> assign_provider()}
  end

  def handle_event("save", %{"settings" => params}, socket) do
    settings = Settings.save(params)

    {:noreply,
     socket
     |> assign(settings: settings, form: settings_form(settings))
     |> assign_provider()
     |> put_flash(:info, "Saved. The next message uses these settings.")}
  end

  def handle_event("clear_key", _params, socket) do
    settings =
      Settings.save(Map.merge(socket.assigns.settings, %{"api_key" => "", "clear_key" => true}))

    {:noreply,
     socket
     |> assign(settings: settings, form: settings_form(settings))
     |> assign_provider()
     |> put_flash(:info, "Removed the saved key.")}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} shell={@shell} active={:settings}>
      <div class="h-full overflow-y-auto">
        <div class="mx-auto w-full max-w-2xl px-4 py-8 sm:px-6">
          <.header>
            Settings
            <:subtitle>
              One model serves Blip and the agents on your nodes. Nodes reach it through this hub, so they never see the key.
            </:subtitle>
          </.header>

          <.form
            for={@form}
            id="settings-form"
            phx-change="change"
            phx-submit="save"
            class="mt-8 space-y-8"
          >
            <section class="space-y-5 rounded-2xl border border-line bg-surface p-5 shadow-xs">
              <h2 class="text-[13px] font-semibold text-ink">Model</h2>
              <.input
                field={@form[:provider]}
                type="select"
                label="Provider"
                options={Enum.map(Settings.providers(), fn {id, name} -> {name, id} end)}
              />

              <div :if={@provider != "mock"} class="space-y-5">
                <.input
                  field={@form[:model]}
                  label="Model"
                  placeholder={@default_model || "Model ID"}
                  hint={
                    if(@default_model, do: "Leave blank for #{@default_model}.", else: "Required.")
                  }
                  autocomplete="off"
                />
                <.input
                  :if={@provider not in ["ollama"]}
                  field={@form[:api_key]}
                  type="password"
                  label="API key"
                  autocomplete="off"
                  placeholder={
                    cond do
                      @saved_key? -> "Saved. Type a new key to replace it."
                      @env_key? -> "Using #{@key_env} from the hub's environment"
                      true -> "Paste your key"
                    end
                  }
                />
                <div :if={@saved_key?} class="-mt-3 flex justify-end">
                  <button
                    type="button"
                    phx-click="clear_key"
                    class="text-[12px] text-ink-faint hover:text-bad"
                  >Remove saved key</button>
                </div>
                <.input
                  :if={@provider in ["custom", "ollama"]}
                  field={@form[:base_url]}
                  label="Base URL"
                  placeholder={@default_base_url || "https://example.com/v1"}
                  hint="An OpenAI-compatible endpoint, ending before /chat/completions."
                />
                <.input
                  field={@form[:reasoning]}
                  type="select"
                  label="Reasoning effort"
                  options={[
                    {"Model default", ""},
                    {"Low", "low"},
                    {"Medium", "medium"},
                    {"High", "high"}
                  ]}
                  hint="Only sent if the model supports it."
                />
              </div>
              <p :if={@provider == "mock"} class="text-[13px] leading-relaxed text-ink-soft">
                The mock model follows fixed phrasings, so you can try everything without a key. Type
                <code class="rounded bg-sunken px-1 font-mono">help</code>
                in the chat to see them.
              </p>
            </section>

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
        </div>
      </div>
    </Layouts.app>
    """
  end
end

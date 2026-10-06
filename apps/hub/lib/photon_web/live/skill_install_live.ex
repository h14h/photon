defmodule PhotonWeb.SkillInstallLive do
  @moduledoc """
  Installing a skill at `/skills/install` (section 6.5 of
  `docs/plans/step-3-skills-and-schedules.md`), from a link or a pasted
  SKILL.md.

  Two ways in, as tabs over one card:

    * From a link: `Skills.fetch/1` runs in a `start_async/3` task (it
      makes HTTP requests, so never in a callback), with `Fetching...`
      shown until it answers. A refused link shows its message under the
      field.
    * Paste: `Skills.read/1` reads the text in the callback (no I/O).

  Both forms stay in the page while hidden, so switching tabs keeps what
  was typed. A new fetch or read replaces the last answer.

  What comes back are candidates (`assigns.candidates`), which install
  takes `origin`, `source_url`, the notes and the left-out files from;
  the forms give only names, descriptions and instructions.

    * One candidate opens the preview form, prefilled and editable, with
      its notes and where it came from. A name another skill has is
      flagged under the field as soon as it shows. `Install` goes to the
      skill's page.
    * Several (a folder of skills) are a list to pick from, under
      `fetch/1`'s notice when the folder had more than 30. One that
      can't be picked says why: its download failed, its SKILL.md has no
      name or description, or its name is taken. `Install selected`
      installs each pick under its own name and goes to `/skills`; a pick
      that fails stays listed with its message, and the ones that went in
      are marked installed. A row that can't be picked but was read can
      be installed on its own: it opens in the preview form, to fix there,
      with a way back to the list.

  While a list is open the page follows `Skills.subscribe/0`, so a name
  taken elsewhere becomes unpickable. Everything else the shell passes on
  is ignored.
  """

  use PhotonWeb, :live_view

  import PhotonWeb.EditorComponents, only: [editor_tab: 1]

  alias Photon.{Markdown, Skills}
  alias PhotonWeb.SkillText

  @field_order [:name, :description, :instructions]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :ok = Skills.subscribe()

    {:ok,
     socket
     |> assign(page_title: "Install a skill", source: "url", tab: "write")
     |> assign(url_form: to_form(%{"url" => ""}, as: :link))
     |> assign(paste_form: to_form(%{"text" => ""}, as: :paste))
     |> assign(fetching?: false, error: nil)
     |> stream_configure(:candidates, dom_id: &"install-candidate-#{&1.n}")
     |> show([], nil)}
  end

  ## The answer on show

  # Shows `candidates` (none, one to preview, or several to pick from)
  # with the folder's notice, in place of the last answer.
  defp show(socket, candidates, notice) do
    socket
    |> assign(candidates: candidates, notice: notice, tab: "write", back: nil)
    |> assign(picked: MapSet.new(), installed: %{}, failed: %{})
    |> prefill()
    |> rows()
  end

  defp prefill(%{assigns: %{candidates: [candidate]}} = socket) do
    params = %{
      "name" => candidate.name || "",
      "description" => candidate.description || "",
      "instructions" => candidate.instructions || ""
    }

    assign(socket, form: install_form(params, taken(params["name"])))
  end

  defp prefill(socket), do: assign(socket, form: nil)

  # The list's rows, read again whenever a pick, an install or a name
  # elsewhere changes; at most 30.
  defp rows(%{assigns: %{candidates: [_one, _two | _rest] = candidates}} = socket) do
    rows = for {candidate, n} <- Enum.with_index(candidates), do: row(socket, candidate, n)

    socket
    |> assign(pickable: for(%{reason: nil, installed: nil, n: n} <- rows, do: n))
    |> stream(:candidates, rows, reset: true)
  end

  defp rows(socket), do: socket |> assign(pickable: []) |> stream(:candidates, [], reset: true)

  defp row(%{assigns: %{installed: installed, failed: failed, picked: picked}}, candidate, n) do
    installed = Map.get(installed, n)
    reason = reason(candidate, installed, Map.get(failed, n))
    picked? = is_nil(reason) and is_nil(installed) and n in picked
    %{n: n, candidate: candidate, reason: reason, installed: installed, picked?: picked?}
  end

  # Why a candidate can't be picked, or nil: its download failed, an
  # install of it failed, its SKILL.md lacks a name or a description, or
  # its name is taken. All but the first can be fixed by installing it on
  # its own, through the preview form. One installed here has no reason;
  # the row says it went in.
  defp reason(%{error: message}, _installed, _failed) when is_binary(message), do: message
  defp reason(_candidate, name, _failed) when is_binary(name), do: nil
  defp reason(_candidate, nil, message) when is_binary(message), do: message

  defp reason(%{name: nil}, nil, nil),
    do: "Its SKILL.md has no name. Install it on its own to give it one."

  defp reason(%{description: nil}, nil, nil),
    do: "Its SKILL.md has no description. Install it on its own to add one."

  defp reason(%{name: name}, nil, nil), do: taken(name)[:name]

  # The form error for a name another skill has (the context checks it
  # again when installing).
  defp taken(name) when is_binary(name) and name != "" do
    case Skills.get_by_name(String.trim(name)) do
      nil -> %{}
      _skill -> %{name: "There's already a skill called #{String.trim(name)}."}
    end
  end

  defp taken(_name), do: %{}

  # The preview form over `params`, with `%{field => message}` errors.
  defp install_form(params, errors),
    do: to_form(params, as: :install, errors: Enum.map(errors, fn {k, v} -> {k, {v, []}} end))

  defp clean(params) do
    Map.new(params, fn
      {key, value} when is_binary(value) -> {key, String.replace(value, "\r\n", "\n")}
      pair -> pair
    end)
  end

  ## Getting candidates

  @impl true
  def handle_event("source", %{"source" => source}, socket) when source in ["url", "paste"],
    do: {:noreply, assign(socket, source: source, error: nil)}

  def handle_event("fetch", %{"link" => %{"url" => url} = params}, socket) do
    {:noreply,
     socket
     |> assign(url_form: to_form(params, as: :link), fetching?: true, error: nil)
     |> show([], nil)
     |> start_async(:fetch, fn -> Skills.fetch(String.trim(url)) end)}
  end

  def handle_event("read", %{"paste" => %{"text" => text} = params}, socket) do
    socket = assign(socket, paste_form: to_form(params, as: :paste))

    case Skills.read(text) do
      {:ok, candidate} -> {:noreply, socket |> assign(error: nil) |> show([candidate], nil)}
      {:error, message} -> {:noreply, socket |> assign(error: message) |> show([], nil)}
    end
  end

  ## The preview of one

  def handle_event("tab", %{"tab" => tab}, socket) when tab in ["write", "preview"],
    do: {:noreply, assign(socket, tab: tab)}

  def handle_event("edit", %{"install" => params}, socket) do
    params = clean(params)
    {:noreply, assign(socket, form: install_form(params, taken(params["name"])))}
  end

  def handle_event("install", %{"install" => params}, %{assigns: %{candidates: [c]}} = socket) do
    params = clean(params)

    case Skills.install(params, c) do
      {:ok, skill} ->
        {:noreply,
         socket
         |> put_flash(:info, "Installed #{skill.name}. It's off everywhere; turn it on below.")
         |> push_navigate(to: ~p"/skills/#{skill.name}")}

      {:error, errors} ->
        {:noreply, assign(socket, form: install_form(params, errors))}
    end
  end

  ## Picking from several

  def handle_event("pick", params, socket) do
    {:noreply, socket |> assign(picked: picks(params, socket)) |> rows()}
  end

  # One candidate of the list in the preview form, so the owner can fix
  # what kept it out of the list; `back` returns to the list.
  def handle_event("alone", %{"n" => n}, socket) do
    with {n, ""} <- Integer.parse(n),
         %{error: nil} = candidate <- Enum.at(socket.assigns.candidates, n) do
      back = Map.take(socket.assigns, [:candidates, :notice, :installed, :failed])
      {:noreply, socket |> show([candidate], nil) |> assign(back: back)}
    else
      _other -> {:noreply, socket}
    end
  end

  def handle_event("back", _params, %{assigns: %{back: %{} = back}} = socket) do
    {:noreply,
     socket
     |> show(back.candidates, back.notice)
     |> assign(installed: back.installed, failed: back.failed)
     |> rows()}
  end

  def handle_event("install_selected", params, socket) do
    picked = picks(params, socket)
    candidates = socket.assigns.candidates
    {installed, failed} = install_each(candidates, picked, socket.assigns.installed)

    cond do
      picked == MapSet.new() -> {:noreply, socket}
      failed == %{} -> {:noreply, socket |> put_flash(:info, all_in(installed)) |> to_skills()}
      true -> {:noreply, socket |> some_failed(installed, failed) |> rows()}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # The picks a form sent, as row numbers that can be picked.
  defp picks(params, socket) do
    for value <- List.wrap(params["picked"]),
        {n, ""} <- [Integer.parse(value)],
        n in socket.assigns.pickable,
        into: MapSet.new(),
        do: n
  end

  # Installs each picked candidate under its own name, in list order:
  # the row numbers installed (with what's installed already) and those
  # that failed with why.
  defp install_each(candidates, picked, installed) do
    candidates
    |> Enum.with_index()
    |> Enum.filter(fn {_candidate, n} -> n in picked end)
    |> Enum.reduce({installed, %{}}, fn {candidate, n}, {installed, failed} ->
      case Skills.install(Map.take(candidate, @field_order), candidate) do
        {:ok, skill} -> {Map.put(installed, n, skill.name), failed}
        {:error, errors} -> {installed, Map.put(failed, n, messages(errors))}
      end
    end)
  end

  defp messages(errors) do
    @field_order
    |> Enum.flat_map(&List.wrap(errors[&1]))
    |> Enum.join(" ")
  end

  defp to_skills(socket), do: push_navigate(socket, to: ~p"/skills")

  defp all_in(installed) when map_size(installed) == 1,
    do:
      "Installed #{installed |> Map.values() |> hd()}. It's off everywhere until you turn it on."

  defp all_in(installed),
    do: "Installed #{map_size(installed)} skills. They're off everywhere until you turn them on."

  defp some_failed(socket, installed, failed) do
    count = map_size(installed) - map_size(socket.assigns.installed)
    failed_now = map_size(failed)
    failed = Map.merge(socket.assigns.failed, failed)
    socket = assign(socket, installed: installed, failed: failed, picked: MapSet.new())
    socket = if count > 0, do: put_flash(socket, :info, installed_count(count)), else: socket
    put_flash(socket, :error, "#{skills(failed_now)} couldn't be installed; see why below.")
  end

  defp installed_count(1), do: "Installed 1 skill. It's off everywhere until you turn it on."

  defp installed_count(count),
    do: "Installed #{count} skills. They're off everywhere until you turn them on."

  defp skills(1), do: "1 skill"
  defp skills(count), do: "#{count} skills"

  ## Fetch answers

  @impl true
  def handle_async(:fetch, {:ok, {:ok, candidates, notice}}, socket),
    do: {:noreply, socket |> assign(fetching?: false) |> show(candidates, notice)}

  def handle_async(:fetch, {:ok, {:error, message}}, socket),
    do: {:noreply, assign(socket, fetching?: false, error: message)}

  def handle_async(:fetch, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, fetching?: false, error: "The fetch stopped. Try again.")}

  ## What changed elsewhere

  # A skill made or renamed elsewhere may take a listed name.
  @impl true
  def handle_info({:skills_changed, _id}, socket), do: {:noreply, rows(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  ## Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} shell={@shell} socket={@socket} active={:skills}>
      <div class="h-full overflow-y-auto">
        <div class="blip-clear-y mx-auto w-full max-w-3xl px-4 py-8 sm:px-6">
          <.header>
            <span id="install-heading">Install a skill</span>
            <:subtitle>
              <.link
                id="install-back"
                navigate={~p"/skills"}
                class="inline-flex items-center gap-1 transition hover:text-ink"
              >
                <.icon name="hero-arrow-left-micro" class="size-4" /> Skills
              </.link>
            </:subtitle>
          </.header>
          <p class="mt-4 max-w-2xl text-[14px] leading-relaxed text-ink-soft">
            From a SKILL.md, pasted here or at a link. Only its instructions come in, and it's off everywhere until you turn it on.
          </p>

          <section class="mt-6 rounded-2xl border border-line bg-surface shadow-xs">
            <div class="flex items-center border-b border-line bg-sunken/50 px-4 py-2.5">
              <div
                role="tablist"
                class="flex items-center rounded-full border border-line bg-sunken p-0.5"
              >
                <.source_tab
                  id="install-tab-url"
                  source="url"
                  current={@source}
                  icon="hero-link-micro"
                >
                  From a link
                </.source_tab>
                <.source_tab
                  id="install-tab-paste"
                  source="paste"
                  current={@source}
                  icon="hero-clipboard-document-micro"
                >
                  Paste SKILL.md
                </.source_tab>
              </div>
            </div>

            <.form
              for={@url_form}
              id="install-url-form"
              phx-submit="fetch"
              class={["p-5", @source != "url" && "hidden"]}
            >
              <label for="install-url" class="block text-[13px] font-medium text-ink-soft">
                Link
              </label>
              <div class="mt-1.5 flex flex-col gap-2 sm:flex-row">
                <input
                  type="text"
                  inputmode="url"
                  id="install-url"
                  name={@url_form[:url].name}
                  value={@url_form[:url].value}
                  placeholder="https://github.com/owner/repo/tree/main/skills/pdf-forms"
                  autocomplete="off"
                  spellcheck="false"
                  class={[
                    field_class(),
                    "min-w-0 flex-1 font-mono text-[13px]",
                    @source == "url" && @error && "border-bad/60"
                  ]}
                />
                <.button
                  type="submit"
                  variant="primary"
                  id="install-fetch"
                  disabled={@fetching?}
                  class="h-9 px-4 text-[13px]"
                >
                  <.icon name="hero-arrow-down-tray-micro" class="size-4" /> Fetch
                </.button>
              </div>
              <.install_error :if={@source == "url" && @error} message={@error} />
              <p class="mt-2 text-xs leading-relaxed text-ink-faint">
                A SKILL.md anywhere, or a skill's folder, a folder of skills or a repository on GitHub. Only SKILL.md files are downloaded.
              </p>
              <p
                :if={@fetching?}
                id="install-fetching"
                role="status"
                class="mt-4 flex items-center gap-2 text-[13px] text-ink-soft"
              >
                <.spinner class="size-4 text-accent" /> Fetching...
              </p>
            </.form>

            <.form
              for={@paste_form}
              id="install-paste-form"
              phx-submit="read"
              class={[@source != "paste" && "hidden"]}
            >
              <div class="px-5 pt-5">
                <label for="install-paste" class="sr-only">SKILL.md</label>
                <textarea
                  id="install-paste"
                  name={@paste_form[:text].name}
                  rows="12"
                  spellcheck="false"
                  placeholder="---\nname: pdf-forms\ndescription: Fill in PDF forms. Use when ...\n---\n\n# PDF forms\n..."
                  class={[
                    "block min-h-56 w-full resize-y rounded-lg border border-line bg-sunken/40 px-3 py-2.5 font-mono text-[13px] leading-relaxed text-ink outline-none transition",
                    "placeholder:text-ink-faint focus:border-accent/70 focus:bg-surface focus:ring-3 focus:ring-accent/15",
                    @source == "paste" && @error && "border-bad/60"
                  ]}
                >{Phoenix.HTML.Form.normalize_value("textarea", @paste_form[:text].value)}</textarea>
                <.install_error :if={@source == "paste" && @error} message={@error} />
              </div>
              <div class="mt-4 flex items-center justify-between gap-3 border-t border-line px-5 py-3">
                <p class="text-[12.5px] leading-relaxed text-ink-faint">
                  The whole file, front matter and all.
                </p>
                <.button type="submit" variant="primary" size="sm" id="install-read">
                  Read
                </.button>
              </div>
            </.form>
          </section>

          <.preview
            :if={@form}
            form={@form}
            candidate={hd(@candidates)}
            tab={@tab}
            back={@back && length(@back.candidates)}
          />

          <.candidates
            :if={length(@candidates) > 1}
            count={length(@candidates)}
            notice={@notice}
            streams={@streams}
            picked={MapSet.size(@picked)}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :source, :string, required: true
  attr :current, :string, required: true
  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp source_tab(assigns) do
    ~H"""
    <button
      type="button"
      role="tab"
      id={@id}
      aria-selected={to_string(@source == @current)}
      phx-click="source"
      phx-value-source={@source}
      class={[
        "inline-flex items-center gap-1.5 rounded-full px-3.5 py-1 text-[13px] transition",
        @source == @current && "bg-surface font-medium text-ink shadow-xs",
        @source != @current && "text-ink-faint hover:text-ink"
      ]}
    >
      <.icon name={@icon} class="size-4" />
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :message, :string, required: true

  defp install_error(assigns) do
    ~H"""
    <p id="install-error" role="alert" class="mt-2 flex items-start gap-1.5 text-xs text-bad">
      <.icon name="hero-exclamation-circle-micro" class="mt-px size-4 shrink-0" />
      <span class="leading-relaxed">{@message}</span>
    </p>
    """
  end

  attr :form, :any, required: true
  attr :candidate, :map, required: true
  attr :tab, :string, required: true
  attr :back, :integer, default: nil, doc: "how many skills the list it came from has"

  # One candidate: check it, change it, install it.
  defp preview(assigns) do
    ~H"""
    <section id="install-preview" class="mt-8">
      <button
        :if={@back}
        type="button"
        id="install-back-to-list"
        phx-click="back"
        class="mb-3 inline-flex items-center gap-1 text-[12.5px] text-ink-faint transition hover:text-ink"
      >
        <.icon name="hero-arrow-left-micro" class="size-4" /> Back to the {@back} skills
      </button>
      <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <h2 class="text-[15px] font-semibold tracking-tight text-ink">Check it, then install</h2>
        <.source_line candidate={@candidate} id="install-source" />
      </div>

      <.notes notes={@candidate.notes} id="install-notes" class="mt-4" />

      <.form
        for={@form}
        id="install-form"
        phx-change="edit"
        phx-submit="install"
        class="mt-5 space-y-5"
      >
        <.input
          field={@form[:name]}
          id="install-name"
          label="Name"
          placeholder="pdf-forms"
          hint="Lowercase letters, digits and hyphens. Agents load the skill by this name."
          autocomplete="off"
          spellcheck="false"
          phx-debounce="300"
          class={[field_class(), "font-mono text-[13px]"]}
        />
        <.input
          field={@form[:description]}
          id="install-description"
          type="textarea"
          rows="3"
          label="Description"
          hint="When should an agent use it? Agents see this before they load the skill."
        />

        <div class="space-y-1.5">
          <label for="install-instructions" class="block text-[13px] font-medium text-ink-soft">
            Instructions
          </label>
          <div class="overflow-hidden rounded-2xl border border-line bg-surface shadow-xs transition focus-within:border-accent/60 focus-within:shadow-md focus-within:shadow-accent/10">
            <div class="flex items-center justify-between gap-3 border-b border-line bg-sunken/50 px-3 py-2">
              <div
                role="tablist"
                class="flex items-center rounded-full border border-line bg-sunken p-0.5"
              >
                <.editor_tab id="install-tab-write" tab="write" current={@tab}>Write</.editor_tab>
                <.editor_tab id="install-tab-preview" tab="preview" current={@tab}>
                  Preview
                </.editor_tab>
              </div>
              <span class="flex items-center gap-1.5 text-[11.5px] text-ink-faint">
                <.icon name="hero-document-text-micro" class="size-4" /> Markdown
              </span>
            </div>

            <div class={["px-4 pt-3 pb-3", @tab == "preview" && "hidden"]}>
              <.input
                field={@form[:instructions]}
                id="install-instructions"
                type="textarea"
                rows="18"
                phx-debounce="400"
                spellcheck="false"
                class="block min-h-[22rem] w-full resize-y bg-transparent font-mono text-[13px] leading-relaxed text-ink outline-none placeholder:text-ink-faint"
              />
            </div>

            <div
              :if={@tab == "preview"}
              id="install-instructions-preview"
              class="markdown-body min-h-[22rem] px-5 py-4 text-ink-soft"
            >
              <%= if String.trim(@form[:instructions].value || "") == "" do %>
                <p class="text-[14px] text-ink-faint">Nothing to preview yet.</p>
              <% else %>
                {raw(Markdown.to_html(@form[:instructions].value))}
              <% end %>
            </div>

            <div class="flex items-center justify-between gap-3 border-t border-line px-4 py-3">
              <p class="text-[12.5px] leading-relaxed text-ink-faint">
                It's off everywhere until you turn it on.
              </p>
              <.button
                type="submit"
                variant="primary"
                size="sm"
                id="install-save"
                phx-disable-with="Installing..."
              >
                <.icon name="hero-arrow-down-tray-micro" class="size-4" /> Install
              </.button>
            </div>
          </div>
        </div>
      </.form>
    </section>
    """
  end

  attr :count, :integer, required: true
  attr :notice, :string, default: nil
  attr :streams, :any, required: true
  attr :picked, :integer, required: true

  # Several candidates: pick which to install.
  defp candidates(assigns) do
    ~H"""
    <section id="install-list" class="mt-8">
      <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <h2 class="text-[15px] font-semibold tracking-tight text-ink">
          {@count} skills here
        </h2>
        <p class="text-[12.5px] text-ink-faint">Pick the ones to install.</p>
      </div>

      <p
        :if={@notice}
        id="install-notice"
        role="status"
        class="mt-4 flex items-start gap-2.5 rounded-xl border border-warn/30 bg-warn-soft px-4 py-3 text-[13px] leading-relaxed text-ink"
      >
        <.icon name="hero-information-circle" class="mt-0.5 size-4 shrink-0 text-warn" />
        {@notice}
      </p>

      <.form for={%{}} id="install-pick-form" phx-change="pick" phx-submit="install_selected">
        <input type="hidden" name="picked[]" value="" />
        <div id="install-candidates" phx-update="stream" class="mt-4 space-y-2.5">
          <.candidate :for={{dom_id, row} <- @streams.candidates} id={dom_id} row={row} />
        </div>

        <div class="sticky bottom-0 mt-4 flex items-center justify-between gap-3 rounded-xl border border-line bg-surface/95 px-4 py-3 shadow-sm backdrop-blur">
          <p id="install-picked" class="text-[12.5px] text-ink-faint">
            <%= if @picked == 0 do %>
              Nothing picked yet. They're off everywhere once installed.
            <% else %>
              <span class="font-medium text-ink-soft">{@picked} picked.</span>
              They're off everywhere once installed.
            <% end %>
          </p>
          <.button
            type="submit"
            variant="primary"
            size="sm"
            id="install-selected"
            disabled={@picked == 0}
            phx-disable-with="Installing..."
          >
            <.icon name="hero-arrow-down-tray-micro" class="size-4" /> Install selected
          </.button>
        </div>
      </.form>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :row, :map, required: true

  defp candidate(assigns) do
    assigns = assign(assigns, open?: is_nil(assigns.row.reason) and is_nil(assigns.row.installed))

    ~H"""
    <div
      id={@id}
      class={[
        "flex items-start gap-3 rounded-xl border px-4 py-3.5 shadow-xs transition",
        @open? && @row.picked? && "border-accent/50 bg-accent-soft/40",
        @open? && !@row.picked? && "border-line bg-surface hover:border-line-strong",
        !@open? && "border-line bg-sunken/50"
      ]}
    >
      <input
        type="checkbox"
        id={"#{@id}-pick"}
        name="picked[]"
        value={@row.n}
        checked={@row.picked?}
        disabled={!@open?}
        class="mt-0.5 size-4 shrink-0 cursor-pointer rounded border-line-strong accent-accent disabled:cursor-default disabled:opacity-40"
      />
      <div class="min-w-0 flex-1">
        <label
          for={"#{@id}-pick"}
          class={["block min-w-0", @open? && "cursor-pointer"]}
        >
          <span class="flex min-w-0 flex-wrap items-baseline gap-x-2.5 gap-y-0.5">
            <span class={[
              "min-w-0 truncate font-mono text-[13.5px] font-medium",
              @open? && "text-ink",
              !@open? && "text-ink-soft"
            ]}>
              {@row.candidate.name || "(no name)"}
            </span>
            <span
              :if={@row.candidate.path != ""}
              class="min-w-0 truncate font-mono text-[11.5px] text-ink-faint"
            >
              {@row.candidate.path}
            </span>
          </span>
          <span
            :if={@row.candidate.description}
            class="mt-1 line-clamp-2 block text-[13.5px] leading-relaxed text-ink-soft"
          >
            {@row.candidate.description}
          </span>
        </label>
        <p
          :if={@row.installed}
          id={"#{@id}-installed"}
          class="mt-2 flex items-center gap-1.5 text-[12.5px] text-ok"
        >
          <.icon name="hero-check-circle-micro" class="size-4" /> Installed as
          <.link
            navigate={~p"/skills/#{@row.installed}"}
            class="font-mono underline decoration-ok/40 underline-offset-2 transition hover:decoration-ok"
          >
            {@row.installed}
          </.link>
        </p>
        <div
          :if={@row.reason}
          class="mt-2 flex flex-wrap items-center justify-between gap-x-4 gap-y-2"
        >
          <p
            id={"#{@id}-reason"}
            class="flex min-w-0 items-start gap-1.5 text-[12.5px] leading-relaxed text-bad"
          >
            <.icon name="hero-no-symbol-micro" class="mt-px size-4 shrink-0" />
            <span>{@row.reason}</span>
          </p>
          <.button
            :if={is_nil(@row.candidate.error) and is_binary(@row.candidate.instructions)}
            id={"#{@id}-alone"}
            type="button"
            size="sm"
            variant="ghost"
            phx-click="alone"
            phx-value-n={@row.n}
          >
            <.icon name="hero-pencil-square-micro" class="size-4" /> Install on its own
          </.button>
        </div>
        <ul
          :if={@row.candidate.notes != []}
          id={"#{@id}-notes"}
          class="mt-2 space-y-1 pl-4 text-[12px] leading-relaxed text-ink-faint"
        >
          <li :for={note <- @row.candidate.notes} class="list-disc marker:text-line-strong">
            {note}
          </li>
        </ul>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :candidate, :map, required: true

  # Where a candidate came from: its link without the scheme, or the paste.
  defp source_line(assigns) do
    ~H"""
    <p id={@id} class="min-w-0 text-[12.5px] text-ink-faint">
      <%= if is_binary(@candidate.source_url) do %>
        From
        <a
          href={@candidate.source_url}
          target="_blank"
          rel="noopener noreferrer"
          class="break-all text-ink-soft underline decoration-line-strong underline-offset-2 transition hover:text-ink hover:decoration-ink-faint"
        >{SkillText.place(@candidate.source_url)}</a>
      <% else %>
        From a pasted SKILL.md
      <% end %>
    </p>
    """
  end

  attr :id, :string, required: true
  attr :notes, :list, required: true
  attr :class, :any, default: nil

  # What install leaves out, as the skill will keep it.
  defp notes(assigns) do
    ~H"""
    <section
      :if={@notes != []}
      id={@id}
      class={["rounded-2xl border border-line bg-sunken/60 px-5 py-4", @class]}
    >
      <h3 class="flex items-center gap-2 text-[13px] font-semibold text-ink">
        <.icon name="hero-information-circle" class="size-4 text-ink-faint" /> Install notes
      </h3>
      <ul class="mt-2 space-y-1.5 pl-6 text-[13px] leading-relaxed text-ink-soft">
        <li :for={note <- @notes} class="list-disc marker:text-ink-faint">{note}</li>
      </ul>
      <p class="mt-2.5 pl-6 text-[12px] text-ink-faint">The skill keeps these notes.</p>
    </section>
    """
  end
end

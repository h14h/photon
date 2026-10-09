defmodule PhotonWeb.CoreComponents do
  @moduledoc """
  Photon's UI building blocks, styled with plain Tailwind against the theme
  tokens in `assets/css/app.css` (`canvas`, `surface`, `ink`, `accent`, ...).

  Icons come from [Heroicons](https://heroicons.com): `<.icon name="hero-x-mark" />`.
  """
  use Phoenix.Component

  alias Phoenix.HTML.Form
  alias Phoenix.LiveView.JS

  @doc """
  Renders a flash notice.

      <.flash kind={:info} flash={@flash} />
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  @spec flash(map()) :: Phoenix.LiveView.Rendered.t()
  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="pointer-events-auto w-80 animate-rise cursor-pointer sm:w-96"
      {@rest}
    >
      <div class={[
        "flex items-start gap-3 rounded-xl border px-4 py-3 text-sm shadow-lg shadow-black/5 backdrop-blur",
        @kind == :info && "border-line bg-surface/95 text-ink",
        @kind == :error && "border-bad/30 bg-bad-soft/95 text-ink"
      ]}>
        <.icon :if={@kind == :info} name="hero-check-circle" class="mt-0.5 size-5 shrink-0 text-ok" />
        <.icon
          :if={@kind == :error}
          name="hero-exclamation-circle"
          class="mt-0.5 size-5 shrink-0 text-bad"
        />
        <div class="min-w-0 flex-1">
          <p :if={@title} class="font-semibold">{@title}</p>
          <p class="leading-snug">{msg}</p>
        </div>
        <.icon name="hero-x-mark" class="size-4 shrink-0 text-ink-faint" />
      </div>
    </div>
    """
  end

  @size_classes %{"sm" => "h-8 px-2.5 text-[13px]", "md" => "h-9 px-3.5 text-sm"}

  @variant_classes %{
    "primary" =>
      "bg-accent text-accent-ink shadow-sm shadow-accent/30 hover:bg-accent-strong hover:shadow-md hover:shadow-accent/30",
    "secondary" =>
      "border border-line bg-surface text-ink shadow-xs hover:border-line-strong hover:bg-sunken",
    "ghost" => "text-ink-soft hover:bg-sunken hover:text-ink",
    "danger" => "border border-bad/30 bg-surface text-bad hover:bg-bad-soft"
  }

  @doc """
  Renders a button, or a link styled as one when given `href`, `navigate` or
  `patch`.

      <.button variant="primary">Save</.button>
      <.button navigate={~p"/"} variant="ghost">Back</.button>
  """
  attr :rest, :global,
    include: ~w(href navigate patch method download name value disabled type form target rel)

  attr :class, :any, default: nil
  attr :variant, :string, default: "secondary", values: ~w(primary secondary ghost danger)
  attr :size, :string, default: "md", values: ~w(sm md)
  slot :inner_block, required: true

  @spec button(map()) :: Phoenix.LiveView.Rendered.t()
  def button(%{rest: rest} = assigns) do
    assigns =
      assign(assigns, :classes, [
        "inline-flex select-none items-center justify-center gap-1.5 rounded-lg font-medium whitespace-nowrap transition duration-150",
        "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent disabled:pointer-events-none disabled:opacity-45",
        "active:scale-[0.98] phx-submit-loading:opacity-70",
        @size_classes[assigns.size],
        @variant_classes[assigns.variant],
        assigns.class
      ])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@classes} {@rest}>{render_slot(@inner_block)}</.link>
      """
    else
      ~H"""
      <button class={@classes} {@rest}>{render_slot(@inner_block)}</button>
      """
    end
  end

  @doc """
  Renders an input with a label and error messages, from a form field:

      <.input field={@form[:model]} label="Model" />

  Types: `text` (and other HTML input types), `textarea`, `select`,
  `checkbox`, `hidden`.
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :hint, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  @spec input(map()) :: Phoenix.LiveView.Rendered.t()
  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="py-1">
      <label class="inline-flex cursor-pointer items-center gap-2.5 text-sm text-ink">
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class={@class || "size-4 rounded border-line-strong accent-accent"}
          {@rest}
        />{@label}
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="space-y-1.5">
      <label :if={@label} for={@id} class="block text-[13px] font-medium text-ink-soft">{@label}</label>
      <select
        id={@id}
        name={@name}
        class={[@class || field_class(), @errors != [] && (@error_class || "border-bad/60")]}
        multiple={@multiple}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <p :if={@hint} class="text-xs text-ink-faint">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="space-y-1.5">
      <label :if={@label} for={@id} class="block text-[13px] font-medium text-ink-soft">{@label}</label>
      <textarea
        id={@id}
        name={@name}
        class={[
          @class || [field_class(), "h-auto min-h-24 py-2 leading-relaxed"],
          @errors != [] && (@error_class || "border-bad/60")
        ]}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <p :if={@hint} class="text-xs text-ink-faint">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class="space-y-1.5">
      <label :if={@label} for={@id} class="block text-[13px] font-medium text-ink-soft">{@label}</label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[@class || field_class(), @errors != [] && (@error_class || "border-bad/60")]}
        {@rest}
      />
      <p :if={@hint} class="text-xs text-ink-faint">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  @doc "The shared look of text fields."
  @spec field_class() :: String.t()
  def field_class do
    "block h-9 w-full rounded-lg border border-line bg-surface px-3 text-sm text-ink shadow-xs outline-none transition " <>
      "placeholder:text-ink-faint focus:border-accent/70 focus:ring-3 focus:ring-accent/15"
  end

  defp error(assigns) do
    ~H"""
    <p class="flex items-center gap-1.5 text-xs text-bad">
      <.icon name="hero-exclamation-circle-micro" class="size-4" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc "A page header with an optional subtitle and actions."
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  @spec header(map()) :: Phoenix.LiveView.Rendered.t()
  def header(assigns) do
    ~H"""
    <header class="flex flex-wrap items-end justify-between gap-4">
      <div>
        <h1 class="text-xl font-semibold tracking-tight text-ink">{render_slot(@inner_block)}</h1>
        <p :if={@subtitle != []} class="mt-1 text-sm text-ink-soft">{render_slot(@subtitle)}</p>
      </div>
      <div :if={@actions != []} class="flex items-center gap-2">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  An on/off switch: a button with `role="switch"` and its label, for a
  setting that applies the moment it is clicked (no form to save). The
  page handles the click (`phx-click`, `phx-value-*` in `rest`) and
  renders the stored state back as `on`.

      <.switch id="skill-blip" on={@on?} label="Blip" phx-click="blip" phx-value-on="false" />
  """
  attr :id, :string, required: true
  attr :on, :boolean, required: true
  attr :label, :string, required: true
  attr :class, :any, default: nil
  attr :rest, :global

  @spec switch(map()) :: Phoenix.LiveView.Rendered.t()
  def switch(assigns) do
    ~H"""
    <button
      type="button"
      role="switch"
      id={@id}
      aria-checked={to_string(@on)}
      class={[
        "group inline-flex cursor-pointer select-none items-center gap-2 rounded-full text-[13px] transition",
        "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent",
        "phx-click-loading:opacity-60",
        @class
      ]}
      {@rest}
    >
      <span class={[
        "relative inline-flex h-5 w-9 shrink-0 items-center rounded-full border transition duration-200",
        @on && "border-accent bg-accent shadow-sm shadow-accent/30",
        !@on && "border-line-strong bg-sunken group-hover:border-ink-faint/60"
      ]}>
        <span class={[
          "absolute left-0.5 size-3.5 rounded-full shadow-xs transition duration-200 ease-out",
          @on && "translate-x-4 bg-accent-ink",
          !@on && "bg-surface ring-1 ring-line-strong"
        ]} />
      </span>
      <span class={["truncate", @on && "text-ink", !@on && "text-ink-soft group-hover:text-ink"]}>
        {@label}
      </span>
    </button>
    """
  end

  @doc "A small status dot: `ok`, `busy` (breathing amber), `accent` (still), `warn`, `bad` or `off`."
  attr :status, :atom, default: :off
  attr :class, :any, default: nil

  @spec dot(map()) :: Phoenix.LiveView.Rendered.t()
  def dot(assigns) do
    ~H"""
    <span class={[
      "inline-block size-2 shrink-0 rounded-full",
      @status == :ok && "bg-ok shadow-[0_0_0_3px] shadow-ok/15",
      @status == :busy && "animate-breathe bg-accent shadow-[0_0_0_3px] shadow-accent/20",
      @status == :accent && "bg-accent",
      @status == :warn && "bg-warn",
      @status == :bad && "bg-bad",
      @status == :off && "border border-ink-faint/60",
      @class
    ]} />
    """
  end

  @doc """
  A thread's state as a small mark: the breathing dot while it runs, a
  speech bubble while it waits on Blip (so it doesn't look like work), an
  amber dot with a halo when it waits on the owner, a red dot when it
  failed, a still accent dot when it finished unread, and nothing when it is
  quiet or idle. Its tooltip and label are the state's words
  (`PhotonWeb.ThreadText.state/1`).
  """
  attr :state, :atom, required: true, doc: "a `Photon.Threads.State.t()`"
  attr :id, :string, default: nil
  attr :class, :any, default: nil

  @spec state_mark(map()) :: Phoenix.LiveView.Rendered.t()
  def state_mark(%{state: state} = assigns) when state in [:quiet, :idle] do
    ~H""
  end

  def state_mark(assigns) do
    assigns = assign(assigns, :words, PhotonWeb.ThreadText.state(assigns.state))

    ~H"""
    <span
      id={@id}
      role="img"
      aria-label={@words}
      title={@words}
      data-mark={@state}
      class={["inline-flex shrink-0 items-center justify-center", @class]}
    >
      <.icon
        :if={@state == :asking}
        name="hero-chat-bubble-oval-left-ellipsis-micro"
        class="size-3.5 text-accent-strong"
      />
      <.dot :if={@state == :running} status={:busy} class="size-1.5" />
      <.dot
        :if={@state == :waiting}
        status={:warn}
        class="size-1.5 shadow-[0_0_0_3px] shadow-warn/25"
      />
      <.dot :if={@state == :failed} status={:bad} class="size-1.5" />
      <.dot :if={@state == :unread} status={:accent} class="size-1.5" />
    </span>
    """
  end

  @doc """
  The "Jump to latest" button of a thread that follows new content only
  while it's pinned to the bottom (the `PinToBottom` hook). Put it last
  inside the scrolling element; it shows only while the thread is unpinned.
  """
  @spec jump_to_latest(map()) :: Phoenix.LiveView.Rendered.t()
  def jump_to_latest(assigns) do
    ~H"""
    <div class="pin-jump-row">
      <button type="button" data-pin-jump class="pin-jump">
        <.icon name="hero-arrow-down-micro" class="size-3.5" /> Jump to latest
      </button>
    </div>
    """
  end

  @doc "A small spinner."
  attr :class, :any, default: "size-4"

  @spec spinner(map()) :: Phoenix.LiveView.Rendered.t()
  def spinner(assigns) do
    ~H"""
    <svg
      class={["animate-spin text-current", @class]}
      viewBox="0 0 24 24"
      fill="none"
      aria-hidden="true"
    >
      <circle cx="12" cy="12" r="9" stroke="currentColor" stroke-opacity="0.2" stroke-width="3" />
      <path d="M21 12a9 9 0 0 0-9-9" stroke="currentColor" stroke-width="3" stroke-linecap="round" />
    </svg>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  @spec icon(map()) :: Phoenix.LiveView.Rendered.t()
  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  @doc "Shows the element `selector` names, with a short fade and rise."
  @spec show(JS.t(), String.t()) :: JS.t()
  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-out duration-200", "opacity-0 translate-y-2",
         "opacity-100 translate-y-0"}
    )
  end

  @doc "Hides the element `selector` names, with a short fade and drop."
  @spec hide(JS.t(), String.t()) :: JS.t()
  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 150,
      transition:
        {"transition-all ease-in duration-150", "opacity-100 translate-y-0",
         "opacity-0 translate-y-2"}
    )
  end

  @doc "Fills in an error message's interpolations."
  @spec translate_error({String.t(), keyword()}) :: String.t()
  def translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  @doc "Translates the errors for a field from a keyword list of errors."
  @spec translate_errors(keyword(), atom()) :: [String.t()]
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end

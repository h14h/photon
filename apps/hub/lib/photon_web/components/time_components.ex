defmodule PhotonWeb.TimeComponents do
  @moduledoc """
  Times in the owner's time zone.

  The hub keeps times in UTC and has no time zone database (Settings' time
  zone is free text for Blip's prompt), but the browser knows the owner's
  zone. So the server renders UTC and a colocated hook converts it:

    * `local_time/1` is a `<time>` with the ISO time in `datetime` and a
      UTC fallback ("Oct 8, 14:00 UTC") as its text, which the
      `.LocalTime` hook rewrites with `Intl.DateTimeFormat` when it mounts
      and after every patch
    * `local_datetime_input/1` is a `datetime-local` input the owner edits
      in local time and the hidden field the server reads, in UTC. The
      `.LocalDateTime` hook fills the input from `data-utc` and writes
      every edit back into the hidden field as ISO UTC, then dispatches an
      `input` event so the form's `phx-change` sees it. Tests set the
      hidden field directly with `render_change/2`.

  Imported in every LiveView through `PhotonWeb`'s `html_helpers`.
  """

  use Phoenix.Component

  import PhotonWeb.CoreComponents, only: [field_class: 0, icon: 1, translate_error: 1]

  @doc """
  A time in the owner's time zone. The text is the UTC fallback until the
  browser's hook replaces it; its tooltip gives the full date and zone.
  """
  attr :id, :string, required: true, doc: "unique on the page; the hook needs it"
  attr :at, DateTime, required: true, doc: "a UTC time"
  attr :class, :any, default: nil

  @spec local_time(map()) :: Phoenix.LiveView.Rendered.t()
  def local_time(assigns) do
    assigns = assign(assigns, :at, DateTime.truncate(assigns.at, :second))

    ~H"""
    <%!-- The hook comes first, so nothing follows the time: punctuation after it stays put. --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalTime">
      // "Oct 8, 2:00 PM" in the browser's zone and locale, with the year
      // when it isn't this year. The server's text is the UTC fallback, and
      // a patch puts it back, so this runs after every update too.
      export default {
        mounted() { this.render() },
        updated() { this.render() },
        render() {
          const at = new Date(this.el.getAttribute("datetime"))
          if (isNaN(at)) return
          const short = {month: "short", day: "numeric", hour: "numeric", minute: "2-digit"}
          if (at.getFullYear() !== new Date().getFullYear()) short.year = "numeric"
          this.el.textContent = new Intl.DateTimeFormat(undefined, short).format(at)
          this.el.title = new Intl.DateTimeFormat(undefined, {
            weekday: "long", year: "numeric", month: "long", day: "numeric",
            hour: "numeric", minute: "2-digit", timeZoneName: "short"
          }).format(at)
        }
      }
    </script>
    <time
      id={@id}
      datetime={DateTime.to_iso8601(@at)}
      phx-hook=".LocalTime"
      data-format="datetime"
      class={["tabular-nums", @class]}
    >{utc_text(@at)}</time>
    """
  end

  @doc ~S"""
  A date and time field the owner fills in local time, for a form field
  that holds UTC. Renders the visible `datetime-local` input
  (`#<id>-local`) and the hidden field (`#<id>`) named after `field`,
  whose value is ISO 8601 in UTC (`"2026-10-08T14:00:00.000Z"` from the
  browser). The field's errors show under it, as `input/1` shows them.
  """
  attr :id, :string, required: true, doc: "the hidden field's; the visible input adds `-local`"
  attr :field, Phoenix.HTML.FormField, required: true, doc: "the field that holds the UTC time"
  attr :label, :string, default: nil
  attr :hint, :string, default: nil

  @spec local_datetime_input(map()) :: Phoenix.LiveView.Rendered.t()
  def local_datetime_input(%{field: field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns =
      assign(assigns,
        name: field.name,
        value: field.value,
        errors: Enum.map(errors, &translate_error/1)
      )

    ~H"""
    <div class="space-y-1.5">
      <label :if={@label} for={"#{@id}-local"} class="block text-[13px] font-medium text-ink-soft">
        {@label}
      </label>
      <input
        type="datetime-local"
        id={"#{@id}-local"}
        phx-hook=".LocalDateTime"
        phx-update="ignore"
        data-utc={@value}
        data-target={@id}
        data-invalid={to_string(@errors != [])}
        class={[field_class(), "w-auto max-w-full data-[invalid=true]:border-bad/60"]}
      />
      <input type="hidden" id={@id} name={@name} value={@value} />
      <p class="text-xs text-ink-faint">
        {@hint}
        <span id={"#{@id}-zone"} phx-update="ignore"></span>
      </p>
      <p :for={msg <- @errors} class="flex items-center gap-1.5 text-xs text-bad">
        <.icon name="hero-exclamation-circle-micro" class="size-4" />
        {msg}
      </p>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalDateTime">
      // The visible input is in the browser's time zone; the hidden field
      // the form sends is UTC. On mount (and when the server's UTC value
      // changes, say on reloading a saved schedule) the input shows the
      // UTC time locally; on every edit the hidden field gets it back as
      // ISO UTC, and an input event from there lets phx-change see it. The
      // visible input's own events stop here: it has no name, and the
      // form would otherwise push a change for each of them as well.
      export default {
        mounted() {
          this.hidden = document.getElementById(this.el.dataset.target)
          const zone = document.getElementById(`${this.el.dataset.target}-zone`)
          const name = Intl.DateTimeFormat().resolvedOptions().timeZone
          if (zone && name) zone.textContent = `Your time zone: ${name.replaceAll("_", " ")}.`
          this.show()
          this.onEdit = e => {
            e.stopPropagation()
            const at = this.el.value ? new Date(this.el.value) : null
            const utc = at && !isNaN(at) ? at.toISOString() : ""
            if (utc === this.hidden.value) return
            this.utc = utc
            this.hidden.value = utc
            this.hidden.dispatchEvent(new Event("input", {bubbles: true}))
          }
          this.el.addEventListener("input", this.onEdit)
          this.el.addEventListener("change", this.onEdit)
        },
        updated() {
          if (this.instant(this.el.dataset.utc) !== this.instant(this.utc)) this.show()
        },
        show() {
          this.utc = this.el.dataset.utc || ""
          const at = new Date(this.utc)
          if (!this.utc || isNaN(at)) { this.el.value = ""; return }
          const pad = n => String(n).padStart(2, "0")
          this.el.value = `${at.getFullYear()}-${pad(at.getMonth() + 1)}-${pad(at.getDate())}` +
            `T${pad(at.getHours())}:${pad(at.getMinutes())}`
        },
        instant(utc) {
          const ms = Date.parse(utc || "")
          return isNaN(ms) ? null : ms
        }
      }
    </script>
    """
  end

  # The text before the browser's hook runs: the time in UTC, said so.
  defp utc_text(at), do: Calendar.strftime(at, "%b %-d, %H:%M UTC")
end

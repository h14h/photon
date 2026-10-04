defmodule PhotonWeb.Blip do
  @moduledoc """
  Blip, the assistant, drawn as an inline SVG. The CSS in `assets/vendor/blip`
  poses and animates it from `data-state`: idle, thinking, working, done,
  error, or observed (someone is looking at it).

  The markup is the Blip brand kit's `blip.svg` (commit 617c74b). Its
  gradient and clip IDs are prefixed with the component's `id`. Browsers
  resolve an ID to the first match on the page, so with shared IDs every
  Blip would take its colours from the first one, whatever its own state.
  """

  use Phoenix.Component

  @states ~w(idle thinking working done error observed)a

  @typedoc "What Blip shows."
  @type state :: :idle | :thinking | :working | :done | :error | :observed

  attr :id, :string, required: true, doc: "unique on the page; prefixes the SVG's own IDs"
  attr :state, :atom, default: :idle, values: @states
  attr :size, :integer, default: 28
  attr :still, :boolean, default: false, doc: "holds the pose without animating"

  attr :contained, :boolean,
    default: true,
    doc: "keeps the working wave inside Blip's box; off where there's room for it to run"

  attr :interactive, :boolean, default: false, doc: "looks back on hover and wobbles on click"
  attr :label, :string, default: nil, doc: "for screen readers; without one Blip is decoration"
  attr :class, :any, default: nil

  @spec blip(map()) :: Phoenix.LiveView.Rendered.t()
  def blip(%{interactive: true} = assigns) do
    ~H"""
    <span id={"#{@id}-hook"} phx-hook=".Blip" class={["inline-grid", @class]}>
      <.svg
        id={@id}
        state={@state}
        size={@size}
        still={@still}
        contained={@contained}
        label={@label}
        class="blip--interactive"
      />
    </span>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Blip">
      // Hover: Blip notices it's being looked at, and goes back to what it was
      // doing (the state the server last set) when you look away. Click: one
      // jelly wobble.
      export default {
        mounted() {
          this.svg = this.el.querySelector("svg")
          this.rest = this.svg.dataset.state
          this.looking = false
          this.watch = new MutationObserver(() => {
            const state = this.svg.dataset.state
            if (state === "observed") return
            this.rest = state
            if (this.looking) this.svg.dataset.state = "observed"
          })
          this.watch.observe(this.svg, {attributes: true, attributeFilter: ["data-state"]})
          this.el.addEventListener("pointerenter", () => {
            this.looking = true
            this.svg.dataset.state = "observed"
          })
          this.el.addEventListener("pointerleave", () => {
            this.looking = false
            this.svg.dataset.state = this.rest
          })
          this.el.addEventListener("click", () => {
            this.svg.classList.remove("is-poked")
            void this.svg.getBoundingClientRect()
            this.svg.classList.add("is-poked")
          })
          this.svg.addEventListener("animationend", e => {
            if (e.animationName === "blip-jelly") this.svg.classList.remove("is-poked")
          })
        },
        destroyed() { this.watch.disconnect() }
      }
    </script>
    """
  end

  def blip(assigns), do: svg(assigns)

  attr :id, :string, required: true
  attr :state, :atom, required: true
  attr :size, :integer, required: true
  attr :still, :boolean, required: true
  attr :contained, :boolean, required: true
  attr :label, :string, required: true
  attr :class, :any, required: true

  defp svg(assigns) do
    ~H"""
    <svg
      id={@id}
      class={["blip shrink-0", @still && "blip--still", @contained && "blip--contained", @class]}
      data-state={@state}
      viewBox="0 0 100 100"
      width={@size}
      height={@size}
      xmlns="http://www.w3.org/2000/svg"
      role={@label && "img"}
      aria-label={@label}
      aria-hidden={is_nil(@label) && "true"}
    >
      <defs>
        <linearGradient
          id={"#{@id}-body"}
          gradientUnits="userSpaceOnUse"
          x1="26"
          y1="50"
          x2="74"
          y2="50"
        >
          <stop
            class="blip-stop-a"
            offset="0"
            stop-color="var(--blip-amber, oklch(70% 0.165 58))"
          />
          <stop
            class="blip-stop-b"
            offset="1"
            stop-color="var(--blip-amber-deep, oklch(58% 0.17 45))"
          />
        </linearGradient>
        <radialGradient id={"#{@id}-halo-g"}>
          <stop
            class="blip-stop-halo"
            offset="0.45"
            stop-color="var(--blip-amber, oklch(70% 0.165 58))"
            stop-opacity="0.38"
          />
          <stop
            class="blip-stop-halo"
            offset="1"
            stop-color="var(--blip-amber, oklch(70% 0.165 58))"
            stop-opacity="0"
          />
        </radialGradient>
        <clipPath id={"#{@id}-clip-l"}><circle cx="42" cy="49.5" r="6.6" /></clipPath>
        <clipPath id={"#{@id}-clip-r"}><circle cx="58" cy="49.5" r="6.6" /></clipPath>
      </defs>
      <path
        class="blip-wave"
        d="M-70 50 C -60 30, -50 30, -40 50 S -20 70, -10 50 S 10 30, 20 50 S 40 70, 50 50 S 70 30, 80 50 S 100 70, 110 50 S 130 30, 140 50 S 160 70, 170 50"
        fill="none"
        stroke={"url(##{@id}-body)"}
        stroke-width="9"
        stroke-linecap="round"
      />
      <circle class="blip-ring" cx="50" cy="50" r="30" fill="none" stroke-width="2" />
      <circle class="blip-halo" cx="50" cy="50" r="46" fill={"url(##{@id}-halo-g)"} />
      <g class="blip-self">
        <g class="blip-body-g">
          <circle class="blip-core" cx="50" cy="50" r="22" fill={"url(##{@id}-body)"} />
          <g class="blip-cheeks">
            <ellipse cx="35.5" cy="59" rx="4" ry="2.6" /><ellipse cx="64.5" cy="59" rx="4" ry="2.6" />
          </g>
        </g>
        <g class="blip-eyes">
          <.eye id={@id} side="l" cx={42} />
          <.eye id={@id} side="r" cx={58} />
        </g>
        <g class="blip-happy" fill="none" stroke-width="3" stroke-linecap="round">
          <path class="blip-happy-l" d="M36.5 51 q5.5 -6.5 11 0" />
          <path class="blip-happy-r" d="M52.5 51 q5.5 -6.5 11 0" />
        </g>
      </g>
      <circle class="blip-mote" cx="50" cy="50" r="2.6" />
    </svg>
    """
  end

  attr :id, :string, required: true
  attr :side, :string, required: true, values: ~w(l r)
  attr :cx, :integer, required: true

  defp eye(assigns) do
    ~H"""
    <g class={"blip-eye blip-eye-#{@side}"}>
      <circle class="blip-sclera" cx={@cx} cy="49.5" r="6" />
      <g class="blip-pupil-g"><circle class="blip-pupil" cx={@cx + 0.4} cy="50.3" r="3.8" /></g>
      <g clip-path={"url(##{@id}-clip-#{@side})"}>
        <circle
          class={"blip-lid blip-lid-#{@side}"}
          cx={@cx}
          cy="35.3"
          r="8"
          fill={"url(##{@id}-body)"}
        />
        <circle
          class={"blip-lower blip-lower-#{@side}"}
          cx={@cx}
          cy="64.7"
          r="9"
          fill={"url(##{@id}-body)"}
        />
      </g>
    </g>
    """
  end
end

defmodule PhotonWeb.SkillComponents do
  @moduledoc """
  What the skill pages share: `install_notes/1`, what install leaves out
  of a skill, on the install page's preview (`PhotonWeb.SkillInstallLive`)
  and on the skill's own page (`PhotonWeb.SkillLive`).
  """

  use Phoenix.Component

  import PhotonWeb.CoreComponents, only: [icon: 1]

  @doc """
  A skill's install notes, a list item each, under an "Install notes"
  heading; nothing when there are none. The footer slot goes under the
  list.
  """
  attr :id, :string, required: true
  attr :notes, :list, required: true
  attr :heading, :string, values: ~w(h2 h3), required: true, doc: "the heading's tag"
  attr :class, :any, default: nil
  slot :footer

  @spec install_notes(map()) :: Phoenix.LiveView.Rendered.t()
  def install_notes(assigns) do
    ~H"""
    <section
      :if={@notes != []}
      id={@id}
      class={[@class, "rounded-2xl border border-line bg-sunken/60 px-5 py-4"]}
    >
      <.dynamic_tag
        tag_name={@heading}
        class="flex items-center gap-2 text-[13px] font-semibold text-ink"
      >
        <.icon name="hero-information-circle" class="size-4 text-ink-faint" /> Install notes
      </.dynamic_tag>
      <ul class="mt-2 space-y-1.5 pl-6 text-[13px] leading-relaxed text-ink-soft">
        <li :for={note <- @notes} class="list-disc marker:text-ink-faint">{note}</li>
      </ul>
      {render_slot(@footer)}
    </section>
    """
  end
end

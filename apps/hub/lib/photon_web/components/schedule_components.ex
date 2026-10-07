defmodule PhotonWeb.ScheduleComponents do
  @moduledoc """
  The lines a schedule shows wherever it is listed: the home page (Blip's
  schedules, `PhotonWeb.HomeLive`) and a project's page
  (`PhotonWeb.ProjectLive`).

    * `schedule_when/1`: when it runs next, or that it is done or stopped
      ("Every day · next <local time>", "Once · <local time>", "Done",
      "Stopped after an error: ...", the last in the error colour)
    * `last_run/1`: what its last firing did ("Last ran <local time>:
      started "Check the backups"", with the thread linked, or a skip
      because scheduled work is off, linked to Settings)

  The words come from `PhotonWeb.ScheduleText` and the times from
  `PhotonWeb.TimeComponents.local_time/1`, so they read in the owner's
  time zone. Each line's DOM ID is the row's plus `-when` or `-last`.
  """

  use PhotonWeb, :html

  alias PhotonWeb.ScheduleText

  @doc """
  When a schedule runs next (`PhotonWeb.ScheduleText.state/2`): the
  words, then the next time while it waits; a stopped schedule's words are
  in the error colour. Its ID is `<id>-when`, and the time's `<id>-next`.
  """
  attr :id, :string, required: true, doc: "the row's DOM ID"
  attr :item, :map, required: true, doc: "a schedule from `Photon.Schedules.list/1`"

  attr :whose, :atom,
    default: :project,
    values: [:project, :blip],
    doc: "whose schedule: `:blip` says how to fix a stopped one without a form"

  @spec schedule_when(map()) :: Phoenix.LiveView.Rendered.t()
  def schedule_when(%{item: item} = assigns) do
    {tone, words} = ScheduleText.state(item.state, item.schedule.every_minutes, assigns.whose)
    assigns = assign(assigns, tone: tone, words: words)

    ~H"""
    <p
      id={"#{@id}-when"}
      data-state={@tone}
      class={["mt-0.5 text-[12px]", if(@tone == :stopped, do: "text-bad", else: "text-ink-faint")]}
    >
      {@words}
      <.local_time :if={@tone == :next && @item.next_at} id={"#{@id}-next"} at={@item.next_at} />
    </p>
    """
  end

  @doc """
  What the schedule's last firing did, once it has fired: "Last ran <local
  time>: <`PhotonWeb.ScheduleText.outcome/1`>". After "started", the
  thread it started follows, linked (`<id>-last-thread`) when the page
  passes its title and path; a skip because scheduled work is off links
  to Settings (`<id>-last-settings`). A failed task isn't a run: the when
  line says that (`schedule_when/1`), so nothing shows until the next
  firing.
  """
  attr :id, :string, required: true, doc: "the row's DOM ID"
  attr :schedule, Photon.Schedules.Schedule, required: true
  attr :thread_title, :string, default: nil, doc: "the title of the thread it last started"
  attr :thread_path, :string, default: nil
  attr :class, :any, default: nil

  @spec last_run(map()) :: Phoenix.LiveView.Rendered.t()
  def last_run(%{schedule: schedule} = assigns) do
    {words, link} = ScheduleText.last(schedule.last_outcome)
    shown? = schedule.last_run_at != nil and schedule.last_outcome not in [nil, "failed"]
    thread? = link == :thread and assigns.thread_title != nil and assigns.thread_path != nil
    assigns = assign(assigns, words: words, link: link, shown?: shown?, thread?: thread?)

    ~H"""
    <p :if={@shown?} id={"#{@id}-last"} class={["text-[12px] text-ink-faint", @class]}>
      <span phx-no-format>Last ran <.local_time id={"#{@id}-last-at"} at={@schedule.last_run_at} />: </span><.link
        :if={@link == :settings}
        id={"#{@id}-last-settings"}
        navigate={~p"/settings"}
        class="text-warn underline decoration-warn/40 underline-offset-2 transition hover:decoration-warn"
      >{@words}</.link><span :if={@link != :settings} phx-no-format>{@words}{if(@thread?, do: " ")}<.link
          :if={@thread?}
          id={"#{@id}-last-thread"}
          navigate={@thread_path}
          class="text-ink-soft underline decoration-line-strong underline-offset-2 transition hover:text-ink hover:decoration-ink-faint"
        >"{@thread_title}"</.link></span>
    </p>
    """
  end
end

defmodule PhotonWeb.ActivityLive do
  @moduledoc """
  The activity page at `/activity` (section 10.7 of
  `docs/plans/step-4-blip-as-coordinator.md`): everything Blip did, and
  who asked. For now it has its header and the empty state, `#no-activity`;
  the list of `Photon.Activity`'s rows, its filter and `Show older` arrive
  with the rest of that section. Everything the shell passes on is
  ignored.
  """

  use PhotonWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: "Activity")}

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} shell={@shell} socket={@socket} active={:activity}>
      <div class="h-full overflow-y-auto">
        <div class="blip-clear-y mx-auto w-full max-w-3xl px-4 py-8 sm:px-6">
          <.header>
            <span id="activity-heading">Activity</span>
            <:subtitle>Everything Blip did, and who asked.</:subtitle>
          </.header>

          <div
            id="no-activity"
            class="mt-8 rounded-2xl border border-dashed border-line-strong px-6 py-10 text-center"
          >
            <span class="mx-auto flex size-10 items-center justify-center rounded-full bg-accent-soft text-accent-strong">
              <.icon name="hero-queue-list" class="size-5" />
            </span>
            <p class="mx-auto mt-3 max-w-sm text-[14px] leading-relaxed text-ink-soft">
              Nothing yet. When Blip runs a command, starts a thread or answers one, it shows here.
            </p>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end

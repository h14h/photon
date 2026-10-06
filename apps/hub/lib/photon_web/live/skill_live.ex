defmodule PhotonWeb.SkillLive do
  @moduledoc """
  One skill (section 6.4 of `docs/plans/step-3-skills-and-schedules.md`):
  `:new` at `/skills/new` writes one, `:edit` at `/skills/:name` shows
  and edits one.

  For now the page is its header: the skill's name and description, or
  "Write a skill", with the way back to the Skills page. The editor and
  the switches that turn it on come with the page's own task.

  An unknown skill goes back to `/skills` with a flash. Everything the
  shell passes on is ignored.
  """

  use PhotonWeb, :live_view

  alias Photon.Skills
  alias Photon.Skills.Skill

  @impl true
  def mount(params, _session, socket) do
    case skill(params, socket.assigns.live_action) do
      {:ok, skill} ->
        {:ok, assign(socket, skill: skill, page_title: title(skill))}

      {:error, message} ->
        {:ok, socket |> put_flash(:error, message) |> push_navigate(to: ~p"/skills")}
    end
  end

  defp skill(_params, :new), do: {:ok, nil}

  defp skill(%{"name" => name}, :edit) do
    case Skills.get_by_name(name) do
      %Skill{} = skill -> {:ok, skill}
      nil -> {:error, "There's no skill called #{name}."}
    end
  end

  defp title(nil), do: "Write a skill"
  defp title(%Skill{name: name}), do: name

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} shell={@shell} socket={@socket} active={:skills}>
      <div class="h-full overflow-y-auto">
        <div class="blip-clear-y mx-auto w-full max-w-4xl px-4 py-8 sm:px-6">
          <.header>
            <span id="skill-heading" class={@skill && "font-mono text-[19px]"}>
              {title(@skill)}
            </span>
            <:subtitle>
              <.link
                id="skill-back"
                navigate={~p"/skills"}
                class="inline-flex items-center gap-1 transition hover:text-ink"
              >
                <.icon name="hero-arrow-left-micro" class="size-4" /> Skills
              </.link>
            </:subtitle>
          </.header>
          <p
            :if={@skill}
            id="skill-summary"
            class="mt-4 max-w-2xl text-[14px] leading-relaxed text-ink-soft"
          >
            {@skill.description}
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end

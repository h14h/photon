defmodule Photon.Assistant.Tools.CancelSchedule do
  @moduledoc """
  Blip's `cancel_schedule` tool: deletes any schedule by its `sc_` ID,
  Blip's own or a project's, inside the commit that records the result
  (`Photon.Schedules.delete_tx/3` with `:any`). Threads a project
  schedule started stay.

  A run that carries a thread's question, and that the owner hasn't
  written into, can't cancel a schedule (`Photon.Assistant.may_act_tx/3`).
  """
  @behaviour Photon.Durable.Tool

  alias Photon.{Assistant, Projects, Schedules}

  @impl true
  def name, do: "cancel_schedule"

  @impl true
  def description,
    do: "Cancel a scheduled prompt by its ID, yours or a project's (list_schedules shows them)."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{"schedule_id" => %{"type" => "string"}},
      "required" => ["schedule_id"]
    }
  end

  @impl true
  def replay, do: :safe

  @impl true
  def execute(%{"schedule_id" => id}, api), do: {:commit, &cancel(&1, api, String.trim(id))}

  defp cancel(tx, api, id) do
    with :ok <- Assistant.may_act_tx(tx, api.task, :change),
         %{schedule: schedule} <- Schedules.get(id) || {:error, :not_found},
         :ok <- Schedules.delete_tx(tx, id, :any) do
      cancelled(schedule, schedule.project_id && Projects.get(schedule.project_id))
    else
      {:error, :not_found} -> {:error, "There is no schedule #{id}."}
      {:error, message} -> {:error, message}
    end
  end

  defp cancelled(schedule, nil),
    do: {:ok, "Cancelled #{schedule.id}.", %{"schedule_id" => schedule.id}}

  defp cancelled(schedule, project),
    do:
      {:ok, "Cancelled #{schedule.id} in #{project.slug}.",
       %{"schedule_id" => schedule.id, "project_id" => project.id, "slug" => project.slug}}
end

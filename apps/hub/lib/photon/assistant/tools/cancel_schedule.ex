defmodule Photon.Assistant.Tools.CancelSchedule do
  @moduledoc false
  @behaviour Photon.Durable.Tool

  alias Photon.Durable

  @impl true
  def name, do: "cancel_schedule"

  @impl true
  def description, do: "Cancel a scheduled prompt by its ID, from list_schedules."

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
  def execute(%{"schedule_id" => id}, _api) do
    case Durable.task(id) do
      # A project's schedule isn't Blip's to cancel.
      %{kind: "routine", input: input} when not is_map_key(input, "schedule_id") ->
        _routine = Durable.abort_task(id, background: true)
        {:ok, "Cancelled #{id}."}

      _ ->
        {:error, "There is no schedule #{id}."}
    end
  end
end

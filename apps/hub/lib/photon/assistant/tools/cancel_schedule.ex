defmodule Photon.Assistant.Tools.CancelSchedule do
  @moduledoc """
  Blip's `cancel_schedule` tool: deletes one of Blip's own schedules by
  its `sc_` ID, inside the commit that records the result
  (`Photon.Schedules.delete_tx/3`). A project's schedule isn't Blip's to
  cancel, so its ID gets the same answer as an unknown one.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.Schedules

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
  def execute(%{"schedule_id" => id}, _api), do: {:commit, &cancel(&1, id)}

  defp cancel(tx, id) do
    case Schedules.delete_tx(tx, id, :blip) do
      :ok -> {:ok, "Cancelled #{id}."}
      {:error, :not_found} -> {:error, "There is no schedule #{id}."}
    end
  end
end

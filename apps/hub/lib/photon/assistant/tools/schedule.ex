defmodule Photon.Assistant.Tools.Schedule do
  @moduledoc """
  Blip's `schedule` tool (section 3.6 of
  `docs/plans/step-3-skills-and-schedules.md`): one of Blip's own
  schedules, which posts its prompt into Blip's conversation, once or
  repeatedly. It can't schedule work in a project; the owner adds those on
  the project's page.

  The schedule is made inside the commit that records the call's result
  (`Photon.Schedules.blip_schedule_tx/5`), with the call's task ID as its
  request ID, so a call that runs again after a restart makes one
  schedule.
  """
  @behaviour Photon.Durable.Tool

  alias Photon.Durable.ToolAPI
  alias Photon.Schedules

  @impl true
  def name, do: "schedule"

  @impl true
  def description do
    "Schedule a prompt for yourself, once or repeatedly. When it's due, it arrives here as a message starting with \"[Scheduled]\" and you act on it. " <>
      "It posts here, in your own conversation; it can't schedule work in a project. " <>
      "Give the time as in_minutes, or at (ISO 8601 with a UTC offset, such as 2026-10-04T09:00:00-05:00)."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "prompt" => %{
          "type" => "string",
          "description" => "What to do when it fires, written as an instruction to yourself."
        },
        "in_minutes" => %{
          "type" => "integer",
          "description" => "Minutes from now for the first run."
        },
        "at" => %{"type" => "string", "description" => "When to run first, ISO 8601 with offset."},
        "every_minutes" => %{
          "type" => "integer",
          "description" =>
            "Repeat this often (from 5 to 524160, which is 52 weeks). Omit for a one-off."
        }
      },
      "required" => ["prompt"]
    }
  end

  @impl true
  def replay, do: :safe

  @impl true
  def execute(args, api) do
    now = System.system_time(:millisecond)
    request_id = "schedule:" <> ToolAPI.task_id(api)
    {:commit, &schedule(&1, api.conversation_id, args, request_id, now)}
  end

  defp schedule(tx, conversation_id, args, request_id, now) do
    case Schedules.blip_schedule_tx(tx, conversation_id, args, request_id, now) do
      {:ok, schedule} ->
        {:ok, "Scheduled #{schedule.id}: #{Schedules.when_text(schedule)}.",
         %{"schedule_id" => schedule.id}}

      {:error, message} ->
        {:error, message}
    end
  end
end

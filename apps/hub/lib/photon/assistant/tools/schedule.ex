defmodule Photon.Assistant.Tools.Schedule do
  @moduledoc false
  @behaviour Photon.Durable.Tool

  alias Photon.Durable
  alias Photon.Durable.ToolAPI

  @impl true
  def name, do: "schedule"

  @impl true
  def description do
    "Schedule a prompt for yourself, once or repeatedly. When it's due, it arrives here as a message starting with \"[Scheduled]\" and you act on it. " <>
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
          "description" => "Repeat this often (at least 5). Omit for a one-off."
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

    with {:ok, first_at} <- first_at(args, now),
         {:ok, every} <- every(args["every_minutes"]) do
      task =
        Durable.create_task(%{
          kind: "routine",
          conversation_id: api.conversation_id,
          background: true,
          request_id: "schedule:" <> ToolAPI.task_id(api),
          phase: "start",
          input: %{"prompt" => args["prompt"], "first_at" => first_at, "every_ms" => every}
        })

      when_text =
        first_at |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%Y-%m-%d %H:%M UTC")

      repeat = if every, do: ", then every #{div(every, 60_000)} minutes", else: ""
      {:ok, "Scheduled #{task.id}: first at #{when_text}#{repeat}.", %{"schedule_id" => task.id}}
    end
  end

  defp first_at(%{"in_minutes" => minutes}, now) when is_integer(minutes) and minutes >= 0,
    do: {:ok, now + minutes * 60_000}

  defp first_at(%{"at" => at}, now) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _offset} ->
        ms = DateTime.to_unix(dt, :millisecond)
        if ms < now - 60_000, do: {:error, "#{at} is in the past."}, else: {:ok, ms}

      {:error, _} ->
        {:error, "at must be ISO 8601 with a UTC offset, like 2026-10-04T09:00:00-05:00."}
    end
  end

  defp first_at(%{"every_minutes" => every}, now) when is_integer(every),
    do: {:ok, now + every * 60_000}

  defp first_at(_args, _now), do: {:error, "Give in_minutes or at."}

  defp every(nil), do: {:ok, nil}
  defp every(minutes) when is_integer(minutes) and minutes >= 5, do: {:ok, minutes * 60_000}
  defp every(_), do: {:error, "every_minutes must be at least 5."}
end

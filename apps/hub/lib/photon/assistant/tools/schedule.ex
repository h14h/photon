defmodule Photon.Assistant.Tools.Schedule do
  @moduledoc """
  Blip's `schedule` tool (section 3.6 of
  `docs/plans/step-3-skills-and-schedules.md`, and 5.5 of
  `docs/plans/step-4-blip-as-coordinator.md`): a prompt that fires once or
  repeatedly. Without `project` it is one of Blip's own schedules, which
  posts into Blip's conversation. With `project` it is that project's
  schedule, like one the owner adds on the project's page: it starts a
  new thread each time, or wakes the thread `thread` names. Threads a
  project schedule Blip made starts or wakes are Blip's work, so Blip
  hears how they end.

  The schedule is made inside the commit that records the call's result
  (`Photon.Schedules.tool_schedule_tx/4`), with the call's task ID as its
  request ID, so a call that runs again after a restart makes one
  schedule. Its `asked_by` comes from the run that called it
  (`Photon.Assistant.Origin.asked_by/1`): the owner when they wrote to
  that run, Blip otherwise.

  A run that carries a thread's question, and that the owner hasn't
  written into, can't schedule anything (`Photon.Assistant.may_act_tx/3`).
  """
  @behaviour Photon.Durable.Tool

  alias Photon.{Assistant, Schedules, Threads}
  alias Photon.Assistant.{Origin, Readout}
  alias Photon.Durable.ToolAPI

  @impl true
  def name, do: "schedule"

  @impl true
  def description do
    "Schedule a prompt, once or repeatedly. Without project, it's a reminder to yourself: when it's due, it arrives here as a message starting with \"[Scheduled]\" and you act on it. " <>
      "With project, it's work in that project: each time it starts a new thread there with the prompt, or wakes the thread you name. " <>
      "Give the time as in_minutes, or at (ISO 8601 with a UTC offset, such as 2026-10-04T09:00:00-05:00)."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "prompt" => %{
          "type" => "string",
          "description" =>
            "What to do when it fires: an instruction to yourself, or the message a project's thread gets."
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
        },
        "project" => %{
          "type" => "string",
          "description" =>
            "To schedule work in a project, its slug. Leave it out for a reminder to yourself, which posts here."
        },
        "thread" => %{
          "type" => "string",
          "description" =>
            "With project, the ID of one of its threads to wake each time, instead of starting a new thread."
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

    with {:ok, target, project} <- target(args, api) do
      {:commit, &schedule(&1, api, %{target: target, project: project}, args, {request_id, now})}
    end
  end

  # Where it fires: Blip's conversation, or a project (found by slug or
  # ID) and the thread it wakes, if any.
  defp target(%{"project" => name} = args, _api) when is_binary(name) and name != "" do
    with {:ok, project} <- Assistant.find_project(name),
         do: {:ok, {:project, project.id, args["thread"]}, project}
  end

  defp target(%{"thread" => thread}, _api) when is_binary(thread) and thread != "",
    do: {:error, "Give project too: the slug of the project #{String.trim(thread)} is in."}

  defp target(_args, api), do: {:ok, {:blip, api.conversation_id}, nil}

  defp schedule(tx, api, place, args, {request_id, now}) do
    with :ok <- Assistant.may_act_tx(tx, api.task, :change),
         asked_by = Origin.asked_by(Assistant.origin_tx(tx, api.task)),
         {:ok, schedule} <-
           Schedules.tool_schedule_tx(tx, place.target, args, %{
             asked_by: asked_by,
             request_id: request_id,
             now: now
           }) do
      text =
        Readout.scheduled(
          schedule.id,
          Schedules.when_text(schedule),
          readout_place(schedule, place.project)
        )

      {:ok, text, details(schedule, place.project)}
    end
  end

  defp readout_place(_schedule, nil), do: nil

  defp readout_place(schedule, project) do
    thread =
      case schedule.conversation_id && Threads.get(schedule.conversation_id) do
        nil -> nil
        thread -> %{id: thread.id, title: thread.title}
      end

    %{slug: project.slug, thread: thread, repeats?: schedule.every_minutes != nil}
  end

  defp details(schedule, nil), do: %{"schedule_id" => schedule.id}

  defp details(schedule, project) do
    base = %{"schedule_id" => schedule.id, "project_id" => project.id, "slug" => project.slug}

    if schedule.conversation_id,
      do: Map.put(base, "thread_id", schedule.conversation_id),
      else: base
  end
end

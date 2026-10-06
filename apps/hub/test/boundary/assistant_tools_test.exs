defmodule Photon.AssistantToolsTest do
  @moduledoc """
  The assistant's own tools through their `Photon.Durable.Tool` API
  (`execute/2`), the way a tool task calls them, against the database.
  The machine tools have their own tests (`machine_tools_test.exs`).
  """

  use Photon.DataCase, async: false

  import Photon.Fixtures, only: [call: 2, tool_task: 2]

  alias Photon.Assistant.Tools
  alias Photon.Durable.ToolAPI

  @moduletag :durable

  ## Named setups

  defp conversation(_context), do: %{conversation: Photon.Assistant.conversation_id()}

  defp api(%{conversation: c}, name, task_id \\ "t_tool") do
    ToolAPI.new(tool_task(call(name, %{}), id: task_id, conversation_id: c))
  end

  describe "schedules" do
    setup :conversation

    test "start in some minutes, or at a time, optionally repeating", ctx do
      assert {:ok, "Scheduled " <> _, %{"schedule_id" => id}} =
               Tools.Schedule.execute(
                 %{"prompt" => "check disks", "in_minutes" => 10},
                 api(ctx, "schedule", "t_s1")
               )

      assert %{
               kind: "routine",
               background: true,
               input: %{"prompt" => "check disks", "every_ms" => nil}
             } =
               Durable.task(id)

      assert {:ok, text, _} =
               Tools.Schedule.execute(
                 %{"prompt" => "ping", "at" => "2099-01-01T09:00:00Z", "every_minutes" => 60},
                 api(ctx, "schedule", "t_s2")
               )

      assert text =~ "first at 2099-01-01 09:00 UTC, then every 60 minutes"

      assert {:ok, _, _} =
               Tools.Schedule.execute(
                 %{"prompt" => "p", "every_minutes" => 5},
                 api(ctx, "schedule", "t_s3")
               )
    end

    test "refuse a time in the past, a bad time, too short an interval, or no time", ctx do
      api = api(ctx, "schedule")

      assert {:error, "2000-01-01T00:00:00Z is in the past."} =
               Tools.Schedule.execute(%{"prompt" => "p", "at" => "2000-01-01T00:00:00Z"}, api)

      assert {:error, "at must be ISO 8601" <> _} =
               Tools.Schedule.execute(%{"prompt" => "p", "at" => "tomorrow"}, api)

      assert {:error, "every_minutes must be at least 5."} =
               Tools.Schedule.execute(
                 %{"prompt" => "p", "in_minutes" => 1, "every_minutes" => 1},
                 api
               )

      assert {:error, "Give in_minutes or at."} = Tools.Schedule.execute(%{"prompt" => "p"}, api)
    end

    test "are listed with their next time, and cancelled by ID", ctx do
      assert {:ok, "No schedules. (Now: " <> _} =
               Tools.ListSchedules.execute(%{}, api(ctx, "list"))

      {:ok, _, %{"schedule_id" => id}} =
        Tools.Schedule.execute(
          %{"prompt" => "ping", "in_minutes" => 5, "every_minutes" => 30},
          api(ctx, "schedule", "t_s4")
        )

      {:ok, listed} = Tools.ListSchedules.execute(%{}, api(ctx, "list"))
      assert listed =~ ~s(- #{id}: next )
      assert listed =~ ~s(, every 30 min: "ping")

      assert Tools.CancelSchedule.execute(%{"schedule_id" => id}, api(ctx, "cancel")) ==
               {:ok, "Cancelled #{id}."}

      assert Durable.task(id).abort_requested

      assert Tools.CancelSchedule.execute(%{"schedule_id" => "t_nope"}, api(ctx, "cancel")) ==
               {:error, "There is no schedule t_nope."}
    end
  end
end

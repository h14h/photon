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
  alias Photon.{Projects, Schedules}
  alias Photon.Schedules.Schedule

  @moduletag :durable

  ## Named setups

  defp conversation(_context), do: %{conversation: Photon.Assistant.conversation_id()}

  defp api(%{conversation: c}, name, task_id \\ "t_tool") do
    ToolAPI.new(tool_task(call(name, %{}), id: task_id, conversation_id: c))
  end

  describe "schedules" do
    setup :conversation

    setup do
      :ok = Photon.Schedules.subscribe()
    end

    # Runs a tool the way its task does: `{:commit, fun}` is decided inside
    # the commit that records the result.
    defp run(tool, args, api) do
      case tool.execute(args, api) do
        {:commit, fun} -> Durable.commit(fun)
        result -> result
      end
    end

    defp schedule(ctx, args, task_id),
      do: run(Tools.Schedule, args, api(ctx, "schedule", task_id))

    test "start in some minutes, or at a time, optionally repeating", ctx do
      assert {:ok, "Scheduled sc_" <> _, %{"schedule_id" => id}} =
               schedule(ctx, %{"prompt" => "check disks", "in_minutes" => 10}, "t_s1")

      assert_receive {:schedules_changed, nil}

      assert %{state: :waiting, schedule: row} = Schedules.get(id)

      assert %Schedule{
               project_id: nil,
               prompt: "check disks",
               every_minutes: nil,
               created_by: "blip"
             } = row

      assert row.conversation_id == ctx.conversation

      assert %{kind: "routine", background: true, conversation_id: nil} =
               task = Durable.task(row.task_id)

      assert task.request_id == "schedule:t_s1"

      assert task.input == %{
               "schedule_id" => id,
               "first_at" => ms(row.first_at),
               "every_ms" => nil
             }

      assert {:ok, text, _} =
               schedule(
                 ctx,
                 %{"prompt" => "ping", "at" => "2099-01-01T09:00:00Z", "every_minutes" => 60},
                 "t_s2"
               )

      assert text =~
               ~r/\AScheduled sc_\w+: first at 2099-01-01 09:00 UTC, then every 60 minutes\.\z/

      assert {:ok, _, _} = schedule(ctx, %{"prompt" => "p", "every_minutes" => 5}, "t_s3")
      assert length(Schedules.list(:blip)) == 3
    end

    test "refuse a time in the past, a bad time, too short an interval, or no time", ctx do
      refuse = &schedule(ctx, &1, "t_bad")

      assert {:error, "2000-01-01T00:00:00Z is in the past."} =
               refuse.(%{"prompt" => "p", "at" => "2000-01-01T00:00:00Z"})

      assert {:error, "at must be ISO 8601" <> _} =
               refuse.(%{"prompt" => "p", "at" => "tomorrow"})

      assert {:error, "every_minutes must be at least 5."} =
               refuse.(%{"prompt" => "p", "in_minutes" => 1, "every_minutes" => 1})

      assert {:error, "Give in_minutes or at."} = refuse.(%{"prompt" => "p"})
      assert Schedules.list(:blip) == []
      refute_received {:schedules_changed, _}
    end

    test "a call that runs again makes one schedule", ctx do
      args = %{"prompt" => "ping", "in_minutes" => 5, "every_minutes" => 30}
      assert {:ok, text, %{"schedule_id" => id}} = schedule(ctx, args, "t_again")
      assert {:ok, ^text, %{"schedule_id" => ^id}} = schedule(ctx, args, "t_again")

      assert [%{id: ^id}] = Schedules.list(:blip)
      assert [_one] = Durable.live_tasks("routine")
    end

    test "in_minutes 0 fires at once, into Blip's conversation", %{conversation: c} = ctx do
      :ok = Durable.subscribe(c)

      assert {:ok, _, %{"schedule_id" => id}} =
               schedule(ctx, %{"prompt" => "machines", "in_minutes" => 0}, "t_now")

      entry = await_entry(c, &(&1.data["source"]["schedule_id"] == id))
      assert PhotonCore.Message.text_of(entry.data["message"]) == "[Scheduled] machines"
      assert %{last_outcome: "sent"} = Repo.get!(Schedule, id)

      # Lets the run the prompt started finish before the test ends.
      if Durable.busy?(c), do: await_change(c, fn _changes -> not Durable.busy?(c) end)
    end

    test "are listed with their next time, and cancelled by ID", ctx do
      list = fn -> run(Tools.ListSchedules, %{}, api(ctx, "list")) end
      cancel = &run(Tools.CancelSchedule, %{"schedule_id" => &1}, api(ctx, "cancel"))

      assert {:ok, "No schedules. (Now: " <> _} = list.()

      {:ok, _, %{"schedule_id" => id}} =
        schedule(ctx, %{"prompt" => "ping", "in_minutes" => 5, "every_minutes" => 30}, "t_s4")

      task_id = Repo.get!(Schedule, id).task_id

      {:ok, listed} = list.()
      assert listed =~ ~s(- #{id}: next )
      assert listed =~ ~s(, every 30 min: "ping")

      assert cancel.(id) == {:ok, "Cancelled #{id}."}
      assert Schedules.get(id) == nil
      assert Durable.task(task_id).abort_requested
      assert {:ok, "No schedules. (Now: " <> _} = list.()

      assert cancel.("sc_nope") == {:error, "There is no schedule sc_nope."}
    end

    test "leave a project's schedules alone", ctx do
      {:ok, project} =
        Projects.create(%{"purpose" => "Keep the garden watered.", "name" => "Garden"})

      {:ok, theirs} =
        Schedules.create({:project, project.id}, %{
          "prompt" => "Check the backups",
          "at" => DateTime.utc_now() |> DateTime.add(1, :hour) |> DateTime.to_iso8601(),
          "repeat" => "once",
          "target" => "new_thread"
        })

      assert {:ok, "No schedules. (Now: " <> _} = run(Tools.ListSchedules, %{}, api(ctx, "list"))

      assert run(Tools.CancelSchedule, %{"schedule_id" => theirs.id}, api(ctx, "cancel")) ==
               {:error, "There is no schedule #{theirs.id}."}

      assert %{state: :waiting} = Schedules.get(theirs.id)
    end

    test "the schedule tool says it posts to Blip's own conversation" do
      assert Tools.Schedule.description() =~
               "It posts here, in your own conversation; it can't schedule work in a project."
    end
  end

  defp ms(datetime), do: DateTime.to_unix(datetime, :millisecond)
end

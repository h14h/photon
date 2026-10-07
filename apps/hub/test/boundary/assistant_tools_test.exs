defmodule Photon.AssistantToolsTest do
  @moduledoc """
  The assistant's own tools through their `Photon.Durable.Tool` API
  (`execute/2`), the way a tool task calls them, against the database.
  The machine tools have their own tests (`machine_tools_test.exs`).
  """

  use Photon.DataCase, async: false

  import Photon.Fixtures, only: [call: 2, task: 1, tool_task: 2]

  alias Photon.{Assistant, Projects, Schedules, Skills, Threads}
  alias Photon.Assistant.Tools
  alias Photon.Durable.{Submission, ToolAPI, Tx}
  alias Photon.Schedules.{Routine, Schedule}
  alias PhotonCore.Message

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
                 %{"prompt" => "ping", "at" => "2035-01-01T09:00:00Z", "every_minutes" => 60},
                 "t_s2"
               )

      assert text =~
               ~r/\AScheduled sc_\w+: first at 2035-01-01 09:00 UTC, then every 60 minutes\.\z/

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

      assert cancel.(id) == {:ok, "Cancelled #{id}.", %{"schedule_id" => id}}
      assert Schedules.get(id) == nil
      assert Durable.task(task_id).abort_requested
      assert {:ok, "No schedules. (Now: " <> _} = list.()

      assert cancel.("sc_nope") == {:error, "There is no schedule sc_nope."}
    end

    test "a stopped one stays listed with why, so it can be cancelled", ctx do
      {:ok, _, %{"schedule_id" => id}} =
        schedule(ctx, %{"prompt" => "ping", "in_minutes" => 5, "every_minutes" => 30}, "t_s5")

      task = Durable.task(Repo.get!(Schedule, id).task_id)

      :ok =
        Durable.commit(fn tx ->
          _failed = Tx.finish(tx, task, "failed", %{"status" => "failed", "reason" => "boom"})
          Routine.on_fail(task, "boom", tx)
        end)

      assert {:ok, listed} = run(Tools.ListSchedules, %{}, api(ctx, "list"))
      assert listed =~ "- #{id}: stopped after an error (boom); it won't run again until you"
      assert listed =~ ~s(, every 30 min: "ping")

      assert {:ok, "Cancelled " <> _, _details} =
               run(Tools.CancelSchedule, %{"schedule_id" => id}, api(ctx, "cancel"))
    end

    test "the schedule tool says where each kind posts" do
      assert Tools.Schedule.description() =~
               ~s(Without project, it's a reminder to yourself: when it's due, it arrives here)

      assert Tools.Schedule.description() =~
               "With project, it's work in that project: each time it starts a new thread there"
    end
  end

  describe "project schedules" do
    setup :conversation

    setup %{conversation: c} do
      {:ok, garden} =
        Projects.create(%{"purpose" => "Keep the garden watered.", "name" => "Garden"})

      {:ok, house} = Projects.create(%{"purpose" => "Fix things.", "name" => "House"})
      :ok = Schedules.subscribe()

      # A finished run of Blip's that the owner typed into, for the calls
      # below to belong to: only such a run may make a project's schedule.
      _submission =
        Repo.insert!(%Submission{
          id: "s_owner",
          conversation_id: c,
          mode: "follow_up",
          content: %{"parts" => Message.parts("schedule it"), "source" => %{"kind" => "user"}},
          status: "done"
        })

      _run =
        Repo.insert!(
          task(
            id: "t_owner_run",
            conversation_id: c,
            status: "done",
            checkpoint: %{"submissions" => ["s_owner"]}
          )
        )

      %{garden: garden, house: house}
    end

    # A call in the owner's run above.
    defp owner_schedule(%{conversation: c}, args, task_id) do
      call = call("schedule", %{})
      task = tool_task(call, id: task_id, conversation_id: c, owner_task_id: "t_owner_run")
      run(Tools.Schedule, args, ToolAPI.new(task))
    end

    test "are refused in a run the owner didn't type into", %{garden: garden} = ctx do
      args = %{"prompt" => "Water zone 2", "in_minutes" => 5, "project" => "garden"}

      assert schedule(ctx, args, "t_unattended") ==
               {:error,
                "Only the user can set up work in a project on a schedule. Ask them, " <>
                  "or leave out project for a reminder to yourself."}

      assert Schedules.list({:project, garden.id}) == []
      refute_received {:schedules_changed, _}
    end

    test "start a new thread each time, as Blip's, outside any run Blip's own",
         %{
           garden: garden
         } = ctx do
      args = %{
        "prompt" => "Water zone 2",
        "at" => "2035-01-01T09:00:00Z",
        "every_minutes" => 1440,
        "project" => "garden"
      }

      assert {:ok, text, details} = owner_schedule(ctx, args, "t_p1")
      assert_receive {:schedules_changed, garden_id} when garden_id == garden.id

      assert text =~
               ~r/\AScheduled sc_\w+: first at 2035-01-01 09:00 UTC, then every 1440 minutes, in garden, starting a new thread each time\.\z/

      assert %{"schedule_id" => id, "project_id" => project_id, "slug" => "garden"} = details
      assert project_id == garden.id
      refute Map.has_key?(details, "thread_id")

      assert %{state: :waiting, schedule: row} = Schedules.get(id)

      assert %Schedule{
               project_id: ^project_id,
               conversation_id: nil,
               prompt: "Water zone 2",
               every_minutes: 1440,
               created_by: "blip",
               asked_by: "owner"
             } = row

      assert [%{id: ^id}] = Schedules.list({:project, garden.id})
      assert Schedules.list(:blip) == []

      # A rerun of the call makes nothing new.
      assert {:ok, ^text, ^details} = owner_schedule(ctx, args, "t_p1")
      assert [_one] = Schedules.list({:project, garden.id})
    end

    test "wake a thread in the project", %{garden: garden} = ctx do
      thread = idle_thread!(garden)

      args = %{
        "prompt" => "Check the pump",
        "in_minutes" => 30,
        "project" => garden.id,
        "thread" => " #{thread.id} "
      }

      assert {:ok, text, %{"thread_id" => thread_id} = details} =
               owner_schedule(ctx, args, "t_p2")

      assert thread_id == thread.id
      assert details["slug"] == "garden"
      assert text =~ ~s(, in garden, waking #{thread.id} "#{thread.title}".)
      refute text =~ "each time"

      assert %Schedule{conversation_id: ^thread_id, project_id: project_id} =
               Repo.get!(Schedule, details["schedule_id"])

      assert project_id == garden.id
    end

    test "refuse a thread from another project, a thread without a project, and an unknown project",
         %{house: house} = ctx do
      theirs = idle_thread!(house)

      assert owner_schedule(
               ctx,
               %{
                 "prompt" => "p",
                 "in_minutes" => 5,
                 "project" => "garden",
                 "thread" => theirs.id
               },
               "t_bad"
             ) == {:error, "#{theirs.id} isn't a thread in garden."}

      assert owner_schedule(
               ctx,
               %{"prompt" => "p", "in_minutes" => 5, "thread" => theirs.id},
               "t_bad"
             ) ==
               {:error, "Give project too: the slug of the project #{theirs.id} is in."}

      assert owner_schedule(
               ctx,
               %{"prompt" => "p", "in_minutes" => 5, "project" => "gardn"},
               "t_bad"
             ) ==
               {:error, "There's no project called gardn. Projects: garden, house."}

      assert owner_schedule(ctx, %{"prompt" => "p", "project" => "garden"}, "t_bad") ==
               {:error, "Give in_minutes or at."}

      assert Schedules.list({:project, house.id}) == []
      refute_received {:schedules_changed, _}
    end

    test "are listed with their targets, and cancelled by ID", %{garden: garden} = ctx do
      list = &run(Tools.ListSchedules, &1, api(ctx, "list"))
      cancel = &run(Tools.CancelSchedule, %{"schedule_id" => &1}, api(ctx, "cancel"))

      assert {:ok, "No schedules in garden. (Now: " <> _, %{"slug" => "garden"}} =
               list.(%{"project" => "garden"})

      thread = idle_thread!(garden)

      {:ok, _, %{"schedule_id" => new}} =
        owner_schedule(
          ctx,
          %{"prompt" => "Water", "in_minutes" => 5, "project" => "garden"},
          "t_l1"
        )

      {:ok, _, %{"schedule_id" => woken}} =
        owner_schedule(
          ctx,
          %{
            "prompt" => "Pump",
            "in_minutes" => 10,
            "every_minutes" => 60,
            "project" => "garden",
            "thread" => thread.id
          },
          "t_l2"
        )

      {:ok, listed, details} = list.(%{"project" => "garden"})
      assert details == %{"project_id" => garden.id, "slug" => "garden"}
      assert listed =~ "Schedules in garden:\n"
      assert listed =~ ~s(- #{new}: first at )
      assert listed =~ ~s(starts a new thread each time: "Water")
      assert listed =~ ~s(wakes #{thread.id} "#{thread.title}": "Pump")

      # Blip's own list leaves the project's out.
      assert {:ok, "No schedules. (Now: " <> _} = list.(%{})

      task_id = Repo.get!(Schedule, new).task_id

      assert cancel.(new) ==
               {:ok, "Cancelled #{new} in garden.",
                %{"schedule_id" => new, "project_id" => garden.id, "slug" => "garden"}}

      assert_receive {:schedules_changed, garden_id} when garden_id == garden.id
      assert Schedules.get(new) == nil
      assert Durable.task(task_id).abort_requested
      assert [%{id: ^woken}] = Schedules.list({:project, garden.id})
    end

    test "made in a run the owner wrote to are asked by the owner; a reminder in a scheduled run, by Blip",
         %{conversation: c, garden: garden} do
      :ok = Durable.subscribe(c)
      {:ok, s} = Assistant.send("every 60 minutes in garden: Water zone 2")
      await_settled(c, s.id)

      assert [%{schedule: %Schedule{prompt: "Water zone 2"} = owners}] =
               Schedules.list({:project, garden.id})

      assert {owners.created_by, owners.asked_by} == {"blip", "owner"}

      # One of Blip's own schedules fires a prompt that makes another of
      # its own (a project's would be refused there).
      Repo.insert!(%Schedule{
        id: "sc_morning",
        conversation_id: c,
        prompt: "in 30 minutes: Check the pump",
        first_at: DateTime.utc_now() |> DateTime.add(1, :day),
        version: 1,
        created_by: "blip",
        asked_by: "owner"
      })

      assert Schedules.run_now("sc_morning") == {:ok, "sent"}

      await_entry(
        c,
        &(&1.kind == "tool_result" and &1.data["name"] == "schedule" and
            &1.data["details"]["schedule_id"] != owners.id)
      )

      if Durable.busy?(c), do: await_change(c, fn _changes -> not Durable.busy?(c) end)

      assert %Schedule{asked_by: "blip", created_by: "blip", project_id: nil} =
               Repo.get_by!(Schedule, prompt: "Check the pump")
    end
  end

  describe "skills" do
    setup :conversation

    setup do
      {:ok, garden} =
        Projects.create(%{"purpose" => "Keep the garden watered.", "name" => "Garden"})

      :ok = Skills.subscribe()
      %{garden: garden}
    end

    defp skill!(name, description \\ "Fill in PDF forms."),
      do:
        elem(
          Skills.create(%{
            "name" => name,
            "description" => description,
            "instructions" => "# #{name}\n\nDo it."
          }),
          1
        )

    defp set(ctx, args), do: run(Tools.SetProjectSkill, args, api(ctx, "set_project_skill"))

    test "list_skills shows every skill and where it is on", %{garden: garden} = ctx do
      assert run(Tools.ListSkills, %{}, api(ctx, "list_skills")) == {:ok, "No skills yet."}

      pdf = skill!("pdf-forms")
      _notes = skill!("release-notes", "Write release notes")
      :ok = Skills.enable(pdf.id, :blip)
      :ok = Skills.enable(pdf.id, {:project, garden.id})

      assert run(Tools.ListSkills, %{}, api(ctx, "list_skills")) ==
               {:ok,
                "pdf-forms: Fill in PDF forms. On for: you, garden.\n" <>
                  "release-notes: Write release notes. Off everywhere."}
    end

    test "list_skills names a machine a skill is on for", %{garden: garden} = ctx do
      {:ok, _key} = Photon.NodeKeys.issue("mm1")
      ios = skill!("ios-simulators", "Run iOS simulators")
      :ok = Skills.enable(ios.id, {:machine, "mm1"})

      assert run(Tools.ListSkills, %{}, api(ctx, "list_skills")) ==
               {:ok, "ios-simulators: Run iOS simulators. On for: machine mm1."}

      :ok = Skills.enable(ios.id, :blip)
      :ok = Skills.enable(ios.id, {:project, garden.id})

      assert run(Tools.ListSkills, %{}, api(ctx, "list_skills")) ==
               {:ok, "ios-simulators: Run iOS simulators. On for: you, machine mm1, garden."}
    end

    test "set_project_skill turns a skill on and off for a project, once",
         %{garden: garden} = ctx do
      pdf = skill!("pdf-forms")
      pdf_id = pdf.id
      # Its creation's announcement.
      assert_receive {:skills_changed, ^pdf_id}
      on = %{"project" => "garden", "skill" => " PDF-forms ", "on" => true}

      assert set(ctx, on) ==
               {:ok, "Turned on pdf-forms for garden.",
                %{
                  "project_id" => garden.id,
                  "slug" => "garden",
                  "skill" => "pdf-forms",
                  "on" => true
                }}

      assert_receive {:skills_changed, ^pdf_id}
      assert [%{name: "pdf-forms"}] = Skills.enabled({:project, garden.id})
      assert Skills.enabled(:blip) == []

      # Already on: nothing changes, nothing is announced.
      assert {:ok, "Turned on pdf-forms for garden.", _} = set(ctx, on)
      refute_received {:skills_changed, _}

      assert {:ok, "Turned off pdf-forms for garden.", %{"on" => false}} =
               set(ctx, %{on | "on" => false})

      assert_receive {:skills_changed, ^pdf_id}
      assert Skills.enabled({:project, garden.id}) == []
    end

    test "set_project_skill refuses an unknown skill or project, and a 31st skill",
         %{
           garden: garden
         } = ctx do
      assert set(ctx, %{"project" => "garden", "skill" => "pdf-form", "on" => true}) ==
               {:error, "There's no skill called pdf-form. There are no skills yet."}

      _pdf = skill!("pdf-forms")
      _notes = skill!("release-notes")

      assert set(ctx, %{"project" => "garden", "skill" => "pdf-form", "on" => true}) ==
               {:error, "There's no skill called pdf-form. Skills: pdf-forms, release-notes."}

      assert set(ctx, %{"project" => "gardn", "skill" => "pdf-forms", "on" => true}) ==
               {:error, "There's no project called gardn. Projects: garden."}

      for n <- 1..30, do: :ok = Skills.enable(skill!("skill-#{n}").id, {:project, garden.id})

      assert {:error, "30 skills are on here already." <> _} =
               set(ctx, %{"project" => "garden", "skill" => "pdf-forms", "on" => true})

      assert length(Skills.enabled({:project, garden.id})) == 30
    end
  end

  # A thread in `project` whose first run has ended.
  defp idle_thread!(project) do
    {:ok, thread} = Threads.start(project.id, "files")
    :ok = Durable.subscribe(thread.id)

    if Durable.busy?(thread.id),
      do: await_change(thread.id, fn _changes -> not Durable.busy?(thread.id) end)

    thread
  end

  defp ms(datetime), do: DateTime.to_unix(datetime, :millisecond)
end

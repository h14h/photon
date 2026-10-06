defmodule Photon.Assistant.RoutineTest do
  @moduledoc "When a scheduled routine fires, and what it posts."

  use Photon.Case, async: true

  alias Photon.Assistant.Routine

  describe "a routine" do
    defp routine(input, checkpoint \\ %{}) do
      task(id: "t_r", kind: "routine", phase: "fire", input: input, checkpoint: checkpoint)
    end

    test "first waits until its first time, counting runs from zero" do
      assert Routine.first_wait(routine(%{"first_at" => 1_000})) ==
               {:wait, %{"until" => 1_000}, "fire", %{"next_at" => 1_000, "runs" => 0}}

      assert {:wait, %{"until" => 5_000}, "fire", _} =
               Routine.first_wait(routine(%{"first_at" => 1_000}, %{"next_at" => 5_000}))
    end

    test "posts its prompt once per firing" do
      task = routine(%{"prompt" => "check disks"}, %{"runs" => 2})

      assert Routine.prompt(task) == "[Scheduled] check disks"
      assert Routine.request_id(task) == "routine:t_r:2"
    end

    test "a one-off finishes after it fires" do
      assert Routine.after_fire(routine(%{"every_ms" => nil}, %{"runs" => 0}), 0) ==
               {:done, %{"runs" => 1}}
    end

    test "a recurring one waits for its next time on its grid, skipping missed runs" do
      task = routine(%{"every_ms" => 100}, %{"next_at" => 1_000, "runs" => 3})

      assert Routine.after_fire(task, 1_050) ==
               {:wait, %{"until" => 1_100}, "fire", %{"next_at" => 1_100, "runs" => 4}}

      assert Routine.next_after(1_000, 100, 1_350) == 1_400
      assert Routine.next_after(1_000, 100, 500) == 1_100
    end
  end
end

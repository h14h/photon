defmodule Photon.ProjectHelpers do
  @moduledoc """
  Builders for the records tests hang their threads and schedules off,
  stored through the contexts' APIs: the "Garden" project most tests use,
  and project schedules made as the schedule form makes them.
  """

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  import ExUnit.Assertions

  alias Photon.{Projects, Schedules}
  alias Photon.Schedules.Schedule

  @doc ~s(The "Garden" project, to keep the garden watered; `overrides` replace its params.)
  def garden!(overrides \\ %{}) do
    params = Map.merge(%{"name" => "Garden", "purpose" => "Keep the garden watered."}, overrides)
    {:ok, project} = Projects.create(params)
    project
  end

  @doc "An ISO 8601 time `ms` from now, as the schedule form's hook sends it."
  def at(ms), do: DateTime.utc_now() |> DateTime.add(ms, :millisecond) |> DateTime.to_iso8601()

  @doc "The schedule form's params: a new thread to check the backups once, in an hour."
  def schedule_params(overrides \\ %{}) do
    Map.merge(
      %{
        "prompt" => "Check the backups",
        "at" => at(:timer.hours(1)),
        "repeat" => "once",
        "target" => "new_thread"
      },
      overrides
    )
  end

  @doc "A schedule in `project`, made from `schedule_params/1`."
  def schedule!(project, overrides \\ %{}) do
    assert {:ok, %Schedule{} = schedule} =
             Schedules.create({:project, project.id}, schedule_params(overrides))

    schedule
  end
end

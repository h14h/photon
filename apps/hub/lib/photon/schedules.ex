defmodule Photon.Schedules do
  @moduledoc """
  Schedules (section 3 of `docs/plans/step-3-skills-and-schedules.md`):
  prompts that fire at set times. A project's schedules start a new
  thread in the project each time, or wake one of its threads; Blip's own
  schedules post into Blip's conversation. The owner manages a project's
  on its page, and Blip makes its own with its `schedule` tool. Threads
  have no schedule tools, since a schedule that starts threads would let
  a thread start threads.

  A schedule is a row (`Photon.Schedules.Schedule`: the definition and a
  summary of its last firing) and a durable routine task that waits for
  its next time and fires it (`Photon.Schedules.Routine`, the
  `"routine"` task kind). The task is only the timer: the next time and
  whether the schedule is waiting, done or stopped are read from it,
  never stored on the row (rule 15).

  Where a firing goes follows from the row (`Photon.Schedules.Rules.target/1`):
  Blip's conversation, one thread, or a new thread, each with
  `"[Scheduled] <prompt>"` as the message. A firing reads the row and the
  facts it needs and applies `Photon.Schedules.Rules.fire/2`'s decision
  in one commit, so the facts are current when the decision lands:

    * consent: a firing uses the owner's ChatGPT plan only when Settings
      allows scheduled work (or on the scripted model, which uses nobody's
      plan); otherwise it is skipped, with a notice in Blip's conversation
      or the thread
    * overlap: a new-thread schedule skips while the thread it last
      started is still running, and a prompt never queues behind one of
      its own, so a stuck thread doesn't pile up firings (rule 73)

  Every edit replaces the task and every delete retires it, in the same
  commit as the row's change. The fence is `Photon.Durable.Runtime.commit/2`:
  a firing step whose task was marked for abort, finished or restarted
  commits nothing, so a firing happens once and never after its schedule
  was edited or deleted (checked in TLA+, `specs/tla/Durable.md`). The
  replacement task arms at the first time the old one hadn't fired
  (`Photon.Schedules.Rules.arm/4` and `fired_through/3`), so an edit
  neither skips nor repeats a firing.

  Every change and every firing announces `{:schedules_changed,
  project_id}` (nil for Blip's) on `"schedules"` after its commit.

  There is no process here: the rows and the durable tasks hold the
  state, the Scheduler wakes the tasks, and the Store's commit line
  orders the writes. A hub restart finds each task waiting for its time,
  as it finds any durable task.
  """

  use Boundary,
    deps: [
      Photon.Durable,
      Photon.Events,
      Photon.Projects,
      Photon.Repo,
      Photon.Settings,
      Photon.Threads,
      PhotonCore,
      Ecto
    ],
    exports: [Schedule]
end

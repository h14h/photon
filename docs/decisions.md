# Design decisions

The choices behind Photon that the code alone doesn't explain, and what
isn't built yet. Each entry names the code it concerns; read it before
changing that code. The build plans they came from are in git history:
the docs/plans folder, removed once the five build steps and machine skills
shipped.

## Projects and threads

**Projects aren't tied to a machine, and needn't be code.** A project is
the context for any body of work, and any of its threads can use any
machine. That is why threads don't get their own git worktree as in T3
Code: many projects aren't repos. A purpose is the only required field;
there is no status, kind or owner column. (`Photon.Projects`)

**One owner.** Photon has a single user. Questions passed on, unread
state, Resolve and activity credit all assume "the owner" and would need
rethinking for a second person. (`Photon.Projects.Project`,
`Photon.Threads.State`)

**A project's threads share one folder per machine.** `workdir/1` is the
project's slug, so threads running at once see each other's files; the
thread prompt tells them to look before deleting or overwriting. A slug is
one `[a-z0-9-]` segment, so it can't leave the workspace, but it can
match a folder that already exists there (a repo cloned as `photon`), and
the project then works in it; the project page shows the path.
(`Photon.Threads.workdir/1`, `Photon.Projects.Rules.slug/1`)

**Every submission to a thread goes through `Threads.start_tx/4` or
`send_tx/4`.** They set `active_at` and announce `{:projects_changed, id}`
in the submission's commit. The sidebar, the project page's order and
`PhotonWeb.Shell`'s cheap `{:durable_tasks, _}` filter rely on that; a
direct `Durable.submit_tx/4` leaves the thread unlisted.

**The sidebar is an assign, not a stream.** It is bounded (each project's
five most recent threads plus any running one), and it is set by an
`on_mount` hook and drawn by `Layouts.app`, which a stream can't pass
through. The pages' own lists are streams. (`PhotonWeb.Shell`)

**Projects and threads are never deleted.** Some code relies on it:
`Threads.system_prompt/1` and `workdir/1` raise when the row or project is
missing, a schedule's `"skipped_missing"` outcome can't happen yet, and
skill enablements have no foreign key to projects. Adding deletion means
revisiting all three.

**Page paths aren't URL-decoded.** `Assistant.Page.at/1` splits the raw
path, which works only because slugs and context file names use characters
a browser leaves alone. Widen either alphabet and `at/1` must decode.

## Context files

**Threads overwrite; the owner's editor checks versions.** A thread's
`write_context_file` replaces the whole file, last write wins.
`edit_context_file` exists so a thread can change one passage without
rewriting the file over the owner's edits; its `old_text` must occur
exactly once, counting overlaps. (`Photon.Projects.Rules.edit/4`)

**Every editor saves against the version it loaded, and offers "Keep my
text".** The context file, skill and schedule editors refuse a stale save
and offer to load the saved version or keep the owner's text, which takes
the stored version so the next save wins. Without it the owner could never
save over a thread's or another tab's change. (`PhotonWeb.EditorComponents`)

## Skills

**Install never edits the instructions.** It drops other files and extra
front matter and says so in its notes, but keeps the instructions as
written even where they mention files it left out, since cutting sentences
could change what the rest means. `files_left_out` is its own column
because it drives the line `load_skill` adds telling the agent not to look
for those files (a same-named file in a project folder is something
else). (`Photon.Skills.Source`, `Photon.Skills.Prompt`)

**GitHub is read without signing in.** No token is stored; anonymous API
access allows about 60 requests an hour and a link costs at most two.
(`Photon.Skills.Fetch`)

**Turning a skill off doesn't rewrite history.** Nothing records which
skills a conversation loaded beyond the transcript; the prompt tells the
model to stop following a loaded skill no longer listed. Removing loaded
text from model input was rejected: it would need a profile hook in
`Photon.Durable.Context`.

**An enablement's scope is a string, not a foreign key.** One table serves
Blip (`"blip"`), projects (the project ID) and machines (`"machine:<id>"`),
so a future project delete must remove its enablement rows itself.
(`Photon.Skills.Enablement`)

**Machine skills only add.** A skill on for a machine is offered to Blip
and every thread whatever their own sets hold; an "only on these machines"
filter was ruled out. Each set (Blip, each project, each machine) holds at
most 30 skills with no hub-wide cap, so a prompt can list 30 × (machines
with skills + 1) descriptions. (`Photon.Skills.offered/1`)

**A machine's skills belong to its name.** Removing or forgetting a machine
leaves its enablement rows; readers filter them through
`Machines.known/0`, so `Photon.NodeKeys` needn't know about skills. A
different computer later installed under that name inherits them.

**Skills never reach a node.** A skill is instructions on the hub; a node
sees only the commands an agent runs. No spec models skills: a tool that
turns machine skills on from inside a run, or anything that sends skills
to nodes, needs `Durable.tla` extended first.

**SKILL.md parse errors are plain text**, shown as written, so they hold no
Markdown. (`Photon.Skills.SkillMd`)

## Schedules and time

**Repeats are fixed UTC intervals.** The hub has no time zone database
(Settings' time zone is free text for Blip's prompt). The browser converts
times for display and input, so "every day from 09:00" moves an hour when
the clocks change. The daily review works the same way at the browser's
UTC offset, re-armed on each Settings save. (`Photon.Schedules.Rules`,
`PhotonWeb.TimeComponents`, `Photon.Ambient.Rules.next_review/2`)

**Every edit replaces the timer task**, even one that only changes the
prompt: one code path, and the task's input always matches the row. The
step fence and `Rules.arm/4` make the swap safe. Schedule times are covered
by ExUnit (`test/core/schedules/rules_test.exs`,
`test/boundary/schedules_test.exs`), not TLC. (`Photon.Schedules.update/3`)

**Stop on a thread withdraws its waiting scheduled prompts; Blip's Stop
keeps them.** Stop starts the next queued input, so a scheduled prompt left
on a thread would start a run the moment the owner pressed Stop. A
withdrawn prompt doesn't count as queued, so the next firing isn't skipped.
Blip keeps background input because the work that sent it carries on.
(`Photon.Threads.stop/1`, `Photon.Assistant.stop/0`)

**Blip's own schedules have no form.** They are made by asking Blip and
listed on Home; `update/3` refuses them.

## Thread state

**State comes from code; judgement comes from Blip.** Waking Blip's model
on every change would run down the owner's ChatGPT plan, so code works out
each thread's state and which changes reach Blip, and Home shows the state
directly. (`Photon.Threads.State`, `Photon.Signals.Rules`)

**Quiet means stopped and left alone, not just old.** Only a thread whose
last run was stopped (or never recorded an end) can go quiet, after 72
hours: long enough that a thread worked on every weekday never shows,
short enough to catch one stopped and forgotten last week. The daily
review uses the same threshold (`Threads.quiet_after/0`). Resolve exists so
"done with this" is explicit; any new input clears it.

**Unread has no time limit, and only the owner marks a thread seen.**
Finished work that dropped off the list on its own would defeat the list;
Blip's `read_thread` doesn't mark it seen.

**"It asked a question" is a heuristic tied to the thread prompt.** The
last paragraph with words, after a trailing code block, ends in `?`. The
thread prompt says to end with a question only when it needs a reply, so a
change to one needs a check of the other. (`Threads.State.asks?/1`,
`Photon.Threads.Prompt`)

## Signals and questions

**Whose work a run is comes from its inputs, not who started the thread.**
The signal filter reads the settled submissions' sources; a schedule's
firing belongs to whoever made the schedule (`created_by`). An owner's
thread that finishes normally never wakes Blip: Home shows it unread, and
in ambient mode it becomes a digest item. (`Signals.Rules.thread_update/2`)

**A question never shares a message with an update.** A question's run is
restricted unless the owner types into it; merged messages would either
strip update runs of their tools or let questions escape the restriction.
(`Signals.Rules`, `Assistant.Origin`)

**Threads know nothing about the owner.** A thread's prompt carries no
name, memory or Settings instructions; it asks with `ask_blip`. What Photon
knows about the owner stays in one place, away from threads running
unattended on any machine. (`Photon.Threads.Prompt`)

**The owner's answer reaches the thread by code, never through Blip's
model.** Blip gets a copy and runs once on it so it can remember; that run
is the cost of Blip learning. When Blip passed the question on in its own
words, the thread's result includes that wording, so "yes" is read against
what the owner saw. (`Questions.answer/2`, `Questions.Rules.result/1`)

**A question with the owner waits without limit; one Blip skipped reaches
the owner within a minute.** The waiting call escalates at its next check.
The escalation notice is neutral because Blip may already have asked in
prose; only `ask_owner` gives the owner a card that answers the thread.
While a question is with the owner, the thread page's composer becomes the
answer form, since a typed message would only queue behind the parked
call. (`Questions.escalate/1`, `PhotonWeb.ThreadLive`)

**IDs stay out of what the owner reads.** Refusals for Blip name the `q_`
ID its tools take; the owner's name the thread by title; notices carry no
ID. (`Questions.Rules`)

## What Blip may do on its own

**The unattended limit is in code, because prompts can't bound a loop.**
Blip and a thread can keep waking each other. Between two owner messages,
Blip may start or message threads at most 10 times in runs the owner
didn't type into, capping a loop at 10 thread runs and 11 Blip runs. Calls
in runs the owner typed into don't count. (`Assistant.may_act_tx/3`,
`Origin.unattended_ok?/3`)

**Project schedules need the owner's own words.** A count can't bound a
schedule, since one call fires forever, so Blip's `schedule` with a project
is refused in any run the owner didn't type into. Blip may still set its
own reminders. (`Origin.schedule_work_ok?/1`)

**A thread's question can't make Blip start work.** A run carrying a
question the owner hasn't typed into can't start, wake, stop or schedule
threads or change a project: threads can't start work, directly or
through Blip. Thread updates have no such limit because Blip acts on them
for the owner.

**Closing a thread and Blip's own skills stay the owner's.** Blip has no
resolve, archive or delete tool; it may change a project's skills but not
its own set or a machine's, since a machine skill changes what every agent
is offered. (`Assistant.Tools.SetProjectSkill`)

## Activity log

**Thread updates are credited to "Blip's follow-up", never to a thread.**
Crediting some to the owner would need a link from each thread to the
owner's request, which nothing stores. Only a question's own calls are
credited to its thread. (`Activity.Rules.origin_label/2`)

**Blip's schedules record why they were made (`asked_by`), not whether
they repeat.** Repetition got one-off owner reminders wrong.
(`Schedules.Schedule`, `Origin.asked_by/1`)

## Ambient mode

### The digest

**The digest is how Blip follows along, so it collects what Blip doesn't
already hear about.** Only items new to the owner trigger one (a finished
run they haven't opened, a stopped schedule); smaller changes ride along:
file writes, projects and threads the owner made, renames, Resolves, and
finishes they have seen. It leaves out what Blip already got as signals or
did itself, so collectors hook only the owner-facing entry points
(`Projects.create/1`, not `create_tx/2`) and never a write by `"blip"`.
(`Ambient.Rules.digest/3`, `Signals.collect_tx/2`)

**A stopped schedule is news until the owner saves or deletes it.** The
item stores the failed task, since a Save keeps the schedule's ID but arms
a new task.

### The daily review

**The review covers quiet, failed and waiting threads, not unread ones**,
which the digest covers. A thread is raised once per quiet spell and again
after 7 days if still untouched. A review's marks are cleared if Blip never
told the owner (withdrawn, failed, or ambient mode turned off while
queued); otherwise Home would say "In Blip's review" and the next review
would skip those threads for a week. (`Ambient.Rules.review/3`)

### Digest and review runs

**They only report.** They can't start, message or stop threads or change
projects or schedules: waking a stopped thread would undo the owner's Stop,
and a run that starts nothing can't feed the next digest. Machine tools
stay. The owner typing into the run lifts the limit; their answer to a
question doesn't. (`Origin.report_only?`)

**`[nothing to tell]` is silent**: no bubble, no activity row, nothing in
the panel, since a "nothing to report" bubble every few hours is worse
than silence. (`Transcript.nothing_to_tell?/1`, `Assistant.Notice`)

**Earlier digests shrink in later requests, by a generic rule.** Blip's
conversation resets only on Fresh context. `Durable.Context` sends a past
run whose first input has an `"older"` map as its stub, or drops it when
its answer matched `"drop_if_answer"`. The cut moves only when a new run
starts, so requests within a run share a cacheable prefix.

**Ambient mode spends the plan only with the scheduled-work consent.**
Firings skip without "Let schedules use my plan while I'm away" or while
Blip can't reach its model. The Settings section stays visible while the
setting is on, even signed out, so it can always be turned off.

## Machines and commands

**Blip and threads run commands themselves, on any machine.** `shell`,
`view_image` and `list_machines` take a `machine` argument; nodes run no
model. The hub's own computer is `local`, reached through the node inside
the hub's VM. (`Photon.MachineTools`)

**A machine call is synchronous.** unreal-agent's async tool calls
(placeholder results, grace periods, heartbeats) weren't carried over. A
`shell` call holds its conversation until the command exits, so the prompt
tells agents to start long work detached and check back with `schedule`.
(`Photon.MachineTools.Guide`)

**Commands run without approval or timeout.** Stop is the only control.
(`Photon.MachineTools.Call`)

## Durable harness

**The Scheduler commits each decision on its own.** One commit per pass
would be cheaper but would change the interleavings `Durable.tla` checks,
so batching needs the spec updated first. (`Photon.Durable.Scheduler`)

## Prompts and compatibility

**Nothing that changes often goes in a system prompt**, so provider prompt
caches stay warm. Neither prompt lists machines or who is online (agents
call `list_machines`), and machines are listed in `known/0` order, which
ignores who is connected. (`Photon.Machines.Roster.ids/3`)

**A feature that's off or unused leaves the prompt byte for byte.** With no
machine skills, the Skills section is the earlier text exactly; with
ambient mode off, Blip's prompt is what it was before ambient mode. Tests
pin this (`skills/prompt_test.exs`, `roster_test.exs`). Follow the pattern
for new prompt sections. (`Photon.Skills.Prompt`, `Photon.Assistant.Prompt`)

**`load_skill` is always offered**, even with no skills on, so the tool
list stays stable for caching and every stored call names a tool the
profile still has. Removing a tool from a profile breaks that for existing
conversations.

**Stored names are data.** The source kind `"routine"`, the task kinds
`"routine"`, `"thread_title"` and `"ambient"`, and the profile names are
stored in rows and mapped to modules in config; renaming one means
migrating rows.

**The live hub's data is kept.** Schema changes ship as additive
migrations that read existing rows sensibly without a backfill. A breaking
node protocol change bumps the `ops:N` capability (`docs/operations.md`).

## Known limitations

- The Scheduler scans every live task on each reconcile.
- Live model output isn't coalesced: each delta is one broadcast to every
  subscriber (pages re-render Markdown only when a block finishes).
- `PhotonWeb.Shell` rebuilds its data in every open tab on each change.
- Conversation pages load the whole conversation and keep every tool
  result (without image data) in assigns.
- A `Photon.Provision` restart loses its job table.
- `NodeChannel.join/3` can block up to 2 s while it takes over a replaced
  connection, and concurrent `Tailnet` cache misses each run `tailscale`.
- Hub database tests run one at a time; a VM runs at most one node.
- `LLM.Mock` takes call IDs from the clock, so scripted replies aren't
  deterministic.

## Not built yet

- Deleting, archiving or moving projects and threads; Blip resolving,
  archiving or deleting threads
- A folder per thread instead of one per project and machine
- A model per thread or project
- Approvals for shell commands, and a command timeout
- Collaborators on projects
- Skills with scripts or other files; updating an installed skill from its
  source, and exporting one as a SKILL.md; machine skills on the Nodes page
- Pausing a schedule; calendar rules such as "weekdays at 9"; schedules
  and the daily review following the owner's time zone across daylight
  saving changes
- Quiet hours for digests, other digest intervals, a review time other
  than 09:00, and digests of machine changes such as a node going offline
- Pruning the activity log and digest history; an activity row that links
  to its call in Blip's conversation
- Threads talking to each other, and tagging @Blip inside a thread
- A Discord client for Blip; watchers on outside services (GitHub, Slack)
  that post into threads
- Image resizing in `view_image` (an oversized image fails with a hint)

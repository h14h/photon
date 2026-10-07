# Projects, threads and Blip

Status: written 2026-10-05. All five steps of the build order are built
(2026-10-06 to 2026-10-07). What they left for later is listed under
"Build order".

Photon is meant to be a self-hostable replacement for two things at once:

- **T3 Code**: projects, each with threads, where agents do real work on
  your machines.
- **A personal assistant** in the spirit of ChatGPT, Instinct and Claude
  Tag: Blip, one point of entry that learns who you are, handles everyday
  requests itself, follows along with every project, and helps you keep
  track of it all.

This doc describes the model, how the hub and nodes split the work, the UI,
and an order to build it in. Photon has a single user for now. Existing
data is not kept: the system is early, so tables, the hub-node protocol and
installed nodes are all replaced without migrations or compatibility
shims.

## Concepts

**Machine.** A computer Photon can run tools on: a node, connected to the
hub. The hub's own computer is a machine too, by running a node on it.
Machines don't run agents or call models any more; they carry out tool
calls the hub sends them.

**Skill.** Instructions an agent can load when a task calls for it.
Skills live on the hub; you write or install them in the app. A new skill
is turned off everywhere: each project, and Blip, has its own set of
enabled skills. Skills are instructions only for now, with no scripts or
other files to run.

> Status: step 3 built skills (`docs/plans/step-3-skills-and-schedules.md`,
> section 2). A skill is a name, a description and Markdown instructions,
> written on the Skills page or installed from a pasted SKILL.md or a
> GitHub link. Install keeps only those three and says what it left out
> (other files in the folder, other front matter, files the instructions
> mention). A project's skills are turned on on its page, Blip's on the
> Skills page and on each skill's page. An agent's prompt lists the
> enabled skills' names and descriptions, and its `load_skill` tool puts
> one's instructions in the conversation. Each set holds at most 30.

**Project.** A context for some body of work, not necessarily code. It has:

- an owner (you, for now)
- a **Purpose** (required): a few sentences on what the project is for
- **context files**: freeform Markdown kept on the hub (notes, goals,
  research, decisions), read and written by you and by its threads
- the **skills** enabled for it
- **threads**
- **schedules**: prompts that start or wake a thread at set times

A project doesn't belong to a machine. Its threads can use any machine.

**Schedule.** A prompt that fires at set times, once or every so often. A
project's schedule starts a new thread in the project each time, or
wakes one of its threads. Blip has its own schedules, for things outside
projects like a morning review, which post into Blip's conversation.
Threads can't make schedules, since a schedule that starts threads would
let a thread start threads.

A firing is skipped rather than piled up. A new-thread schedule waits
while the thread it last started is still running, and a prompt doesn't
queue behind one of its own that hasn't run yet. Stop in a thread
withdraws everything queued there, scheduled prompts included, so the
thread stays stopped until the schedule's next firing. Blip's Stop keeps
its scheduled prompts waiting. A firing uses your
ChatGPT plan only when Settings allows scheduled work; otherwise it is
skipped, and the project page or the conversation says so.

> Status: step 3 built schedules (`docs/plans/step-3-skills-and-schedules.md`,
> section 3). Each is a row with a durable task as its timer, so it
> survives hub restarts. A project's are listed on its page and made or
> edited in a form there; Blip's are still made by asking Blip and listed
> on the home page.
>
> Step 4 let Blip make, list and cancel a project's schedules too. The
> threads a schedule Blip made starts or wakes count as Blip's work, so
> Blip hears how they end. The schedule also remembers whether you asked
> for it or Blip set it up on its own, which decides whether the activity
> log credits its firings to a schedule or to Blip's follow-up.

**Thread.** One agent conversation inside a project, run on the hub by the
durable harness. Its tools take a `machine` argument, so one thread can run
a command on mm1, look at a screenshot on mp1, and write a note to the
project's context files on the hub. You start threads; so can Blip and
schedules, but threads can't start other threads. Every thread belongs to
a project.

Threads don't carry anything about the owner in their prompts. When a
thread needs the owner's judgement or preferences, it calls `ask_blip`
with a specific question. Blip answers from what it knows when it can do
so confidently. Only when it can't does it ask you, as a message of its
own in its conversation, and pass your answer back. The thread waits for
the answer durably, and shows as waiting until it arrives.

> Status: step 4 built `ask_blip` (`docs/plans/step-4-blip-as-coordinator.md`,
> section 4). A question is a row, and the thread's tool call waits on it
> as a durable task, so neither a hub restart nor a long wait loses it.
> The question reaches Blip as a message in its conversation. Blip either
> answers it with `answer_question` or asks you with `ask_owner`, and
> while Blip has it the thread shows "Asking Blip", a state of its own,
> so it doesn't look like a thread at work. If Blip's run ends without
> doing either, the hub passes the question to you in the thread's own
> words and says so in Blip's conversation. You answer from the question's
> card in Blip's panel, from the home page, or from the thread page, where
> the answer box takes the composer's place. Your answer goes straight to
> the thread by code, never through the model, with Blip's wording of the
> question when Blip asked in its own words; Blip sees it afterwards and
> may remember it. Blip can answer a question it passed to you only in a
> run you typed into (relaying what you said in chat), so its guess is
> never recorded as your answer. Stopping the thread withdraws its
> question.

**Blip.** One conversation outside all projects, and your general-purpose
assistant. Blip:

- keeps a personal memory about you: who you are, what you care about, how
  you like things done
- handles one-off requests itself, including running tools on any machine
  ("is Codex installed on mm1?" needs no project)
- can see every project and thread, start projects and threads, message
  them, stop them, and read and write project context
- has its own set of enabled skills
- answers threads' `ask_blip` questions, or brings them to you
- follows along: it hears when threads finish, fail, or are waiting on you
- speaks up about what you need to know, and follows up on threads that
  have gone quiet without being resolved (when ambient mode is on)
- keeps a log of everything it did and who asked (you, a thread, a
  schedule, its own follow-up)

> Status: step 4 gave Blip tools over every project and thread
> (`docs/plans/step-4-blip-as-coordinator.md`, section 5): list and read
> projects and threads, start a project, start a thread, message and
> stop threads, list, read, write and edit any project's context files,
> manage a project's schedules, and turn skills on or off for a project.
> Blip's own skill set stays yours to change. Two limits hold in code:
>
> - A run that carries a thread's question and that you haven't typed
>   into can't start, wake, stop or schedule threads, or change a
>   project. A question is a thread talking to Blip, and threads can't
>   start work. Thread updates carry no such limit, since Blip acts on
>   them to carry out what you asked.
> - Between two of your messages, Blip can start or message threads at
>   most 10 times on its own (`unattended_limit`), so Blip and a thread
>   can't keep waking each other. What it does in a run you typed into
>   doesn't count.
> - Blip sets up a project's schedule only when you ask in your message,
>   since each firing starts or wakes a thread.
>
> The activity log is a table with one row per tool call Blip makes,
> reads included, and one row for each message Blip sent you from a run
> nobody typed into (a thread update, a question, a schedule). Each row
> says who asked. You asked for runs you typed into or answered a
> question in. A schedule asked when it is one you asked Blip for
> (whether it repeats or not). Blip's follow-up covers schedules Blip made
> on its own and runs a thread update started, naming the thread it
> followed up on. Step 5 added two more follow-ups: runs started by an
> ambient mode digest or daily review are logged as "Blip's follow-up on
> the digest" and "Blip's follow-up on the daily review". A thread asked only when Blip handled that thread's
> question, and each call is credited to the thread whose question it
> was. The log is on the Activity page (`/activity`), filtered by who
> asked or to changes only.

## Keeping track

This is Blip's main job once there are many projects with several threads
running in each. It rests on two layers:

1. **Thread state, worked out by code, not by a model.** Each thread is in
   one of: running, asking Blip (its `ask_blip` question is with Blip),
   waiting on you (it asked a question and its run ended, or its
   `ask_blip` question was passed to you), failed, done and unread, idle,
   or quiet (a run that was stopped part way, left alone for a while).
   These are cheap to compute and drive the UI directly.
2. **Blip's judgement on top.** State changes reach Blip as signals in its
   conversation, the way node reports did before step 1 removed them.
   Blip decides what is worth telling you, and in what words.

Waking Blip's model on every state change would spend your ChatGPT plan
fast, so signals are filtered:

- **Quiet** (today's behaviour): Blip hears about work it started itself,
  `ask_blip` questions, and failures and questions in threads you started.
- **Ambient**: Blip also gets a periodic digest of everything that changed,
  and a daily review of quiet threads to follow up on.

The home page shows the state layer directly ("needs you", "running",
"recently finished") whether or not Blip says anything.

> Status: step 4 built both layers in quiet mode
> (`docs/plans/step-4-blip-as-coordinator.md`, sections 2 and 3).
>
> A thread's state is derived when it is read, from facts the hub stores
> as they happen: how and when its last run ended, whether that answer
> ended with a question (its last paragraph ends in `?`), when you last
> had its page open, whether you resolved it, whether it is busy, and its
> open questions. Nothing stores the state itself. The rules, first match
> wins: a question with you is waiting on you; a busy thread whose
> question Blip has is asking Blip; a busy thread is running; a resolved
> thread is idle; a failed run is failed; a finished run that asked is
> waiting on you; a finished run you haven't looked at since is unread
> ("Finished"); a stopped run, or one with no recorded end, left alone
> for 72 hours (`quiet_after_hours`) is quiet; anything else is idle
> ("Done" after a finished run). Unread has no time limit: finished work
> stays listed until you open it or mark it read.
>
> Quiet means work left unfinished in substance. A run that finished
> cleanly, asked nothing and has been read is done, however old, so it
> never drifts into "Gone quiet". Step 5's daily review of quiet threads
> builds on this meaning, so it won't spend model runs following up on
> finished work.
>
> Resolve is how you say a thread is finished with: the thread page and
> the home page can mark a thread resolved, which makes it idle. Any new
> message reopens it.
>
> Quiet mode's filter, decided by code on each settled run: Blip hears
> how every run it started or messaged ends (unless it was stopped),
> every `ask_blip` question, and failures and end-of-run questions in
> your threads. Whose a thread is comes from the messages the run
> answered, not from who started the thread. Threads a project schedule
> starts or wakes belong to whoever made the schedule: your schedules
> make your threads, and schedules Blip made make Blip's. Updates that
> arrive while Blip is busy merge into one queued message, and questions
> into another, so a burst wakes Blip's model once. A question never
> shares a message with an update. Ambient mode (digests, the daily
> review, the setting) is step 5; the filter takes the mode as an
> argument, so it plugs in there.

> Status: step 5 built ambient mode (`docs/plans/step-5-ambient-mode.md`).
>
> The setting is in Settings, under Ambient mode: a switch, off by
> default, and how often the digest comes (every hour, 3 hours or 6
> hours; 3 by default). The section shows whenever Blip can think, and
> while ambient mode is on even when Blip can't, so it can always be
> turned off. The
> setting lives in the hub's database rather than the settings file, so
> turning it on or off and starting or stopping its two timers happen in
> one step. Off, Blip hears exactly what quiet mode lets through, its
> prompt and tools are step 4's, and nothing runs on a timer.
>
> While it is on, the hub collects what changed that Blip didn't already
> hear about: runs of your threads that finished, schedules that stopped
> after an error, context files written by threads or by you, projects
> and threads you started, name and Purpose edits, and threads you
> resolved. At each interval the digest timer reads that list. Only a
> finished run you haven't opened yet, or a stopped schedule, can send a
> digest. Everything else rides along in compact form, and with nothing
> new there is no message and no model run; the changes you've seen or
> made yourself wait for the next digest that has something new. The
> list keeps one entry per thread, schedule, project or file, the newest,
> so it stays small however long digests skip. A schedule you saved again
> after it stopped is no longer news. A digest is one message in Blip's
> conversation, at most 20 new and 15 other changes. The changes it
> carries are cleared once Blip has answered it, and wait for the next
> digest if Blip's run failed, so none is reported twice or lost.
>
> The daily review comes around 09:00 at your browser's UTC offset,
> which Settings sends with every Save. It lists threads that are
> stopped, failed or waiting on you and that nobody has touched for 72
> hours (`quiet_after_hours`), at most 10, oldest first. Each is listed
> once per quiet spell, and again after a week if it is still untouched.
> Finished threads you haven't read stay out of it, since the digest
> covers them. Home marks the threads a review raised. Like a schedule,
> the review is a fixed 24-hour repeat, so it drifts an hour at daylight
> saving changes until you next save Settings.
>
> Blip reads each digest or review and tells you what's worth knowing in
> its own conversation, which makes a speech bubble when its panel is
> closed. In a run a digest or review started, Blip can read anything,
> check machines and update its memory, but it can't start, message or
> stop threads, or change projects or schedules, until you answer. So a
> digest can't cause the work that would fill the next one. Blip has no
> tool to resolve a thread; the review tells you where the Resolve button
> is. Blip's panel shows each digest or review as one collapsed line that
> opens to its items.
>
> When nothing is worth saying, Blip answers `[nothing to tell]`. That
> makes no bubble and no activity row, and draws nothing in the panel
> beyond the digest's own line: what Blip said and checked on the way is
> hidden too, and only its final answer in such a run can make a bubble.
>
> Blip's conversation is cleared only when you press Fresh context, so
> digests would otherwise make every later request bigger. Once a later
> run starts, an earlier digest or review reaches the model as a
> one-line note with its tool results cut short, and one Blip answered
> with `[nothing to tell]` is left out entirely.
>
> Each digest and review is a run on your ChatGPT plan, so both obey the
> consent for scheduled work in Settings: while schedules can't use your
> plan, they skip, and Settings and Home say so. They also skip while
> Blip isn't signed in to ChatGPT, since its run could only fail. A
> digest or review also skips while the last one still waits for Blip.
> A review whose run failed, or that you withdraw from Blip's inbox,
> clears its threads' marks so the next review lists them again.
> Turning ambient mode off stops both timers, drops what was waiting,
> and takes back a digest or review Blip hasn't started on.

## Hub and nodes

> Status: step 1 built this section's machine tools and removed what it
> says goes away (`docs/plans/step-1-machine-tools.md`). The node's
> operation layer is now `PhotonNode.Ops`, run by `PhotonNode.Executor`;
> the paragraph below describes the code before step 1.
>
> Status: step 2 built threads and their working directories
> (`docs/plans/step-2-projects-and-threads.md`). A thread is a
> conversation under the `"thread"` profile, and its machine tools work in
> `<node workspace>/<project slug>`, which the node creates the first time
> a command runs there. That is a protocol change: nodes join with the
> capability `ops:2` instead of `ops:1`, and the hub sends no operations
> to a node without it, so every node needs reinstalling once.

Today each node runs a whole agent loop (`PhotonNode.Harness`: session
state machine, context, tools, its own log) and calls the model through the
hub's relay. The hub mirrors each session's log into its own tables
(`Photon.NodeSessions`). Blip runs a second loop on the hub
(`Photon.Durable`).

After this change there is one loop, on the hub:

- **Blip and threads are durable conversations**, under the `"assistant"`
  and a new `"thread"` profile. The durable harness already supports many
  conversations; Blip is just the only one today.
- **Machine tools are shared.** Blip and threads use the same tools
  (shell, view_image), each taking a `machine` argument. Only the
  surrounding tools differ: Blip's work across projects, a thread's work
  within one.
- **Nodes are executors.** The hub sends `op.start` (an operation ID, its
  kind and arguments) and `op.cancel`; the node runs the operation and sends
  snapshots back until it finishes. This is the existing
  `PhotonNode.Harness.Ops` layer, which already reports snapshots, resends
  the latest on request, and is idempotent per operation ID: what a hub
  needs to pick an operation back up after a disconnect.
- **A tool call on an offline machine** waits durably for the machine to
  come back, up to a limit, then fails with a plain message the model can
  act on ("mm1 has been offline for 10 minutes").
- **Working directory.** Each project gets a directory per machine, by
  default `<node workspace>/<project slug>`, created on first use. Blip
  works in the node's workspace.
- **Skills** are read from the hub. Loading one puts its instructions in the
  conversation.

> Status: step 3 built skills on the hub. Nothing about them reaches a
> node: the hub stores them, lists them in prompts and loads them inside
> the conversation's own commit.

What goes away: the node's session state machine, coordinator, context
builder, log store, skills and model requests; the hub's model relay;
`Photon.NodeSessions` and its mirror; Blip's `run_on_node` family of tools;
the `NodeSync` TLA+ spec and the session parts of `Coordinator`. What
stays: node keys and enrolment, install and update, the operation
processes, the tool translators (moved to the hub).

## UI

**Sidebar**

- Blip's home ("needs you")
- **Projects**, with a "+" to start a project. Each project lists its
  threads, with a "+" on the row to start a thread in it.
- Machines, with the online count, linking to the Nodes page
- Settings

The "+" next to today's "Machines" heading goes away; it only duplicated
the Nodes link.

**Home.** What needs you, across all projects: threads waiting on you
(including questions Blip passed along), failures, finished work you
haven't looked at, what's running, what's gone quiet. This replaces
today's overview.

> Status: step 4 built the home page at `/`
> (`docs/plans/step-4-blip-as-coordinator.md`, section 10.3): Needs you
> (questions with an answer box each, threads whose last answer asked,
> failed and finished threads, with Mark all read), Running (threads
> asking Blip after the ones at work), Gone quiet, and Blip's schedules.
> It dropped the overview's machine cards. The sidebar marks each thread
> with its state, counts the threads that need you next to Home, and has
> an Activity entry for the activity log.

**Project page.** Purpose, context files, skills, threads, schedules.

**Thread page.** The conversation, as today's session page shows it, with
the machine named on each tool call.

**Blip panel.** Stays as it is, floating over every page. It knows which
project or thread is on screen (as `Assistant.Page` did for node sessions
until step 1 removed them), so "what's left here?" means the thing you're
looking at.

## Build order

Each step leaves a working app.

> Status: steps 1, 2 and 3 are built (`docs/plans/step-1-machine-tools.md`,
> `docs/plans/step-2-projects-and-threads.md`,
> `docs/plans/step-3-skills-and-schedules.md`). Step 2 left out, for
> later: deleting or archiving projects and threads, moving threads
> (context files can be deleted), and a model per thread. Blip sees
> projects and threads only through a note about the page on screen until
> step 4 gives it tools.
>
> Step 3 put skills and schedules in the project page's second column.
> It left out, for later: skills scoped to machines and skills with
> scripts or other files; updating an installed skill from its source,
> and exporting one as a SKILL.md; pausing a schedule (delete it and make
> it again); calendar rules such as "weekdays at 9"; and repeats that
> follow your time zone across daylight saving changes (a repeat is a
> fixed interval, so it drifts by an hour). Blip's schedule tools touch
> only its own schedules until step 4. Asked for recurring work in a
> project, Blip tells you to add it with New schedule on the project's
> page.
>
> Step 4 (`docs/plans/step-4-blip-as-coordinator.md`) built Blip as
> coordinator: its tools over projects and threads, `ask_blip`, thread
> state and the signals quiet mode lets through, the home page, and the
> activity log. Blip's schedule tools now reach project schedules too. It
> left out, for later: ambient mode (step 5), Blip resolving, archiving
> or deleting threads and deleting projects, and pruning the activity
> log. Every flow can be tried with `PHOTON_MOCK_MODEL=1`; section 8.3 of
> the plan walks through it.
>
> Step 5 (`docs/plans/step-5-ambient-mode.md`) built ambient mode: the
> setting, the digest, the daily review, and Blip's report-only runs on
> them (see "Keeping track"). With it all five steps are built. Every
> flow can be tried with `PHOTON_MOCK_MODEL=1`, and
> `PHOTON_QUIET_AFTER_HOURS=0` makes a stopped thread count as quiet at
> once so the review has something to show; section 8.4 of the plan walks
> through it. With the scripted model, Settings has "Send a digest now"
> and "Run the review now" buttons for trying it.

1. **Machine tools on the hub.** Make nodes executors and give Blip shell
   and view_image on any machine, replacing `run_on_node` and node
   sessions. Blip answers one-off requests itself from here on.
2. **Projects and threads.** Purpose, context files and their tools, the
   `"thread"` profile, the sidebar grouping, new project and new thread.
3. **Skills on the hub**: writing and installing them in the app, and
   turning them on per project and for Blip. **Schedules in projects**:
   today's routines can belong to a project and wake a thread there; Blip
   keeps its own for things outside projects, like a morning review.
4. **Blip as coordinator.** Tools over projects and threads, `ask_blip`,
   thread signals to Blip, the home page, the activity log.
5. **Ambient mode.** Digests, the daily review of quiet threads, the
   setting to turn it on.

Left for later, with the door left open:

- a Discord client for Blip, so you can talk to it from your phone
- watchers on outside services (GitHub, Slack) that post into threads the
  way schedules do
- skills scoped to particular machines, and skills with scripts
- tagging @Blip inside a thread to bring it in there
- collaborators on projects
- approvals for shell commands (see "Open questions")
- a model per thread or project
- Blip resolving, archiving or deleting threads
- deleting or archiving projects, and moving threads between them
- pruning the activity log
- schedules and the daily review following your time zone across
  daylight saving changes
- calendar rules for schedules, such as "weekdays at 9"
- pausing a schedule
- digests of machine changes, such as a node going offline
- quiet hours for digests
- a review time other than 09:00
- threads sharing a directory (see "Open questions")

## Open questions

- **Threads sharing a directory.** Two threads in one project working on
  the same machine share its project directory, so they can trip over each
  other's changes. T3 Code gives each thread its own git worktree; Photon
  projects aren't always repos. Shared for now, until it causes trouble.
- **Approvals.** Threads and Blip run shell commands on your machines
  without asking, as Blip does today.
- **Model per thread.** Every conversation uses the model in Settings for
  now; choosing one per thread or project can come later.

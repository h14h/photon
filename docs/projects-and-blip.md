# Projects, threads and Blip

Status: draft for discussion, 2026-10-05. Nothing here is built yet.

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

**Project.** A context for some body of work, not necessarily code. It has:

- an owner (you, for now)
- a **Purpose** (required): a few sentences on what the project is for
- **context files**: freeform Markdown kept on the hub (notes, goals,
  research, decisions), read and written by you and by its threads
- the **skills** enabled for it
- **threads**
- **schedules**: prompts that start or wake a thread at set times

A project doesn't belong to a machine. Its threads can use any machine.

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

## Keeping track

This is Blip's main job once there are many projects with several threads
running in each. It rests on two layers:

1. **Thread state, worked out by code, not by a model.** Each thread is in
   one of: running, waiting on you (it asked a question and its run
   ended, or its `ask_blip` question was passed to you), failed, done and
   unread, idle, or quiet (unresolved and untouched for a while). These are
   cheap to compute and drive the UI directly.
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

## Hub and nodes

> Status: step 1 built this section's machine tools and removed what it
> says goes away (`docs/plans/step-1-machine-tools.md`). The node's
> operation layer is now `PhotonNode.Ops`, run by `PhotonNode.Executor`;
> the paragraph below describes the code before step 1.

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

**Project page.** Purpose, context files, skills, threads, schedules.

**Thread page.** The conversation, as today's session page shows it, with
the machine named on each tool call.

**Blip panel.** Stays as it is, floating over every page. It knows which
project or thread is on screen (as `Assistant.Page` did for node sessions
until step 1 removed them), so "what's left here?" means the thing you're
looking at.

## Build order

Each step leaves a working app.

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

Later, with the door left open:

- a Discord client for Blip, so you can talk to it from your phone
- watchers on outside services (GitHub, Slack) that post into threads the
  way schedules do
- skills scoped to particular machines, and skills with scripts
- tagging @Blip inside a thread to bring it in there
- collaborators on projects

## Open questions

- **Threads sharing a directory.** Two threads in one project working on
  the same machine share its project directory, so they can trip over each
  other's changes. T3 Code gives each thread its own git worktree; Photon
  projects aren't always repos. Shared for now, until it causes trouble.
- **Approvals.** Threads and Blip run shell commands on your machines
  without asking, as Blip does today.
- **Model per thread.** Every conversation uses the model in Settings for
  now; choosing one per thread or project can come later.

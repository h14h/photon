# Photon architecture by OTP layer

This maps every module in `apps/core`, `apps/node` and `apps/hub` onto the
layers from *Designing Elixir Systems with OTP* (Gray and Tate):

- **data**: structs, schemas and the shapes that move between layers
- **functional core**: pure functions over that data
- **boundary**: the API callers use, plus the adapters that touch files,
  network, database, environment and other processes
- **lifecycle**: applications, supervisors, child specs, boot work
- **workers**: processes that do the concurrent work

Tests are the book's sixth layer; test support modules get a short table at
the end of the module map.

The module map and the supervision trees describe the code after step 3 of
`docs/projects-and-blip.md` (2026-10-06). Step 1 made nodes executors for
the hub's operations, gave Blip machine tools to run commands on them,
and removed node sessions, the model relay and the node's agent loop
(`docs/plans/step-1-machine-tools.md`). Step 2 added projects, their
context files, and threads that work in a project's folder on any machine
(`docs/plans/step-2-projects-and-threads.md`). Step 3 added skills,
which Blip and threads load when a task calls for them, and moved
schedules into projects (`docs/plans/step-3-skills-and-schedules.md`).
The hotspots and the refactor log below were written against the
`elixir-harness` worktree as of 2026-10-03, and their line numbers refer
to that snapshot. Many of the modules they name were removed in step 1;
the step 1, 2 and 3 entries at the end of the refactor log say what each
step changed.

Purity column:

- `pure`: deterministic, no side effects
- `pure*`: no I/O, but reads the clock or random bytes (usually through
  `PhotonCore.ID.new/1`), so results aren't repeatable
- `does I/O`: files, network, database, OS environment, PubSub, ETS,
  registries, `:persistent_term`, or messages to other processes
- `is a process`: the module is the callback module of a process (GenServer,
  Supervisor, Slipstream client, channel, LiveView); it also does I/O unless
  noted

A module that spans layers lists its main layer first.

## Summary

The core app is a library: data, a functional core and one HTTP boundary
(the model client), with no processes of its own. It also holds what the
hub and nodes share about operations: the snapshot shape
(`PhotonCore.Operation`), the `op.*` messages (`Operation.Wire`) and the
output bounds (`Output`).

The node app runs the hub's operations and nothing else. One process,
`PhotonNode.Executor`, owns a journal of every operation on disk, starts
one worker per operation (`Ops.Shell` or `Ops.Job`), monitors them, and
forwards their snapshots to the hub connection. Its decisions are the pure
`Executor.Rules` and `Executor.Request`. The node has no model, no
sessions and no log of its own beyond the journal.

The hub's durable harness has a pure `Context` and `Schema` and an explicit
commit boundary (`Durable.Store` plus `Durable.Tx`); the scheduling policy
and the task kinds' decisions are pure modules. Blip's machine tools
(`Photon.MachineTools`) are durable tools that store each operation as a
row through `Photon.Machines` and park until its result arrives; the
rules for those rows are the pure `Machines.Rules`. `Photon.Machines` has
no process: the registry says which machines are connected, the rows hold
the state, the durable harness waits, and each node's channel is the
transport. No LiveView does I/O in `render/1`.

Projects and threads add no process either. A project and its context
files are rows (`Photon.Projects`), written in Store commits whose rules
are the pure `Projects.Rules`. A thread (`Photon.Threads`) is a durable
conversation under the `"thread"` profile with a row tying it to its
project; it shares Blip's machine tools, which run in the project's
folder on each machine (`<workspace>/<slug>`, through the profile's
optional `workdir/1`), and has four tools of its own for the context
files, which write inside the commit that records their result. Writes
are announced from inside their commit (`Durable.Tx.announce/3`) and
broadcast only after it. Blip's panel and a thread's page draw a
conversation with the same pieces (`Photon.Transcript`,
`PhotonWeb.ConversationComponents`, `PhotonWeb.ConversationView`).

Skills and schedules add no process either. A skill is a row, and each
place it is on (Blip, or one project) is an enablement row; the rules,
the SKILL.md reader and what a link means are pure (`Skills.Rules`,
`SkillMd`, `Source`), and only `Skills.Fetch` makes HTTP requests, in
the install page's `start_async` task. Agents see the enabled skills in
their prompt (`Skills.Prompt`) and load one with `load_skill`, which
reads it inside the commit that records the result. A schedule is a row
plus a durable `"routine"` task (`Schedules.Routine`) that waits for its
next time; the task is only the timer, and every edit or delete replaces
or retires it in the commit that changes the row, so the step fence
keeps a firing from landing after its schedule changed. What a firing
does (start a thread, wake one, post to Blip, or skip) is the pure
`Schedules.Rules.fire/2`, decided inside the firing's commit.

## Module map

### apps/core (`:photon_core`)

| Module | Layer | Purity | Depends on |
| --- | --- | --- | --- |
| `PhotonCore` | namespace (docs; the Boundary root for the shared data and core) | pure | none |
| `PhotonCore.Message` | data (message format, constructors and readers) | pure | Jason |
| `PhotonCore.LLM.Error` | data (exception struct, `new/3` constructor) | pure | none |
| `PhotonCore.ID` | functional core (utility) | `encode/3` and `valid?/1` pure; `new/1` pure* (clock, `:crypto` RNG) | `:crypto` |
| `PhotonCore.LLM.SSE` | functional core | pure | none |
| `PhotonCore.LLM.Retry` | functional core (retry policy: retry or give up, backoff, jitter) | pure (randomness passed in) | `LLM.Error` |
| `PhotonCore.LLM.HTTPError` | functional core (a failed request's status and body as an `LLM.Error`; Sign in with ChatGPT's own codes said plainly) | pure | `LLM.Error`, Jason |
| `PhotonCore.LLM.Responses.Request` | functional core (Responses API body; messages as input items, tools in a namespace, reasoning items handed back) | pure | `Message`, Jason |
| `PhotonCore.LLM.Responses.Response` | data (the `%Response{}` stream token) and functional core (`feed/2` returns events, `finish/2`, `usage/1`) | pure (missing call IDs come from a function passed in) | `SSE`, `HTTPError`, `LLM.Error`, `Message`, Jason |
| `PhotonCore.Operation` | data (operation snapshot, shared by the node and the hub) with pure `new/5`, `advance/3`, `fail/2`, `terminal?/1` and `statuses/0` | pure | none |
| `PhotonCore.Operation.Wire` | functional core (the `op.*` messages between the hub and a node: builders and parsers, which ignore unknown fields) | pure | `ID`, `Operation` |
| `PhotonCore.Output` | functional core (`bound/3`, `truncated/5`) | pure | none |
| `PhotonCore.LLM.Mock` | boundary (scripted provider adapter and script behaviour; the hub's `Assistant.MockScript` is a script) | pure*; calls the caller's `on_event` | `Message`, `LLM.Error`, `ID`, Jason |
| `PhotonCore.LLM.Responses` | boundary (HTTP adapter for the Responses API, with a Sign in with ChatGPT token) | `stream/3` does I/O (HTTP), feeds `Response`, calls `on_event`, mints missing call IDs | Req, `Request`, `Response`, `HTTPError`, `LLM.Error` |
| `PhotonCore.LLM` | boundary (API: types, dispatch to `"chatgpt"` or `"mock"`, retries) | does I/O (`Process.sleep` between attempts) | `Responses`, `Mock`, `Retry`, `LLM.Error` |

### apps/node (`:photon_node`)

| Module | Layer | Purity | Depends on |
| --- | --- | --- | --- |
| `PhotonNode.Application` | lifecycle | is a process (app supervisor); runs `CLI.boot/0` first when packaged | `CLI`, `PhotonNode` |
| `PhotonNode` | lifecycle (node supervisor, with its lifecycle plan and the protocol summary in the moduledoc: the `ops:2` capability) and global config accessor | is a process; `init/1` writes `:persistent_term` and creates the ops dir and the workspace | `Config`, `Ops`, `Executor`, `Connection`, Registry, DynamicSupervisor |
| `PhotonNode.CLI` | boundary (executable entry point) | does I/O (stdout/stderr, `System.halt`, logger config) | Logger |
| `PhotonNode.Config` | data (struct with `t/0`) and boundary (`new/1`) | `new/1`, `hostname/0` do I/O (opts, app env, OS env, hostname); `ops_dir/1` pure | none |
| `PhotonNode.Connection` | boundary and worker (the hub link; joins with the capability `ops:2`) | is a process (Slipstream); hands `op.start`, `op.cancel` and `op.ack` to the executor and pushes its journaled snapshots after each join; `snapshot/1` and `output/3` (`Executor.Link`) are its client functions, plain sends dropped while it isn't joined | Slipstream, `Executor`, `Config`, `PhotonCore.Operation.Wire` |
| `PhotonNode.Executor` | boundary (the node's API for the hub's operations: `start/1`, `cancel/1`, `ack/1`, `snapshots/0`; one server for all of them, which owns the journal, implements `Ops.Owner`, monitors the op processes it starts and applies `Executor.Rules`; step 1, section 2.3's node rules) | is a process; journal files through `Journal`, starts op processes, forwards snapshots through `Link`, a daily `send_after` sweep | `Journal`, `Request`, `Rules`, `Link`, `Ops`, `Ops.Owner`, `Ops.Env`, `Config`, `PhotonCore.Operation` |
| `PhotonNode.Executor.Journal` | boundary helper (each op's `op.json`: fsynced write by rename, read, list, forget on `op.ack`, the 7-day sweep of output; no process, called only from the executor) | does I/O (files, fsync, `sync` on the directory on Linux) | Jason |
| `PhotonNode.Executor.Request` | functional core (judges an `op.start` into an operation; builds the snapshots for ops the node won't run: rejected, lost, never started, unrecorded, unreadable, failed; `fit/2` cuts a snapshot to the 6 MB frame budget) | pure | `PhotonCore.Operation`, `PhotonCore.Output`, Jason |
| `PhotonNode.Executor.Rules` | functional core (what `op.start`, the start-up scan and an op process's exit mean: run, resend, resume, lost, restart or fail, each with the journal's cancel flag) | pure | `PhotonCore.Operation` |
| `PhotonNode.Executor.Link` | contract (behaviour for the hub link: `snapshot/1`, `output/3`; dispatches to the config's `:link`, `Connection` by default) | reads `PhotonNode.config/0` | `Config` |
| `PhotonNode.Ops` | boundary (API over operation processes, each started for an `Ops.Owner`: `add/2`, `cancel/1`, `running?/1`; owns their `:resend` and `:cancel` messages and the via tuples into `PhotonNode.OpRegistry`) | does I/O (Registry, DynamicSupervisor, sends) | `Ops.Shell`, `Ops.Job`, `Ops.ViewImage`, `Ops.Owner` |
| `PhotonNode.Ops.Owner` | contract (behaviour for whatever owns operations: `checkpoint/2`, `report/2`, `output/4`; the executor, or a test owner) | pure dispatch on the `{module, owner_id}` pair | `PhotonCore.Operation` |
| `PhotonNode.Ops.Shell` | worker (one per command; creates the command's working directory before the `process` checkpoint, or fails the op without running it) | is a process; Port, files (`pid`, `exit`, and the `canceled`, `stopped` and `unstarted` markers), `/bin/sh` kill (polled with `send_after`, not slept on), live output | `Ops.Env`, `Ops`, `Ops.Owner`, `PhotonCore.Operation`, `PhotonCore.Output` |
| `PhotonNode.Ops.Job` | worker (one-shot operations, behaviour for jobs) | is a process; runs `job.run/1` once and reports | `Ops`, `Ops.Owner`, `PhotonCore.Operation` |
| `PhotonNode.Ops.ViewImage` | boundary (job: reads the image file) | does I/O (file) | `Ops.Image`, `PhotonCore.Operation`, `Ops.Job` |
| `PhotonNode.Ops.Image` | functional core (image formats and sizes from a file's header) | pure | none |
| `PhotonNode.Ops.Env` | boundary (OS environment for commands) | `shell/0` and `overrides/0` read the environment; `overrides/1` with an explicit env and `to_port/1` are pure | none |
| `Mix.Tasks.Photon.Package` | build tooling, outside the runtime layers | does I/O (`System.cmd`, an HTTP HEAD, files) | Burrito, Req, `QuietStream` |
| `Mix.Tasks.Photon.Package.QuietStream` | build tooling (Collectable) | does I/O (`IO.write`) | none |

### apps/hub (`:photon`), domain

| Module | Layer | Purity | Depends on |
| --- | --- | --- | --- |
| `Photon` | namespace (docs only: the contexts and where each layer lives) | pure | none |
| `Photon.Application` | lifecycle (the lifecycle plan is in its moduledoc) | is a process (app supervisor); `start/2` may generate and write the GUI password before the tree starts | `Auth`, `NodeKeys` (the built-in node's key), `Paths`, every child it starts |
| `Photon.Repo` | boundary (SQLite) | is a process (connection pool) | Ecto, ecto_sqlite3 |
| `Photon.Paths` | boundary (locations) | reads app env | none |
| `Photon.Events` | boundary (the hub's PubSub announcements: hints to re-read committed state; a failed broadcast or subscription is logged, not raised) | does I/O (PubSub) | Phoenix.PubSub |
| **Durable harness** | | | |
| `Photon.Durable` | boundary (harness API: reads, submit, abort, reset, subscriptions, which conversations are busy (`busy/1`, `busy_in_profile/1`), a conversation's last entry of a kind; moduledoc lists the layers behind it) | does I/O; reads go through `Queries`, no `%Tx{}` outside a commit | `Store`, `Tx`, `Queries`, `Inbox`, `Repo`, `Events`, durable schemas |
| `Photon.Durable.Supervisor` | lifecycle (task supervisor, Store, Scheduler; `:one_for_one`, plan in its moduledoc; `children/0` is what tests start) | is a process | the three children |
| `Photon.Durable.Store` | boundary (the commit line; a lock with no state, which its moduledoc says) | is a process; runs `Tx.run/1`, broadcasts what `Changes` says (the commit's `Tx.announce/3` messages too, after it commits), notifies `Scheduler` | `Tx`, `Changes`, `Scheduler`, `Events` |
| `Photon.Durable.Tx` | boundary (write operations inside a commit; owns the commit's change list, including the announcements `announce/3` adds for the Store to broadcast after the commit) | does I/O (Repo); keeps the change list in the Store's process dictionary for one commit; a write through a `Tx` that isn't the open commit raises | `Repo`, `Queries`, durable schemas, `PhotonCore.ID`, Jason |
| `Photon.Durable.Queries` | functional core (the reads, as Ecto queries) | pure (builds queries; callers run them) | Ecto.Query, durable schemas |
| `Photon.Durable.Changes` | functional core (what a commit announces: its `durable:*` messages and its `Tx.announce/3` messages in commit order) | pure | durable schemas |
| `Photon.Durable.Runtime` | boundary (step-commit helper around a data struct) | does I/O through `Store` | `Store`, `Tx` |
| `Photon.Durable.Scheduler` | boundary (the server that runs tasks: reads facts, applies `Policy`'s decisions in per-task commits, tracks steps) | is a process; DB reads, commits, starts step tasks, timer | `Durable`, `Policy`, `Queries`, `Runtime`, `Store`, `Tx`, `Repo`, `Durable.TaskSupervisor` |
| `Photon.Durable.Policy` | functional core (the scheduler's rules: stop, wake, start, fail, timer) | pure | `TaskRecord` |
| `Photon.Durable.Inbox` | functional core (submission rules: dedupe, queue, start a run, next input) | pure | `Submission`, `Message` |
| `Photon.Durable.TaskKind` | behaviour (contract for task kinds) | pure | `Runtime`, `TaskRecord`, `Tx` (types only) |
| `Photon.Durable.Profile` | behaviour (contract; optional `workdir/1`: the directory under each machine's workspace that the conversation's tools work in) | pure | `Conversation` (types only) |
| `Photon.Durable.Tool` | behaviour with helpers (`spec/1`; `replay/1` loads the module) | pure apart from code loading | `ToolAPI`, `Durable.implements?/3` |
| `Photon.Durable.ToolAPI` | boundary (capability handed to tools; data struct with `new/1`, and `new/2` with the profile's `workdir`) | does I/O (PubSub, commits) | `Durable` |
| `Photon.Durable.Generation` | worker logic (task kind): reads the conversation, calls the model, commits | does I/O (DB, model HTTP, PubSub) | `Durable`, `Turn`, `Runtime`, `Tx`, `PhotonCore.LLM` |
| `Photon.Durable.Turn` | functional core (a generation's request, outcome, entries, settlements, transitions, usage, live events) | pure | `Context`, `Tool`, `Message`, `PhotonCore.LLM` (types) |
| `Photon.Durable.ToolTask` | worker logic (task kind): finds the tool, runs it with the profile's `workdir/1` in its API, commits; a raise in `execute/2` or `resume/2` is rescued and recorded with the tool's `on_interrupt/2` in the same commit | does I/O | `Durable`, `ToolCall`, `Tool`, `ToolAPI`, `Runtime`, `Tx` |
| `Photon.Durable.ToolCall` | functional core (whether a call runs, its result entry, its transitions) | pure | `Schema`, `Message` |
| `Photon.Durable.Context` | functional core (model input from the transcript; tool results from earlier runs shortened: images dropped, long text cut around a pointer to the full output) | pure | `Entry`, `Message`, `Output` |
| `Photon.Durable.Schema` | functional core | pure | none |
| `Photon.Durable.Conversation` | data (Ecto schema, `t/0`) | pure | Ecto |
| `Photon.Durable.Entry` | data | pure | Ecto |
| `Photon.Durable.Doc` | data | pure | Ecto |
| `Photon.Durable.Signal` | data | pure | Ecto |
| `Photon.Durable.Submission` | data (plus `background?/1`: input from a schedule, which Blip's Stop keeps) | pure | Ecto |
| `Photon.Durable.TaskRecord` | data (plus `terminal?/1`) | pure | Ecto |
| **Assistant** | | | |
| `Photon.Assistant` | boundary (the assistant's API, which the web pages use, and its profile; its tools are its own five plus `MachineTools.tools/0`; `page_at/1` makes the page the user has open, and `send/2` sends a message with the page's facts read fresh; `schedules/0` and `cancel_schedule/1` are Blip's own schedules through `Photon.Schedules`; `stop/0` keeps scheduled prompts (`Submission.background?/1`)) | does I/O (docs, settings file, clock, projects, threads, skills and schedules); `conversation_id/0` may commit | `Durable`, `Settings`, `ChatGPT`, `Prompt`, `Memory`, `Page`, `MachineTools` (`tools/0`), `Projects`, `Threads`, `Skills` (`enabled(:blip)` for the prompt), `Schedules`, `Transcript`, `Assistant.Tools.*` |
| `Photon.Assistant.Prompt` | functional core (system prompt from settings, memory, time and Blip's enabled skills; Blip's voice; the shell lines from `MachineTools.Guide`; the line about page notes; the schedule line saying Blip's schedules post to its own conversation) | pure | `Memory`, `MachineTools.Guide`, `Skills.Prompt` |
| `Photon.Assistant.Page` | functional core (the page the user has open under Blip: what a path is about (`at/1`), the page and its chip's label for a project, a file or a thread, and the bounded note the model sees in front of a message) | pure | none |
| `Photon.Assistant.Memory` | functional core (editing the memory text) | pure | none |
| `Photon.Assistant.Notice` | functional core (what Blip says unasked while its panel is closed: its own answers and failures) | pure | `Entry`, `Message`, `Transcript` |
| `Photon.Assistant.MockScript` | functional core (mock model script: the machine phrasings from `MachineTools.MockPhrases`, the skill phrasings from `Skills.MockPhrases`, memory, schedules and `here`; matches the last text part of the message) | pure* | `LLM.Mock`, `Message`, `MachineTools.MockPhrases`, `Skills.MockPhrases` |
| `Photon.Assistant.Tools.UpdateMemory` | boundary (tool) | does I/O (commit); the editing is `Memory.edit/3` | `Durable`, `Memory` |
| `Photon.Assistant.Tools.Schedule` | boundary (tool: one of Blip's own schedules or a project's, made with `Schedules.tool_schedule_tx/4` inside the commit that records the result, with the call's task ID as its request ID) | does I/O (a commit, clock) | `Schedules`, `ToolAPI` |
| `Photon.Assistant.Tools.ListSchedules` | boundary (tool: Blip's waiting schedules with their `sc_` IDs) | does I/O (DB) | `Assistant` |
| `Photon.Assistant.Tools.CancelSchedule` | boundary (tool: `Schedules.delete_tx/3` with the scope `:blip`, so a project's schedule reads as unknown) | does I/O (a commit) | `Schedules` |
| `Photon.Assistant.Tools.LoadSkill` | boundary (durable tool, `replay: :safe`: one of Blip's enabled skills, read with `Skills.load_tx/3` inside the commit that records the result) | does I/O (DB, in a commit) | `Skills`, `Skills.Prompt` |
| **Projects and threads** | | | |
| `Photon.Projects` | boundary (the projects context: projects, their slugs and their context files; every write is a Store commit that checks with `Rules` and announces with `Tx.announce/3`; `write_file_tx/5` and `edit_file_tx/6` are for thread tools inside their own commit; no process) | does I/O (DB through commits, PubSub through `Events`, clock, IDs) | `Durable`, `Tx`, `Repo`, `Events`, `Rules`, `Project`, `ContextFile` |
| `Photon.Projects.Project` | data (Ecto schema, table `projects`: name, purpose, the slug fixed at creation) | pure | Ecto |
| `Photon.Projects.ContextFile` | data (Ecto schema, table `project_files`: name, lookup key, content, version, who wrote it last) | pure | Ecto |
| `Photon.Projects.Rules` | functional core (purpose and name, the name made from the purpose, slugs and their uniqueness, file names and lookup keys, the content limit, the user's version check, a thread's exactly-once edit) | pure | `Project`, `ContextFile` |
| `Photon.Threads` | boundary (the threads context's API, which the pages use, and the `"thread"` profile: the model in Settings, the prompt with the project's enabled skills, the machine tools, four context-file tools and `load_skill`, and `workdir/1`, the project's slug; starting a thread makes the row, the conversation, the first message and the title task in one commit; `start_tx/4` and `send_tx/4` do it inside a caller's commit, with a `:source` and a `:request_id`, for schedules; `rename/2`; no process) | does I/O (DB, commits, settings file, clock) | `Durable`, `Tx`, `Repo`, `Projects`, `Settings`, `Skills`, `ChatGPT`, `MachineTools`, `Transcript`, `Thread`, `Rules`, `Prompt`, `Threads.Tools.*` |
| `Photon.Threads.Thread` | data (Ecto schema, table `threads`: the conversation's ID, its project, title and `active_at`) | pure | Ecto |
| `Photon.Threads.Rules` | functional core (a thread's first title from its first message, without a leading `[Scheduled] `, the request for the model's short title and what of its answer is one, a renamed title; how the tools list a project's files and head a read, naming who changed each file from the reading thread's side) | pure | `Message` |
| `Photon.Threads.Prompt` | functional core (a thread's system prompt from its project, the hour and the project's enabled skills, with the line saying what a `[Scheduled]` message is; nothing about the user) | pure | `MachineTools.Guide`, `Skills.Prompt` |
| `Photon.Threads.MockScript` | functional core (a thread's scripted model: the machine and skill phrasings, and `files`, `read`, `write` and `edit` for context files; strips a leading `[Scheduled] `) | pure* | `LLM.Mock`, `Message`, `MachineTools.MockPhrases`, `Skills.MockPhrases` |
| `Photon.Threads.MockTitle` | functional core (the scripted model's short title for a thread, from its first message) | pure* | `LLM.Mock`, `Message`, `Threads.Rules` |
| `Photon.Threads.Titling` | boundary (the `"thread_title"` task kind: once a thread's first run ends, one model request for a short title, stored unless the owner renamed the thread meanwhile; background, so the thread isn't busy) | does I/O (one model request, a commit) | `Durable`, `Runtime`, `ChatGPT`, `Settings`, `Threads`, `Rules`, `MockTitle` |
| `Photon.Threads.Tools.ListContextFiles`, `.ReadContextFile` | boundary (durable tools, `replay: :safe`: they change nothing) | does I/O (DB) | `Projects`, `Threads`, `Rules` |
| `Photon.Threads.Tools.WriteContextFile`, `.EditContextFile` | boundary (durable tools, `replay: :safe`: the write is `Projects.write_file_tx/5` or `edit_file_tx/6` inside the commit that records the result) | does I/O (a commit) | `Projects`, `Threads`, `Rules` |
| `Photon.Threads.Tools.LoadSkill` | boundary (durable tool, `replay: :safe`: one of the project's enabled skills, read with `Skills.load_tx/3` inside the commit that records the result) | does I/O (DB, in a commit) | `Skills`, `Skills.Prompt`, `Threads` |
| **Skills** | | | |
| `Photon.Skills` | boundary (the skills context: `list/0` with each skill's scopes, `get/1`, `get_by_name/1`, `create/1`, `install/2`, `update/3` against a version, `delete/1`, `enable/2` and `disable/2` per scope (`:blip` or `{:project, id}`, at most 30 each), `enabled/1` for the prompts, `load_tx/3` for the `load_skill` tools inside their commit, `read/1` for a pasted SKILL.md, `fetch/1` for a link; every write is a Store commit announced with `Tx.announce/3` on `"skills"`; no process) | does I/O (DB through commits, PubSub through `Events`, clock, IDs; HTTP through `Fetch`) | `Durable`, `Tx`, `Repo`, `Events`, `Projects`, `Rules`, `Source`, `Fetch`, `Skill`, `Enablement` |
| `Photon.Skills.Skill` | data (Ecto schema, table `skills`: name, description, instructions, version, origin, source URL, install notes, the files install left out) | pure | Ecto |
| `Photon.Skills.Enablement` | data (Ecto schema, table `skill_enablements`: one skill on in one scope; there is no "off" row) | pure | Ecto |
| `Photon.Skills.Rules` | functional core (the name, description and instructions limits, name suggestions, the 30-per-scope limit, the version check, which paths the instructions mention) | pure | none |
| `Photon.Skills.SkillMd` | functional core (reads a SKILL.md: the subset of YAML front matter SKILL.md files use, then the instructions) | pure | none |
| `Photon.Skills.Source` | functional core (what a link is, the GitHub API and raw URLs, which folders of a tree hold a SKILL.md, a downloaded SKILL.md and its folder to a candidate with its notes and left-out files, and the messages for each failure) | pure | `Rules`, `SkillMd` |
| `Photon.Skills.Fetch` | boundary (the only HTTP for skills: two GitHub API calls at most per link, then the SKILL.md downloads through `Task.async_stream/3`, six at a time; every request bounded in size, time and redirects) | does I/O (HTTP, in the caller's process) | Req, `Source` |
| `Photon.Skills.Prompt` | functional core (what agents see: the prompt's Skills section, the text a load returns with its left-out files line, the load's error, and the `load_skill` tool's name, description and parameters) | pure | `Skill` |
| `Photon.Skills.MockPhrases` | functional core (`skills` and `load skill <name>`, the phrasings both scripted models share) | pure* | `LLM.Mock`, `Message` |
| **Schedules** | | | |
| `Photon.Schedules` | boundary (the schedules context: `list/1` and `get/1` with each schedule's next time and state read from its task, `create/2`, `update/3` against a version, `delete/1`, `run_now/1`, `consent?/0`, the form's `new_params/1` and `edit_params/1`, and for Blip's tools `tool_schedule_tx/4`, `delete_tx/3` and `when_text/1`; every change writes the row and replaces or retires its routine task in one Store commit, announced on `"schedules"`; no process) | does I/O (DB through commits, PubSub through `Events`, settings file, clock, IDs) | `Durable`, `Tx`, `Repo`, `Events`, `Projects`, `Settings`, `Threads` (`start_tx/4`, `send_tx/4`), `Rules`, `Routine`, `Schedule` |
| `Photon.Schedules.Schedule` | data (Ecto schema, table `schedules`: the prompt, the first time and the interval, the project and thread it targets (neither for Blip's), the version, its routine task, and the last firing's time, outcome and thread) | pure | Ecto |
| `Photon.Schedules.Rules` | functional core (the form's and Blip's tool's input, the first time a new or edited schedule's task waits for (`arm/4`, from what the old task fired), the next time after a firing, where a schedule fires and what a firing does there from the consent and overlap facts (`fire/2`), the scheduled text, the skip notice and the request IDs) | pure (time passed in) | none |
| `Photon.Schedules.Routine` | worker logic (the `"routine"` task kind, moved from `Photon.Assistant.Routine`: a background task that waits for the schedule's next time, fires it in one fenced commit (`fire_tx/3`, shared with run-now) and waits again; `on_fail/3` records a failed task on its row) | does I/O (commits, clock, the settings file through `Schedules.consent?/0`) | `Durable`, `Runtime`, `Tx`, `Repo`, `Schedules`, `Threads`, `Rules`, `Schedule` |
| `Photon.Transcript` | functional core (what a conversation page shows, for Blip's panel and a thread's page: entry index without image data, what the user typed without the page note, the in-flight answer fold, running calls' output tails, a call's status and a machine call's line, Blip's mood, an image decoded from its entry) | pure | `Entry`, `Message` |
| **Machines and machine tools** | | | |
| `Photon.Machines` | boundary (the context for machines and their operations: the registry of connected nodes (`register/2`, `list/0`, `get/1`, `online?/1`, `subscribe/0`), status and roster, starting an op, the tool call's claim, cancel and give-up inside its commit, and the channel's join, push, snapshot and output, which push nothing to an outdated machine; `command/3` and `push_op/2` are plain sends to a channel, and its moduledoc says why; no process) | does I/O: every write and the channel's reads are `Durable.Store` commits; Registry, sends to channels (`op.cancel` from inside cancel commits), PubSub through `Events`, output broadcast with `Durable.live/2` | `Durable`, `Tx`, `Repo`, `Events`, `NodeKeys`, `Machines.Op`, `Machines.Rules`, `Machines.Roster`, `PhotonCore.Operation.Wire`, `Photon.MachineRegistry` |
| `Photon.Machines.Op` | data (Ecto schema, table `machine_ops`: one row per tool call's op, with `confirmed`, `pushed`, `cancel` and the result until it is claimed) | pure | Ecto |
| `Photon.Machines.Rules` | functional core (hub rules 2 to 9 of step 1: what a push, a join, a snapshot, a claim, a cancel or a give-up does to a row, and what to send) | pure | `Machines.Op`, `PhotonCore.Operation`, `Operation.Wire` |
| `Photon.Machines.Roster` | functional core (the machines the hub knows, `local` first, each one's status: online, outdated (connected without `ops:2`), offline or unknown; `sort/1`, the order `list/0` returns) | pure | none |
| `Photon.MachineTools` | boundary (namespace: `tools/0` for a profile, `signal_key/1`; exports `Guide` and `MockPhrases`, which Blip and threads share; the moduledoc lists the layers) | pure | `Machines`, its tool modules |
| `Photon.MachineTools.Shell`, `Photon.MachineTools.ViewImage` | boundary (durable tools, `replay: :safe`; delegate to `Call`; they work in the conversation's working directory) | does I/O through `Call` | `Call`, `Translate` |
| `Photon.MachineTools.ListMachines` | boundary (durable tool; names the working directory on each online machine when the conversation has one) | does I/O (Registry, DB) | `Machines` |
| `Photon.MachineTools.Call` | boundary (one `shell` or `view_image` call: `execute/3` commits the op, with the API's `workdir` as its `directory`, and parks on its signal, `resume/2` claims, waits on or gives up (at once, with the outdated message, when the machine is connected without `ops:2`), `on_interrupt/2` cancels) | does I/O (commits through `Machines`, app env, clock) | `Machines`, `Translate`, `Wait`, `Durable.ToolAPI`, `Tx` |
| `Photon.MachineTools.Translate` | functional core (tool arguments and the working directory to an op's `args`; a snapshot to the tool result and its details, bounded again on the hub; the unknown and outdated machine texts) | pure | `PhotonCore.Operation`, `PhotonCore.Output`, `Message` |
| `Photon.MachineTools.Guide` | functional core (the prompt lines about how a `shell` call behaves, shared by Blip's and a thread's prompt) | pure | none |
| `Photon.MachineTools.MockPhrases` | functional core (the machine phrasings Blip's and a thread's scripted models share, and how they relay a result) | pure | `LLM.Mock`, `Message` |
| `Photon.MachineTools.Wait` | functional core (the op ID from the task ID, when to check again, when to give up on an offline machine, and the offline message) | pure (time and limits passed in) | none |
| **Nodes: install, keys and reach** | | | |
| `Photon.NodeDist` | boundary (packaged binaries, install script) | `dir/0`, `binary/1`, `available/0`, `version/0` do I/O; `outdated?/2`, `target/2`, `install_script/1` pure | `Hub`, `InstallScript` |
| `Photon.InstallScript` | functional core (the install script and the node socket URL, from the hub's base URL) | pure | EEx |
| `Photon.Hub` | boundary (how nodes reach the hub) | reads app env; `node_socket_url/1` pure | `InstallScript` |
| `Photon.Provision` | boundary (API and server: job table; jobs run as monitored tasks) | is a process; `System.cmd` ssh, temp files, PubSub | `Jobs`, `Script`, `NodeDist`, `Machines`, `NodeKeys` (a fresh key per install, revoked on removal), `Events`, `Photon.ProvisionTasks` |
| `Photon.Provision.Jobs` | functional core (the job table: validation, busy, events, a task that died) | pure | none |
| `Photon.Provision.Script` | functional core (probe, upload, installer input, ssh arguments, failure reasons) | pure | `InstallScript` |
| `Photon.Provision.Lines` | functional core (Collectable line splitter) | pure apart from the `log` callback it calls | none |
| `Photon.Tailnet` | boundary (`tailscale` CLI, ETS cache) and the cache table's owner (a GenServer that creates it in `init/1`) | does I/O; `parse/1`, `parse_whois/1`, `names/1`, `fresh?/2` pure | ETS |
| **Settings and auth** | | | |
| `Photon.Settings` | boundary (`load/0`, `save/1`) and pure functions of a settings map (`normalize/2`, `model/1`, `model_label/1`, `reasoning/1`, `scheduled_work?/1`), read by Blip's and the thread profile alike, and by `Photon.Schedules` for consent | `load/0`, `save/1` do I/O | `Paths`, `PrivateFile`, `Events` |
| `Photon.ChatGPT` | boundary (API and server: the ChatGPT account; sign-in, tokens only while plan use is allowed, serialized refresh, models; `stream/3` runs a request in the caller and reports a refused token) | is a process; HTTP to OpenAI, the account file, PubSub; its state is redacted from crash reports (`format_status/1`) | `ChatGPT.OAuth`, `Paths`, `PrivateFile`, `Events`, `PhotonCore.LLM`, Req |
| `Photon.ChatGPT.OAuth` | functional core (Sign in with ChatGPT's rules: the link, the pasted address, the token forms and claims, when to refresh) | pure (secrets and time passed in) | Jason |
| `Photon.Auth` | boundary (who may open the GUI: `:tailscale`, `:password`, both, or `:off`) | the password does I/O (file, `:persistent_term`); `check_device/3` is pure | `Paths`, `Tailnet` |
| `Photon.NodeKeys` | boundary (each node's own key: issued with a clock generation that never repeats, tied to its machine's device (up front for SSH installs, atomically on first use by the user's own or a tagged device otherwise, kept across new keys), checked against where it's used, revoked to a tombstone that keeps the machine out of the GUI until `forget/1`; announces every change; the known machines are its keys that aren't revoked) | does I/O (DB, PubSub; the built-in node's key in `:persistent_term`); `check/4` is pure | `Repo`, `NodeKeys.Key`, `Events`, `Tailnet` |
| `Photon.NodeKeys.Key` | data (the `node_keys` table: a key's hash, its device, generation, expiry while untied, and when it was removed) | pure | Ecto |
| `Photon.PrivateFile` | boundary (whole-or-nothing 0600 file writes) | does I/O (temp file, sync, rename) | none |
| `Photon.Markdown` | functional core (rendering through a NIF) | pure | MDEx |

### apps/hub (`:photon`), web

| Module | Layer | Purity | Depends on |
| --- | --- | --- | --- |
| `PhotonWeb` | boundary glue (`use` macros; `html_helpers` imports `TimeComponents`) | pure | Phoenix |
| `PhotonWeb.Endpoint` | boundary (HTTP and websocket entry) and lifecycle (supervises Bandit and sockets) | is a process | `Router`, `NodeSocket`, Phoenix |
| `PhotonWeb.Router` | boundary (routing; every page in one `live_session`, including a project's schedule form and the skills pages, the image routes of Blip and of each thread) | pure | controllers, LiveViews, `Auth`, `Shell` |
| `PhotonWeb.Telemetry` | lifecycle | is a process (Supervisor) | telemetry_poller |
| `PhotonWeb.Auth` | boundary (plug and `on_mount`; in the tailscale modes checks every request and LiveView connection, and rechecks open pages when node keys change and every minute through a `handle_info` hook) | does I/O (session, PubSub, a timer; `tailscale whois` through `ClientIP`, node devices from `NodeKeys`) | `Photon.Auth`, `ClientIP`, `NodeKeys` |
| `PhotonWeb.ClientIP` | boundary (where a request came from, behind the hub's own TLS proxy) | `client/2` is pure; `identify/2` asks `Tailnet.whois/1` | `Tailnet` |
| `PhotonWeb.Origin` | boundary (`check_origin`) | does I/O (app env, `Tailnet.own_names/0`) | `Tailnet` |
| `PhotonWeb.Shell` | boundary (LiveView hook for the app shell: the sidebar's projects and threads with their states, how many threads need the owner, the machines, the model, the ChatGPT sign-in) | does I/O on mount and on the messages it rebuilds on (`:nodes_changed`, `{:node_keys_changed, _}`, settings and ChatGPT changes; `{:projects_changed, _}` and `{:questions_changed, _}` rebuild the sidebar and the count, `{:durable_tasks, _}` only the sidebar and only for a listed thread); the derivations are `Threads.sidebar/1`, `Threads.needs_you_count/0`, `Machines.roster/0`, `Settings.model_label/1` and `ChatGPT.ready?/1` | `Assistant`, `ChatGPT`, `Machines`, `NodeKeys`, `Projects`, `Questions`, `Settings`, `Threads` |
| `PhotonWeb.HealthPlug` | boundary | does I/O (response only) | Plug |
| `PhotonWeb.NodeSocket` | boundary (node socket auth: the node's key against where it connected from; the socket's ID names the node and key generation) | does I/O through `NodeKeys` | `NodeKeys`, `ClientIP`, `NodeChannel` |
| `PhotonWeb.NodeChannel` | boundary and worker (one per connected node; the server layer for a node, rule 11; joins only while its key is current, closes its connection when the key is replaced, and acts only on its own node's ops; hands `op.snapshot` and `op.output` to `Machines` and pushes what it returns, and is the only place an `op.start` is built, on `:joined` and `{:push_op, id}`; ignores events it doesn't know) | is a process; DB through `Machines`, the registry through `Machines.register/2`, PubSub | `Machines`, `NodeKeys`, `PhotonCore.Operation.Wire` |
| `PhotonWeb.NodeInstallController` | boundary | does I/O (files) | `NodeDist` |
| `PhotonWeb.ConversationImageController` | boundary (serves the images in a conversation, one per request, behind `PhotonWeb.Auth`: `blip/2` for Blip's, `thread/2` for a thread's, each finding entries only in its own conversation) | reads the database through `Assistant.image/2` and `Threads.image/3` | `Assistant`, `Threads` |
| `PhotonWeb.ErrorHTML` | boundary (rendering) | pure | Phoenix |
| `PhotonWeb.ErrorJSON` | boundary (rendering) | pure | Phoenix |
| `PhotonWeb.CoreComponents` | boundary (UI components, including `switch/1`, the on and off switch of the skills pages) | pure | Phoenix.Component |
| `PhotonWeb.TimeComponents` | boundary (UI components: `local_time/1`, a UTC time the colocated `.LocalTime` hook shows in the browser's time zone, and `local_datetime_input/1`, a local-time input whose `.LocalDateTime` hook writes UTC into the field the server reads) | pure | Phoenix.Component |
| `PhotonWeb.EditorComponents` | boundary (UI components the context file and skill editors and the schedule form share: `guarded_form/1` with the `.UnsavedGuard` hook that asks before leaving unsaved text, `editor_tab/1`, `banner/1`) | pure | Phoenix.Component, `CoreComponents` |
| `PhotonWeb.ScheduleComponents` | boundary (UI components: a schedule's when line and last-run line, used by the home page, the project page and the schedule form) | pure | `ScheduleText`, `TimeComponents` |
| `PhotonWeb.ThreadText` | functional core (the pages' words for threads: state labels, the home page's summary, "and 4 more", the Mark all read flash, a quiet row's word, a question on one line) | pure | `Threads.State` |
| `PhotonWeb.ScheduleText` | functional core (the pages' words for schedules: how often, what a firing did, the when line per state, where it goes, what Run now did; never formats a time) | pure | `Schedules.Schedule`, `Schedules` (types) |
| `PhotonWeb.SkillText` | functional core (the skills pages' words: where a skill is on, how it arrived, a link's place, the install notes as lines) | pure | `Skills.Skill` |
| `PhotonWeb.Blip` | boundary (UI component: Blip drawn from the brand kit's SVG, posed by `data-state`) | pure | Phoenix.Component |
| `PhotonWeb.Layouts` | boundary (UI layout: the sidebar with Home, the projects and their threads, Machines with the online count linking to the Nodes page, Skills, and Settings; `active` marks the page on screen) | pure | `CoreComponents` |
| `PhotonWeb.ConversationComponents` | boundary (UI components for a durable conversation, shared by Blip's panel and a thread's page: entries, tool call lines with the machine named or the skill loaded, web searches, the in-flight answer, the composer, the sign-in panel; IDs take a prefix, images an image path function) | pure | `Transcript`, `Markdown`, `Message`, `CoreComponents` |
| `PhotonWeb.ConversationView` | boundary (socket helpers for the two conversation pages: mount a conversation's assigns and stream, fold in commits and live events; not a process, and calls only `Transcript` and `Markdown`) | pure apart from the socket it's handed | `Transcript`, `Markdown` |
| `PhotonWeb.ProjectText` | functional core (the project pages' words for times, file sizes and who changed a file, from a time and the thread titles passed in) | pure | `ContextFile` |
| `PhotonWeb.BlipLive` | boundary (UI process; sticky, rendered once by `Layouts.app/1` over every page) | is a process; talks only to `Photon.Assistant`; draws with the shared conversation modules and `Assistant.Notice`; a hook reports the page under it, which a chip in the message box offers as context | `Assistant`, `Transcript`, `Assistant.Notice`, `ConversationComponents`, `ConversationView`, `Markdown`, `Message`, `Blip` |
| `PhotonWeb.ProjectNewLive` | boundary (UI process; starts a project from a purpose and an optional name) | is a process; talks only to `Photon.Projects` | `Projects` |
| `PhotonWeb.ProjectLive` | boundary (UI process; a project's page: name, folder and purpose (editable), its threads (from the project's board, each with its state's mark and words) and context files as streams, and in the second column its skills (turned on and off with a picker) and schedules (with Run now, Delete, and a banner when scheduled work is off)) | is a process; reads on mount and on `{:projects_changed, _}` (schedules too), `{:project_files_changed, ...}`, `{:skills_changed, _}`, its own `{:schedules_changed, id}`, settings changes, and its own threads' `{:durable_tasks, _}` and `{:questions_changed, _}` | `Projects`, `Threads`, `Skills`, `Schedules`, `Markdown`, `ProjectText`, `ScheduleText`, `ThreadText`, `ScheduleComponents` |
| `PhotonWeb.ContextFileLive` | boundary (UI process; writes a new context file or edits one, with a preview, saves against the version it loaded, and a banner when a thread or another tab saves first) | is a process; reads on mount, on `{:project_files_changed, ...}` and on `{:projects_changed, _}` for the project's name | `Projects`, `Threads`, `Markdown`, `ProjectText`, `EditorComponents` |
| `PhotonWeb.ScheduleLive` | boundary (UI process; a project's schedule form: `:new` makes one, `:edit` saves against the version it loaded, with a banner when another tab saves first, and shows the next and last run with Run now and Delete) | is a process; on `:edit` follows `{:schedules_changed, _}` and refreshes only the next and last run, never the form | `Schedules`, `Projects`, `Threads`, `ScheduleText`, `ScheduleComponents`, `EditorComponents` |
| `PhotonWeb.SkillsLive` | boundary (UI process; the Skills page: every skill as a stream with where it is on and how it arrived, a switch for Blip, and links to write or install one) | is a process; re-reads on `{:skills_changed, _}`, and on `{:projects_changed, id}` only when a listed skill is on there | `Skills`, `Projects`, `SkillText` |
| `PhotonWeb.SkillLive` | boundary (UI process; `:new` writes a skill, `:edit` edits one against the version it loaded and turns it on for Blip and each project; a toggle re-reads the switches, and only a new version touches the form) | is a process; follows `{:skills_changed, _}` and `{:projects_changed, _}` | `Skills`, `Projects`, `Markdown`, `SkillText`, `EditorComponents` |
| `PhotonWeb.SkillInstallLive` | boundary (UI process; install from a link, fetched in a `start_async` task, or a pasted SKILL.md: one candidate opens an editable preview, several are a list to pick from) | is a process; the fetch's HTTP runs in its `start_async` task; follows `{:skills_changed, _}` while a list is open | `Skills`, `Markdown`, `SkillText`, `EditorComponents` |
| `PhotonWeb.ThreadLive` | boundary (UI process; `:new` starts a thread with its first message, `:show` is its conversation with a composer, Stop and a Schedule link to a new schedule for the thread, drawn with the shared conversation modules under the ID prefix `thread-`; its state chip, Resolve and Reopen; while Blip has its `ask_blip` question a line above the composer, and while one is with the owner an answer form per question in the composer's place) | is a process; subscribes to the thread's conversation; marks the thread seen while open; re-reads its state on its project's `{:projects_changed, _}` and its own `{:questions_changed, _}` | `Projects`, `Threads`, `Questions`, `Transcript`, `ThreadText`, `ConversationComponents`, `ConversationView` |
| `PhotonWeb.HomeLive` | boundary (UI process; the home page at `/`, Home in the sidebar: what needs the owner across every project (questions passed to them with answer forms, threads that asked, failed and unread threads), what is running or asking Blip, threads gone quiet, and Blip's schedules) | is a process; the board (`Threads.board/1`, grouped by `Threads.State.sections/1`) read on mount, on `{:projects_changed, _}`, `{:questions_changed, _}` and a one-minute tick; answer drafts kept by question ID; Blip's schedules on `{:schedules_changed, nil}` | `Threads`, `Questions`, `Assistant`, `Schedules`, `ThreadText`, `ScheduleComponents` |
| `PhotonWeb.ActivityLive` | boundary (UI process; the activity page at `/activity`, Activity in the sidebar; for now its header and empty state) | is a process; reads nothing yet | none |
| `PhotonWeb.NodesLive` | boundary (UI process) | is a process; node data read on mount and on change messages, `tailscale` in a `start_async` task; `render/1` only derives from assigns | `Machines`, `NodeDist`, `NodeKeys`, `Provision`, `Tailnet`, `Hub` |
| `PhotonWeb.SettingsLive` | boundary (UI process; the scheduled-work checkbox covers every schedule, Blip's and the projects') | is a process; settings file, the ChatGPT account (sign-in steps; models in a `start_async` task), Blip's memory | `Settings`, `ChatGPT`, `Assistant` |

### Test support

| Module | Layer | Notes |
| --- | --- | --- |
| `PhotonCore.Case` | tests | Case template for every core test: aliases the core modules, imports `PhotonCore.Fixtures` |
| `PhotonCore.Fixtures` | tests (builders) | Requests, stub configs, a shell operation, Responses stream events and SSE bodies with overrides; `read_stream/1` folds bytes through `Responses.Response`; `capture_events/1` |
| `PhotonCore.StubProvider` | tests (boundary) | `Req.Test` stubs that play the Responses API: a streamed body, HTTP chunks, a sequence of failures; forwards each request to the test process |
| `PhotonCore.Generators` | tests (StreamData) | Shared generators: cut points, arbitrary JSON, a streamed Responses answer with the message it folds into |
| `PhotonCore.EchoScript` | tests (mock script) | pure |
| `PhotonNode.Case` | tests | Case template for the node's core tests: aliases the pure modules, imports `PhotonNode.Fixtures`; its moduledoc describes the test layout |
| `PhotonNode.Fixtures` | tests (builders) | A shell operation (`shell_op/1`) and its running and completed snapshots, with overrides |
| `PhotonNode.NodeCase` | tests | Boundary case for the operation layer and the connection: starts a whole `PhotonNode` without a hub in a temporary data dir, registers the test process under the name `PhotonNode.Connection`, imports the fixtures |
| `PhotonNode.TestOwner` | tests (an `Ops.Owner`) | Forwards an operation's checkpoints, reports and output to the test process, which answers the checkpoints |
| `PhotonNode.TestLink` | tests (an `Executor.Link`) | Sends the test process each snapshot with the journal entry at that moment, and output; can hold the executor inside the link |
| `Photon.Case` | tests | Case template for the hub's core tests: aliases the pure modules, imports `Photon.Fixtures`; its moduledoc describes the test layout |
| `Photon.Fixtures` | tests (builders) | Task records, entries, calls, submissions, responses, signals, settings and environments, all with overrides; data only |
| `Photon.MachineOps` | tests (builders) | A live tool task to hang an op on, the op it would start, and snapshot payloads as a node sends them |
| `Photon.ChatGPTStub` | tests (boundary) | Plays OpenAI's side of Sign in with ChatGPT (token, revoke, models) through a `Req.Test` stub; `reset!/0` and `sign_in!/1` |
| `Photon.FakeTailscale` | tests (boundary) | A stand-in `tailscale` executable (`PHOTON_TAILSCALE`) that answers `whois --json` and `status --json` for the devices it's given |
| `Photon.Eventually` | tests | A bounded "eventually" for things `assert_receive` can't see (OS processes): calls a check until it is truthy or a deadline passes, no sleeping |
| `Photon.DataCase` | tests | Deletes every table, writes the real settings file, starts `Photon.Durable.Supervisor.children/0` for `@tag :durable` |
| `PhotonWeb.ConnCase` | tests | Phoenix conn case on top of `DataCase` |
| `Photon.TestProfile`, `Photon.TestProfile.Wait` | tests (fake profile and tool) | pure* |
| `Photon.TestProfile.Workdir`, `Photon.TestProfile.Where` | tests (a profile with a working directory, and a tool that reports the one it was handed) | for the `workdir/1` tests (step 2, section 3.4) |
| `Photon.TestProfile.Raise`, `Photon.TestProfile.ShellThenRaise` | tests (tools that raise: in `execute/2`, and in `resume/2` after a shell op exists) | for the raise-runs-`on_interrupt` tests (step 1, hub rule 10) |
| `Photon.HarnessProfiles` (`Block`, `Loop`), `Photon.Property.SlowProfile` | tests (profiles for regression tests and properties) | `Block` holds a model request until the test releases it; `SlowProfile` simulates model latency |

The hub-plus-node test (`apps/hub/test/integration/machine_tools_e2e_test.exs`)
runs a real node against the real channel over a Bandit listener on a free
port, with the scripted models: Blip's machine tools, a thread's
commands in its project's folder, which the node makes and the project's
threads share, and a project schedule that starts a thread whose command
runs there and which loads a skill turned on for the project.

## Supervision trees

### apps/core

No application callback (`mix.exs` has no `:mod`), so no processes. Model
requests run in whichever process calls `PhotonCore.LLM.stream/3`.

### apps/node

```
PhotonNode.AppSupervisor  one_for_one     (PhotonNode.Application)
└── PhotonNode  rest_for_one              started only when config :photon_node, autostart: true
    ├── PhotonNode.OpRegistry             Registry (unique): operation id -> operation process
    ├── PhotonNode.OpSupervisor           DynamicSupervisor
    │   └── Ops.Shell | Ops.Job (ViewImage)    GenServer, :temporary, one per operation
    │       └── (Shell) Port -> bash wrapper -> the command's own process group (outside the BEAM)
    ├── PhotonNode.Executor               GenServer, :permanent: the hub's operations and their journal (<data_dir>/ops); scans and resumes on start
    └── PhotonNode.Connection             Slipstream client, :permanent; left out when connect: false (tests)
```

- Operations report to their owner (`PhotonNode.Ops.Owner`), the
  executor. `report/2` and `checkpoint/2` are calls with no timeout that
  catch every exit, so a snapshot is journaled before the operation goes
  on and an executor crash never takes an operation with it. The executor
  monitors its operation processes (rule 87) and decides about restarts
  with `Executor.Rules.down/3`; `OpSupervisor` never restarts them. A
  restarted executor catches up by calling `Ops.add/2`, which asks a live
  operation to resend its snapshot.
- An `Executor` crash restarts it and the `Connection` (`rest_for_one`);
  the operation processes keep running, and the restarted executor
  re-monitors them from its journal scan. A `Connection` crash restarts
  only the connection, which resends the journal's snapshots on join.
- An `OpSupervisor` or `OpRegistry` crash takes the executor and the
  connection with it; the restarted executor resumes the operations from
  the journal. So does a node VM restart, where a shell command's outcome
  comes from its `canceled`, `stopped`, `exit`, `pid` and `unstarted`
  files.
- Config sits in `:persistent_term` and every name is global, so a VM runs
  at most one node.

### apps/hub

`Photon.Application`'s moduledoc writes the plan down;
`Photon.Durable.Supervisor`'s has its own.

```
Photon.Supervisor  one_for_one                      (Photon.Application)
├── PhotonWeb.Telemetry  Supervisor
│   └── :telemetry_poller
├── Photon.Repo                                     Ecto pool (SQLite)
├── Ecto.Migrator                                   migrates at boot, then :ignore
├── Photon.PubSub                                   Phoenix.PubSub
├── Photon.Tailnet                                  GenServer that owns the whois ETS cache (lookups go straight to the table)
├── Photon.MachineRegistry                          Registry (unique): machine id -> NodeChannel pid, value = node info
├── Photon.ProvisionTasks                           Task.Supervisor: SSH install/uninstall jobs (async_nolink, monitored by Provision)
├── Photon.Provision                                GenServer: job table, broadcasts progress, fails a job whose task dies
├── Photon.ChatGPT                                  GenServer: the ChatGPT account; sign-in, tokens, one refresh at a time
├── Photon.Durable.Supervisor  one_for_one          only when start_durable (off in tests, which start its children/0)
│   ├── Photon.Durable.TaskSupervisor               Task.Supervisor: one task per durable step (async_nolink)
│   ├── Photon.Durable.Store                        GenServer: the commit line (no state; a lock)
│   └── Photon.Durable.Scheduler                    GenServer: reconciles with Durable.Policy, starts steps
├── PhotonWeb.Endpoint                              Bandit
│   ├── /node/websocket -> NodeSocket -> NodeChannel        one process per connected node
│   ├── /live -> HomeLive | ActivityLive | ProjectNewLive | ProjectLive | ContextFileLive | ThreadLive
│   │            | ScheduleLive | SkillsLive | SkillLive | SkillInstallLive
│   │            | NodesLive | SettingsLive, each with BlipLive (sticky) over it
│   └── HTTP -> Router -> NodeInstallController | ConversationImageController | HealthPlug
└── PhotonNode  rest_for_one                        only with :local_node; the node tree above, dialing this Endpoint
```

- The `:photon_node` dependency also starts its own application, but the
  hub sets `autostart: false` (`config/config.exs`), so its
  `PhotonNode.AppSupervisor` is empty and the embedded node lives under
  `Photon.Supervisor` instead.
- Channels and LiveViews are supervised by Phoenix and Bandit and linked to
  their transports, not to anything in Photon's tree. `NodesLive` runs
  `tailscale status` in a `start_async` task linked to the LiveView.
- There is no process per operation on the hub (rules 3, 31, 89). A
  machine tool call is a durable task parked on its op's signal, the op is
  a `machine_ops` row, and the node's channel carries the messages. A
  channel crash loses its registration and its cache of where each op's
  live output goes; the node rejoins and both are rebuilt.
- Step 2 added no process and no registered name. `Photon.Projects` and
  `Photon.Threads` are APIs over the database and the Store's commit
  line; a thread is a conversation the durable harness runs like Blip's,
  so its steps are tasks under `Durable.TaskSupervisor`. A crash loses
  nothing new: projects, files and threads are rows, and the
  announcements are hints that every page re-reads on mount.
- Step 3 added no process and no registered name either. `Photon.Skills`
  and `Photon.Schedules` are APIs over the database and the Store's
  commit line. A schedule's timer is a `"routine"` durable task the
  existing Scheduler wakes, so its steps run under
  `Durable.TaskSupervisor` like any other, and a hub restart finds it
  waiting. A skill fetch runs in the install page's `start_async` task,
  with its downloads in `Task.async_stream/3` tasks linked to it, so
  closing the page drops the fetch and nothing else. The new pages
  (`ScheduleLive`, `SkillsLive`, `SkillLive`, `SkillInstallLive`) are
  LiveViews under the endpoint like the others.
- The durable trio is under its own `one_for_one` supervisor, so a
  `Scheduler` restart doesn't touch the steps already running under
  `Durable.TaskSupervisor`; their commits are fenced instead (H2). Its
  restart intensity is counted in that supervisor (three restarts in
  five seconds) rather than in `Photon.Supervisor`.

## Hotspots

Ordered by how much they cost. Each says where, what's mixed, and which way
to move it. They describe the 2026-10-03 snapshot. Step 1 removed node
sessions, the model relay and the node's agent loop, so H1, H3 and H7 are
about code that no longer exists, and the session parts of H6, H8, H9,
H11, H13, H14 and H15 went with it; each says so in a step 1 status line.

### H1. The node's session state machine lives in GenServer callbacks (high)

> Status (step 1): gone. The node's session harness (`Harness.Session`,
> `Coordinator` and the rest) was removed. The node runs only the hub's
> operations, and its decisions are the pure `Executor.Rules` and
> `Executor.Request`.

> Status (after the node refactor): done, along the lines below.
> `PhotonNode.Harness.Session` is the state machine as a pure token that
> collects effects; `Coordinator` runs a handler's steps and their effects
> in order. Replay is `Session.replay/2`. The ordering rules are tested on
> the core (`test/core/session_test.exs`, and the pure property
> `test/property/session_property_test.exs`) with no processes or files.
> `init/1` still reads the workspace and the hostname, once, and hands them
> to the session as its env. The mailbox drain is unchanged on purpose: it
> decides which inputs share a decision, and `Coordinator.tla` models it.

`apps/node/lib/photon_node/harness/coordinator.ex` is 826 lines with no pure
core underneath it. `persist/3` (821-825) appends, fsyncs and notifies the
connection, and it's called from inside what is otherwise state folding:
`handle_input/2` (296), `request_model_response/1` (517),
`process_model_response/3` (598), `schedule_tool_calls/1` (644),
`reconcile/1` (668), `handle_op_update/2` (699), `handle_stop/1` (735) and
`record_run_state/1` (757, 766). `dispatch/2` (673-693) starts operation
processes in the middle of a reduce. `decide/1` (708-722) mixes the "when
does a turn start" policy with timers (`arm_heartbeat/1` 790-809,
`arm_idle_stop/1` 811-817). `init/1` builds state through `base_state/3`
(105-143), which creates the workspace, globs and reads skill files and
looks up the hostname; `system_prompt/2` (145-153) calls
`:inet.gethostname` again on every settings change and during replay. The
mailbox is drained with selective receives inside callbacks (`drain/3`,
266-282), which waits at least 1 ms per source per message.

The upstream ordering rules (moduledoc, 9-14) are the most important
property of the harness, and today the only way to test them is
`session_test.exs` with a real node, real files and a mock model. I'd
extract a pure `PhotonNode.Harness.Session` with
`apply(state, event) :: {state, [effect]}`, where effects are things like
`{:persist, kind, data}`, `{:dispatch, op}`, `{:cancel_llm}`,
`{:request, request}` and `{:arm, timer, ms}`. The GenServer then runs
effects in order (persist effects first, which keeps the rules), and
replay is a reduce that drops effects.

### H2. A Scheduler restart runs in-flight steps twice (high)

> Status (after the verification pass, see `docs/verification.md`): fixed
> by fencing. `Runtime.commit` passes the task as the step started with it,
> and `Tx.transition/4` ignores the transition unless the task is still
> `running` with the same `updated_at` (`runs` alone isn't enough: it
> restarts with each phase). The supervision tree is unchanged.

> Status (after the hub refactor): the trio now has its own supervisor,
> `Photon.Durable.Supervisor`, still `:one_for_one` on purpose (a
> scheduler restart leaves steps running and fences them), with the
> reasons in its moduledoc.

`Photon.Application` puts `Durable.TaskSupervisor`, `Store` and
`Scheduler` under `one_for_one` (`application.ex:32-42`). Steps start with
`Task.Supervisor.async_nolink/2` (`scheduler.ex:293-297`), so they outlive
the scheduler. When the scheduler restarts, `init/1` flips every `running`
task back to `pending` (`scheduler.ex:37-41`) and starts a new step, while
the old one keeps going. `Tx.transition/3` only checks for terminal or
aborted tasks (`tx.ex:201-212`), so both steps commit. For a `Generation`
that means two model calls and two answers or tool rounds.

The scheduler can crash from inside its own callbacks. `Store.commit/1`
re-raises an exception from the commit function in the caller
(`store.ex:36`), and the scheduler's commit functions run task-kind
callbacks (`on_abort` at `scheduler.ex:161-178`, `on_fail` at 310-326).
Any database error in `reconcile/1` crashes it too (and see H3 for a second
SQLite writer). The fix is either supervision (`rest_for_one` with the
task supervisor after the scheduler, so a scheduler restart kills its
steps) or fencing (pass the step's `runs` into the transition and ignore
stale ones). Fencing is the more robust of the two.

### H3. The node-session mirror bypasses the durable commit line (high)

> Status (step 1): gone with node sessions. Machine ops are rows written
> only in `Durable.Store` commits, and a terminal snapshot is recorded in
> the same commit as the signal that wakes its tool call.

> Status: the lost-signal part is fixed. `ingest/4` and `reject_input/3`
> now run as one `Durable.Store` commit with `Tx.signal/3` inside, and
> broadcast after it. `start/3` and `send_input/3` still write directly.

> Status (after the hub refactor): done. `start/3`, `send_input/3` and
> `delete/1` commit through `Durable.Store` too, so the Store is the only
> writer. Each write group is one commit (`send_input/3`'s insert and
> touch, `delete/1`'s three deletes), broadcasts and pushes follow it, and
> the rules (`place/3`, `effect/1`, refusals) are the pure
> `Photon.NodeSessions.Mirror`. The watcher's wait still has no deadline.

`NodeSessions.ingest/4` stores a record in one transaction
(`node_sessions.ex:178-196`) and then fires `Durable.signal/2` as a second
commit through `Durable.Store` (201). If the hub stops between them, or the
60 s `Store.commit` call (`store.ex:32`) times out and takes the
`NodeChannel` down with it, the signal is gone for good: the session's
`next_offset` already moved, so the node never resends the `state: idle`
record. `NodeWatch` waits on that signal with no deadline
(`node_watch.ex:18-23`), so the report never reaches the conversation.
`reject_input/3` (255-274) splits its write and signal the same way.

More generally, `start/3` (67-90), `send_input/3` (93-126) and `ingest/4`
write SQLite directly from channel and tool processes, concurrently with
`Durable.Store`. That's two writers on one SQLite file, and it contradicts
the moduledocs that say every durable change goes through one line of
commits (`durable.ex:5-7`, `store.ex:3`). Moving these writes into
`Store.commit/1` (with `Tx.signal/3` in the same transaction) fixes both,
without changing the wire protocol or the schema. A `"until"` on the
watcher's wait would be a cheap safety net.

### H4. Scheduling policy is inside the Scheduler, with I/O in predicates (medium)

> Status (after the hub refactor): the policy is the pure
> `Photon.Durable.Policy`: what to kill and abort (bottom-up), when a
> waiting task wakes (`wake?/3` takes the statuses and the signal as
> facts), what `fail_fast` aborts, whether a task starts, what a failure
> does, and the timer's delay. The scheduler still reads the facts per task
> right before each decision and applies each one in its own commit that
> re-checks the task (`Policy.abort?/1`, `wakeable?/1`, `startable?/1`,
> `failable?/1`), so the interleavings `Durable.tla` models are the same.
> It still scans the live tasks on every reconcile; a single-commit pass
> would change those interleavings and is left for later.

Every commit that touches a task or signal triggers `reconcile/1`
(`scheduler.ex:123-132`). It scans all live tasks (125), then for each
waiting task `wake?/2` (219-231) runs its own queries (`statuses/1` at
241-243, a `Signal` lookup at 225), each state change is its own
`Store.commit` (161, 189, 278), and `arm_timer/1` (329-347) scans waiting
tasks again. `wake?/2` is public so it can be tested, but it needs a
database. `stop_aborted/2` (136-182) nests reduce, for, a commit closure,
case and with. The policy (abort bottom-up, fail-fast, wake conditions,
deadline) would fit in a pure `reconcile(tasks, statuses, signals, now)`
that returns actions, which the GenServer applies in one commit.

### H5. `Durable.Tx` depends on hidden process state (medium)

> Status (after the hub refactor): fixed by making the boundary explicit.
> `Tx` owns its change list: `Tx.run/1`, which only `Store` calls, opens a
> commit and hands back the changes, and `%Tx{}` carries a reference to
> that commit. A write through a `Tx` that isn't the calling process's
> open commit raises `ArgumentError` before it touches the database.
> `Durable.busy?/1` and the other reads go through `Photon.Durable.Queries`
> and need no `Tx`. The changes a commit announces are worked out by the
> pure `Photon.Durable.Changes`. Plugin callbacks still run inside the
> Store's process; `Store`'s moduledoc says why it is a process.

`Tx` records changes in the process dictionary (`tx.ex:20-22`), which only
`Store.handle_call/3` sets up (`store.ex:45-63`). Yet `%Tx{}` is an empty
struct (`tx.ex:13`) that any process can build: `Durable.busy?/1` calls
`Tx.active_run(%Tx{}, ...)` outside a commit (`durable.ex:100`). That one
only reads, but a writing `Tx` call made the same way would hit the
database, never be announced, and leave changes in the caller's
dictionary. `Store` also runs caller closures, including plugin
`on_abort`/`on_fail` code, inside the one serialized process. Making `%Tx{}`
carry its change list (returning `{result, tx}`), or raising when a `Tx`
write runs outside a commit, would make the boundary explicit.

### H6. Streaming fans out with no back pressure (medium)

> Status (step 1): model tokens no longer cross the node link; only
> command output does, sampled once a second in chunks of at most 64 KB
> per stream, broadcast by `Machines.output/3` and kept by Blip's page as
> a tail of 8,000 characters per call. The hub's own model deltas are
> unchanged.

> Status (node): unchanged in behavior. The moduledocs of `Connection`,
> `ModelRequest`, `Coordinator`, `Ops` and `Ops.Shell` now say why each
> notification is a plain send and what bounds it, so a faster producer
> isn't added to the same path unnoticed.

> Status (hub): unchanged in behavior, documented the same way:
> `Durable.live/2`, `ToolAPI.output/2`, `NodeSessions.live/2`,
> `Nodes.command/3` and `Scheduler.notify/2` say why they are broadcasts or
> plain sends and what bounds them. The LiveViews still re-render Markdown
> per delta.

Every model token and every second of command output is its own message,
end to end. On the node, `Coordinator` (`coordinator.ex:531-536`) and
`Ops.Shell.stream_live/1` (`shell.ex:446-468`) call `Connection.live/2`, a
plain `send` (`connection.ex:21-27`); the connection pushes each one; the
hub's `NodeChannel.handle_in("live")` (`node_channel.ex:61-64`) broadcasts
it; `SessionLive` appends and re-renders Markdown for the whole text
(`session_live.ex:75-91`, 172). On the hub, `Generation`
(`generation.ex:43-46`) broadcasts each delta and `AssistantLive`
(`assistant_live.ex:145-150`) re-renders `Markdown.to_html(@live.text)` for
the full text on every delta (563), which is quadratic in answer length for
each open tab. Log records go the same way: one unacknowledged push per
record (`connection.ex:126-142`), each ingested in its own transaction on
the channel process (`node_channel.ex:52-59`). Coalescing deltas for 50 to
100 ms in `Connection` and in the LiveViews, showing live text as plain
text until it's committed, and batching replays would cover most of it.

### H7. Replays and boot read whole logs, repeatedly (medium)

> Status (step 1): gone. Nodes keep no session logs. After a join the
> node sends one snapshot per operation in its journal
> (`Executor.snapshots/0`), and an operation leaves the journal when the
> hub acknowledges its result.

> Status: the second read in `replay/3` is gone (it was also a race that
> could leave the hub a record short, NS-1 in `docs/verification.md`).
> Boot still reads whole logs.

After every join, `Connection` replays every session in the hub's sync map
(`connection.ex:56-62`). `replay/3` (153-162) calls `Store.read_from/2`,
which reads and decodes the entire file (`store.ex:107-109`), and when
nothing is new it calls `Store.count/1` (`store.ex:111`), which reads it a
second time. At boot, `Harness.working?/1` (`harness.ex:151-160`) reads each
full log to find the last state record. All of this happens in the
`Connection` process, so live forwarding stalls meanwhile. Skipping
sessions whose offset already matches, and keeping counts somewhere cheaper
than a re-read, would fix it.

### H8. LiveViews and the shell hook do I/O per message and per render (medium)

> Status (step 2): the shell hook also builds the sidebar's projects and
> threads (`Threads.sidebar/1`, three small queries) on mount, on
> `{:projects_changed, _}`, and on `{:durable_tasks, _}` only when a
> changed task belongs to a listed thread. The thread page keeps tool
> results without image data, as Blip's panel does, and the project page
> streams its threads and files.

> Status (step 1): `SessionLive` and the session counts are gone. The
> shell hook builds the machines from `Machines.roster/0` (the registry
> and the node keys) and rebuilds on `:nodes_changed` and
> `{:node_keys_changed, _}`, no longer on `{:durable_tasks, _}`. Blip's
> panel keeps tool results without their image data and loads each image
> by URL.

> Status (after the hub refactor): `render/1` does no I/O in any LiveView.
> `NodesLive` reads nodes and session counts (a count query, not a
> thousand rows) on mount and on `:nodes_changed`/`:node_sessions_changed`,
> and runs `tailscale` with `start_async`; `SessionLive` reads whether
> the node is online on mount and on `:nodes_changed`; `SettingsLive`
> reads the environment in its event handlers. `BlipLive` (which was
> `AssistantLive`) talks only to `Photon.Assistant` and folds with
> `Photon.Assistant.Transcript`. The shell hook still rebuilds per tab per
> message, and Blip's panel still keeps the whole history's tool results
> in assigns.

`PhotonWeb.Shell` rebuilds on `:nodes_changed`, `:node_sessions_changed`,
`:settings_changed` and every `{:durable_tasks, _}` (`shell.ex:25-29`),
which `Store` broadcasts on every task change (`store.ex:82-84`). Each
rebuild (`shell.ex:33-56`) runs two queries, reads the settings file and
calls `Assistant.conversation_id/0`, which can commit
(`assistant.ex:33-56`), once per open LiveView per event. `NodesLive`
queries the database per node inside `render/1`
(`nodes_live.ex:156`, `length(NodeSessions.list(node["id"], 1000))`), calls
`Nodes.list/0` there too (83), and runs `tailscale status` in the LiveView
process (64-65). `SessionLive.render/1` does a Registry lookup (116).
`AssistantLive` loads the entire conversation on mount and keeps every tool
result in assigns (`assistant_live.ex:18-38`), then re-queries on every
commit (127); `SessionLive` keeps the whole transcript, base64 images
included, in assigns (`session_live.ex:21-33`, `node_transcript.ex:166`).
Queries belong in event handlers that set assigns, tailscale belongs in
`start_async`, and the shell data could be computed once per change rather
than once per tab.

### H9. Functions that look pure but read files or the environment (medium)

> Status (step 1): `Settings.node_config/1` and `Operation.new/4` are
> gone. Operation IDs come from the hub, derived from the tool call's task
> ID (`MachineTools.Wait.op_id/1`).

> Status (node): the session core gets the machine description and the
> heartbeat interval in its env instead of reading the hostname and
> `PhotonNode.config/0`. New IDs (operations in the translators; turns,
> settings and heartbeat inputs in `Session`) still come from
> `PhotonCore.ID.new/1`; the moduledocs now call that the one impurity,
> and tests match on prefixes.

> Status: the core part is addressed. `PhotonCore.LLM.resolve/2` takes the
> environment lookup as a function and is pure; `resolve/1` passes
> `System.get_env/1` and is unchanged for callers. See the refactor log.

> Status (hub): `Photon.Settings`' functions of a settings map no longer
> default their argument to a file read; callers load once and pass it.
> `defaults/1`, `key?/2` and `env_key?/2` take the environment as a
> function (`System.get_env/1` by default), and `normalize/2` takes the
> defaults. `Assistant.system_prompt/1` reads settings, memory and the
> clock once and calls the pure `Photon.Assistant.Prompt.system_prompt/3`.

`Photon.Settings.model/1`, `key?/1`, `llm_config/2` and `node_config/1`
default their argument to `load()`, which reads a JSON file
(`settings.ex:91`, 100, 114, 126); `defaults/0` reads the environment
(30-41), so `normalize/1` isn't pure either. `load/0` runs on every
model-proxy request (`model_proxy_controller.ex:23`) and twice per
generation (`assistant.ex:76`, 90). `PhotonCore.LLM.resolve/1` reads the
OS environment (`llm.ex:73-89`). `Photon.Assistant.system_prompt/1`
(`assistant.ex:89-133`) reads the settings file, the memory doc and the
clock. The node's translators are documented as pure with no I/O
(`tools.ex:3-6`), but `Operation.new/4` mints IDs from the clock and RNG
(`operation.ex:15-24`). Load at the boundary and pass values in; inject
`now` and IDs where tests need determinism.

### H10. Provisioning jobs aren't monitored (medium)

> Status (after the hub refactor): fixed. Jobs start with
> `Task.Supervisor.async_nolink/2` and `Photon.Provision` monitors them; a
> job that goes down without reporting its end is marked failed ("Failed:
> the job stopped unexpectedly (...)"), so its machine is free again. A
> `Provision` restart still loses the table, which its moduledoc says. The
> table's rules are the pure `Photon.Provision.Jobs`.

`Provision` starts each SSH job with `Task.Supervisor.start_child/2` and
never monitors it (`provision.ex:55-56`). `job/3` rescues exceptions only
(117-129). A job that exits or gets killed leaves its entry at
`status: :running`, and `idle/2` (89-91) then answers "already busy" for
that machine until the hub restarts. A `Provision` restart loses the job
table while running jobs keep reporting to the dead pid. Starting jobs
with `async_nolink` and handling `:DOWN` fixes both.

### H11. Processes used only for code organization (low)

> Status (step 1): `Ops.SkillUse` is gone. `Ops.Job` runs only
> `Ops.ViewImage`, still in a process of its own, so an image read
> doesn't run in the executor.

> Status (node): `Ops.ViewImage` and `Ops.SkillUse` are now plain job
> functions (`run/1`), run by one worker, `Ops.Job`. A process is still
> used on purpose: an image read (up to 256 MB, then base64) shouldn't run
> in the coordinator, and registering the worker by operation ID keeps
> `Ops.add/2` and the coordinator's monitor working as before. Tailnet and
> `Durable.Store` are hub code, unchanged.

> Status (hub): `Photon.Tailnet` is a GenServer that creates its table in
> `init/1`. `Durable.Store` stays a process on purpose, and its moduledoc
> now says it is a lock with no state.

`Ops.ViewImage` (`view_image.ex:22-60`) and `Ops.SkillUse`
(`skill_use.ex:15-28`) are GenServers that do one file read in
`handle_continue/2` and stop. They ignore `:resend` and `:cancel` (63, 31),
so the registry protocol buys nothing. `ViewImage` reads up to 256 MB
(13, 34) and base64-encodes it in that process. `Photon.Tailnet` owns its
ETS table through a bare `spawn_link` plus `Process.sleep(:infinity)`
(`tailnet.ex:74-86`), outside OTP. `Durable.Store` is a process whose state
is `%{}` (`store.ex:41`); it exists as a lock, which is fine for SQLite but
worth saying out loud given H5.

### H12. Blocking work inside callbacks (low)

> Status (node): `Ops.Shell` no longer sleeps while it kills a process
> group. It polls the group with `Process.send_after/3` and postpones
> other messages until the group is gone, so the order in which it handles
> them is the same as before. Only `terminate/2` still waits in place.
> `NodeChannel.join/3` and `Tailnet.peer?/1` are hub code, unchanged.

> Status (hub): unchanged in behavior; `NodeChannel`'s and `Tailnet`'s
> moduledocs now say what blocks and why (the join waits so the registry
> never names two channels for one node; a cache miss shells out in the
> caller).

`Ops.Shell.kill_group/1` (`shell.ex:407-427`) polls with `Process.sleep`
for up to 5 s, spawning `/bin/sh` per poll, from `handle_info/2` (177, 220)
and recovery (244, 327). `NodeChannel.join/3` blocks up to 2 s waiting for
the previous connection to die (`node_channel.ex:27-43`).
`Tailnet.peer?/1` shells out to `tailscale whois` in the HTTP request
process on a cache miss, with nothing stopping concurrent misses from all
shelling out (`tailnet.ex:31-50`, called from `auth.ex:25`).

### H13. Global names make boundaries hard to test (low)

> Status (step 1): unchanged. `HarnessCase` is now `PhotonNode.NodeCase`,
> and the session tests are gone.

> Status (node): the config and the names are unchanged, since the hub
> embeds the node through `{PhotonNode, opts}` and `PhotonNode.config/0`.
> What changed is how much needs them: the node's core tests (`test/core`)
> run `async: true` with no node at all.

> Status (hub): the same move. The hub's core tests (`test/core`, about
> 170) run `async: true` with no database or processes; `DataCase` still
> wipes every table for the boundary tests, which stay serial.

The node keeps its config in `:persistent_term` (`photon_node.ex:40`) and
reads it from `Store.dir/0` (`store.ex:35`), `Coordinator` (106, 331, 791)
and `Connection` (29, 33, 165). With fixed registered names, that means one
node per VM, and `HarnessCase` stands in for the hub by registering the
test process as `PhotonNode.Connection` (`harness_case.ex:22`). Session
tests are `async: false`. On the hub, `Durable.Store` and `Scheduler` are
globally named and `DataCase` wipes every table and writes the real settings
file (`data_case.ex:27-41`), so database tests run serially too.

### H14. Logic duplicated outside the core (low)

> Status (step 1): the node's translators and `Assistant.Report` are
> gone. Tool arguments and results are translated once, on the hub, by
> `Photon.MachineTools.Translate`, which bounds output with
> `PhotonCore.Output` as the node does.

> Status (node): `Ops.Shell` reads only the two ends of a large output file
> and joins them with `Output.truncated/5`, which `Output.bound/3` uses
> too. The three translators share `Tools.decode_arguments/2` and keep
> their own error messages (which the model sees; `Message.arguments/1`'s
> differ). `Harness.busy_ids/0` is gone.

> Status (hub): the report text lives once, in
> `Photon.Assistant.Report`; `NodeWatch`'s report and `NodeWork`'s tool
> result differ only in their header, as before. `UpdateMemory`'s editing
> is `Photon.Assistant.Memory.edit/3`. `Scheduler` and `Tool` share
> `Durable.implements?/3`.

`Ops.Shell.bounded_file/2` (`shell.ex:353-393`) re-implements the head and
tail truncation in `Output.bound/3` (`output.ex:16-31`).
`NodeWork.resume/1` (`node_work.ex:71-85`) duplicates the report text in
`NodeWatch.report/2` (`node_watch.ex:46-65`). `Tools.Bash`,
`Tools.ViewImage` and `Tools.SkillUse` each define `decode/1`
(`bash.ex:68-74`, `view_image.ex:47-52`, `skill_use.ex:52-57`) next to
`PhotonCore.Message.arguments/1` (`message.ex:65-71`). `UpdateMemory`
keeps its line-editing logic in a closure inside a commit closure
(`update_memory.ex:33-48`). `Harness.busy_ids/0` (`harness.ex:76-91`) has
no callers and uses `Process.alive?/1` plus serial `GenServer.call`s.

### H15. Deep nesting (low)

> Status (step 1): `Coordinator` and `NodeTranscript` are gone.

> Status (node): `Ops.add/2` is a `with` over two small helpers; the old
> `Coordinator.add_tool_result/2` and `finish_call/3` are function heads in
> `Session`; `QuietStream` has its own file.

> Status (hub): `Provision.steps(:install, ...)` is one `with` over small
> steps (`upload/5`, `install/2`); `ToolTask.step("run", ...)` asks
> `ToolCall.plan/3` and has two clauses; `Scheduler.stop_aborted/2` asks
> `Policy` and commits per task through `abort_tx/2`;
> `NodeTranscript.fold/2` decides in function heads.

`Ops.add/2` has three nested cases (`ops.ex:18-40`).
`Provision.steps(:install, ...)` nests a `with` inside a `with`
(`provision.ex:137-158`). `ToolTask.step("run", ...)` goes case, cond, with
(`tool_task.ex:24-46`). Add `Scheduler.stop_aborted/2` from H4 and
`Coordinator.add_tool_result/2` and `finish_call/3`
(`coordinator.ex:441-504`). Separately, `Mix.Tasks.Photon.Package` defines
`QuietStream` in the same file (`photon.package.ex:24-42`), which
`AGENTS.md` rules out.

## Refactor log

Changes made after this map was written, one heading per app. Line
numbers above still refer to the original snapshot.

### apps/core

2026-10-03. Core was already the book's library case (rule 2), so the work
was inside the layers it has. It still has no processes, no application
and no supervisor, and I didn't add any.

What moved:

- `LLM.ChatCompletions` was 564 lines that mixed HTTP with the wire format.
  It's now a thin HTTP adapter (`chat_completions.ex`, about 110 lines)
  over three pure modules. `ChatCompletions.Request` builds the body and
  encodes and decodes messages. `ChatCompletions.Response` is a struct, the
  token the stream folds into (rule 39). `new/0`, `feed/2` and `finish/2`
  replace the old private accumulator map, and `feed/2` returns the events
  instead of calling `on_event`, so the fold can be tested on bytes with no
  HTTP and no callback (rules 28, 43). `Response` also owns `http_error/3`,
  `to_sse/1` and `usage/1`. `ChatCompletions.Wire` (internal) holds the
  three lenient readers both halves share, which used to be private copies.
- The retry policy left `LLM` for `LLM.Retry`: `decide/4` returns
  `{:retry, delay}` or `:give_up`, and the jitter's randomness is an
  argument (rule 29). `LLM` still does the waiting.
- `LLM.resolve/2` takes the environment lookup as a function and is pure;
  `resolve/1` passes `System.get_env/1` (H9, rule 29).
- `ID.encode/3` is the pure half of `ID.new/1`, so the format and sort
  order are testable without the clock.
- `LLM.Error` has `@enforce_keys [:kind, :message]` and a `new/3`
  constructor (rules 18, 34). Every error in core is built through it.
- A provider that leaves out a tool call's ID still gets
  `call_<index>_<unique>`, but the unique integer is now minted by the
  adapter and passed to `Response.finish/2` as a function, which keeps
  `Response` pure.

Style (rules 35-41): decisions sit in function heads now. `LLM.stream/3`'s
`cond` became one clause for the mock plus a `with` over two checks; the
fold's nested `case`s became small clauses (`add_text`, `add_reasoning`,
`add_tool_call_delta`, `note_finish`, ...); `MockAgent.respond/1` lost its
nested `case`; `SSE.parse/2` holds back a trailing CR with a guard;
`Message.arguments/1` decodes through a three-clause helper.

Types (rule 70): every public function has a `@spec`. `PhotonCore.LLM`
defines `request`, `config`, `event`, `on_event`, `response` and `provider`
types, and `PhotonCore.Message` defines `t`, `part`, `tool_call` and
`content`. The hub's `Photon.Durable.Tool` already referred to
`PhotonCore.Message.t()`, which didn't exist until now.

Tests (rules 43-56) are laid out by layer:

- `test/core/` has one file per pure module (`message`, `id`, `sse`,
  `retry`, `error`, `llm_resolve`, `chat_completions/request`,
  `chat_completions/response`, `mock`, `mock_agent`). No HTTP, no
  processes.
- `test/boundary/llm_test.exs` calls `LLM.stream/3` the way the hub and
  nodes do, against `PhotonCore.StubProvider`. It checks the request that
  goes out, events, retries, giving up, client errors, a dropped
  connection, config errors and the mock provider.
- `test/property/` keeps the properties. The streaming ones now run on the
  pure fold, and they also check that events don't depend on how the body
  was cut. One new boundary property, `llm_stream_property_test.exs`,
  checks that an answer streamed over HTTP in any chunks gives
  `LLM.stream/3` the same result and events as the pure fold.
- `test/support/` has `PhotonCore.Case` (aliases plus fixture imports),
  `PhotonCore.Fixtures` (builders with overrides), `PhotonCore.StubProvider`,
  `PhotonCore.Generators` (generators that two or three property files
  used to copy) and `PhotonCore.EchoScript`. Test files use `describe`,
  and the boundary test uses named setups (`setup :answering_provider`).
- `mix.exs` sets a coverage threshold of 95% (`mix test --cover`; it
  measures 97.8% now, up from 86.5%) and gains the same `precommit` alias
  as the hub.

Compatibility. Callers in node and hub needed no change. The public
functions they use keep their names, arities and results:
`LLM.stream/3`, `resolve/1`, `providers/0`, `provider/1`,
`ChatCompletions.stream/3`, `decode_messages/1`, `to_sse/1`,
`encode_messages/1`, `Error.message/1`, `to_map/1`, all of `Message`, `ID`,
`SSE`, `Mock` and `MockAgent`. Three `@doc false` functions with no callers
outside core are gone: `LLM.retry_delay/3` (now `Retry.delay/4`),
`ChatCompletions.encode_request/2` (now `Request.encode/2`) and
`ChatCompletions.usage/1` (now `Response.usage/1`). Building `%LLM.Error{}`
without `:kind` and `:message` no longer compiles; the node's coordinator,
the one place outside core that builds one, gives both. The wire protocol,
the node log format and the database schema are untouched.

How I checked that behavior didn't change. Core has no git history yet
(the app is untracked), so I rebuilt the original modules from their
source under an `OldCore` prefix and ran a throwaway differential property
test against the new code. It compared results, events, errors and
exceptions for streaming over HTTP (well-formed answers, calls without
IDs, arbitrary JSON, error chunks, byte soup, any chunking), HTTP and
transport errors, request encoding, message encoding and decoding,
`to_sse`, `LLM.stream/3` with retries and config errors, retry delays
under the same random seed, `resolve/1`, `Mock`, `MockAgent` and the
`Message` readers. About 3,700 generated cases per run, three seeds, no
difference. I deleted the test and the old copy afterwards. No TLA+ spec
models core or names its modules (`Durable.tla` only assumes
`LLM.stream` can return `{:error, _}`, which still holds), so there was
nothing to re-run TLC on. `docs/verification.md` now points at the moved
test files, and the core table in `docs/otp-design-guide.md` lists the new
modules.

Results: core 106 passed (16 properties, 90 tests), node 49 passed (15
properties, 34 tests), hub 80 passed (13 properties, 67 tests).
`mix compile --warnings-as-errors` and `mix format` are clean in core,
and node and hub compile cleanly against it.

Left as is, on purpose:

- `LLM.stream/3` still sleeps between retries in the caller's process.
  Both callers run it in a task, and the moduledoc now says not to call it
  from a GenServer callback (rule 96).
- Messages stay string-keyed maps rather than structs, because both
  harnesses persist them as JSON and read them back unchanged.
- `Mock.call/2` and so `MockAgent` still mint call IDs from the clock.
  Scripts are test and demo code, and the property tests already compare
  replies with the IDs stripped.
- A bug I found and didn't fix, since the brief was no behavior change: a
  negative `Retry-After` header (`-3`) becomes `retry_after: -3000`, and
  `Process.sleep/1` raises on it, which crashes the caller's request task
  instead of returning an error. (Fixed in the final review:
  `Response.http_error/3` ignores a negative value like any other
  malformed one, so the retry uses the usual backoff;
  `response_test.exs` and `llm_test.exs` cover it.)

### apps/node

2026-10-03. The node needs most of the book's layers (it runs processes,
talks to the hub and writes files), so this pass was about putting each
piece of code in the layer it belongs to. The supervision tree, the
process names and every restart policy are the same as before.

What moved:

- The session state machine left its GenServer (H1, rules 28-30 and
  39-41). `Harness.Session` is new and pure apart from minting IDs. Its
  struct is the coordinator's old state map without the process handles,
  and every function takes and returns it, so it works as a token. A step
  records what the world should see as effects, in order:
  `{:persist, kind, data}`, replies, warnings, `{:request, turn_id,
  request}`, `:cancel_request`, `{:dispatch, op}`, `{:cancel_op, op_id}`,
  and arming or cancelling the grace, heartbeat and idle timers. Every
  change that replay must reproduce goes through `apply_item/2`, live
  right after the persist effect for the same record and at start through
  `Session.replay/2`. The private functions kept their old names
  (`handle_input/3`, `decide/1`, `handle_stop/1` and so on) because the
  TLA+ operators are named after them.
- `Coordinator` is now a thin server: 990 lines before, 431 now, docs
  included. It keeps only the open log, the request task, timer references
  and operation monitors. A callback runs core steps (the event, the
  mailbox drain, `decide/1`) and runs each step's effects before the next
  step starts, so a crash still leaves a prefix of a handler's records in
  the log. One result feeds back into the core: if `Ops.add/2` fails,
  `Session.dispatch_failed/3` fails the operation, and its effects run
  before the rest. That has to happen before `decide/1` looks at the
  operations, which is why a handler is several steps and not one.
- What the core used to read for itself now arrives in its env, read once
  when the coordinator starts (rule 29): the machine line of the system
  prompt (hostname and architecture), the heartbeat interval, the shell and
  the skills. New turn, settings and heartbeat IDs still come from
  `PhotonCore.ID.new/1`, as operation IDs do in the translators. I kept
  that on purpose. Threading IDs through every event would cost more than
  tests that match on `turn_` lose, and the moduledocs say so.
- Model requests are workers in their own module, `Harness.ModelRequest`,
  with `start/3`, `cancel/1`, `config/0` and the pure `live_event/2`.
  `Harness.llm_config/0` delegates to it.
- Message tuples live in the module that handles them (rule 63). The
  coordinator's client functions are `deliver/3` (with the retry loop that
  used to be in `Harness`), `ensure_started/1`, `shutdown/1`, `report_op/2`
  (formerly `Ops.report/2` calling `Coordinator.notify/2`), `checkpoint/2`
  and `info/1`; `via/1` is private. The connection's are `event/3` and
  `live/2`, and `notify/1` is private. `Ops` owns the `:resend` and
  `:cancel` messages of operation processes.
- `Harness` is thin (rules 64, 66, 68). It validates once and calls the
  coordinator, and `ensure_session` decides in function heads.
  `working?/1` became the pure `Session.working?/1`, which
  `Harness.working?/1` still wraps because the specs cite it. `busy_ids/0`
  had no callers and is gone (H14).
- One-shot operations are plain functions now (H11, rules 2, 31, 92).
  `Ops.ViewImage.run/1` and `Ops.SkillUse.run/1` read a file and return the
  terminal snapshot, and they're tested without a process. One worker,
  `Ops.Job`, runs them off the coordinator. It is registered by operation
  ID like the two GenServers it replaces, so `Ops.add/2` and the
  coordinator's monitor see no difference.
- `Ops.Shell` stopped sleeping (H12, drift 5, rule 96). `kill_group/3`
  sends SIGTERM, then polls the group with `Process.send_after/3` (1 ms
  backing off to 50 ms, SIGKILL after five seconds). Messages that arrive
  during the wait are postponed, the way `gen_statem` postpones events, and
  handled in arrival order once the group is gone and the waiting step has
  run. So the shell handles every message in the same order and state as
  before, but it answers system messages in the meantime. A new boundary
  test checks that with a command that ignores SIGTERM. Only `terminate/2`
  still waits in place. Snapshots go through `Operation.advance/3`, and the
  head-and-tail read of a large output file joins its two ends with
  `Output.truncated/5` instead of repeating `Output.bound/3`'s logic (H14).
- Smaller changes in the core, all pure: `Operation.advance/3` and
  `fail/2`; `Output.truncated/5`, which `bound/3` now uses;
  `Tools.decode_arguments/2`, which the three translators share while each
  keeps its own error messages; `Inbox.validate/1` in function heads, with
  the same order and messages; `Context.build/1` in clauses, building its
  lists by prepending; the Bash translator's checks and formatter in heads.
- Lifecycle (rules 78-85). The tree is unchanged, and `PhotonNode`'s
  moduledoc now writes the plan down: each process type, who starts it,
  its restart and shutdown, and why the strategy is `:rest_for_one`.
- Plain sends (drift 4, rules 72 and 73). `Connection`, `Coordinator`,
  `Ops`, `ModelRequest` and `Ops.Shell` say in their moduledocs why each
  notification is a send and what bounds it.
- Types (rule 70). Every public function in `apps/node/lib` has a `@spec`,
  `PhotonNode` and `PhotonNode.Harness` first. `Session`, `Store`,
  `Config`, `Inbox`, `Context`, `Operation`, `Tools`, `Skills`, `Image`
  and `Env` define the types those specs use.
- `QuietStream` has its own file, as `AGENTS.md` asks (H15).

Tests (rules 43-56):

- `test/core` holds the pure modules: the session (32 tests on the ordering
  rules, turns, grace, stops, operation exits, heartbeats, settings, replay
  and `working?/1`), the translators, `Context`, `Inbox`, `Output`,
  `Operation`, `Image`, `Env` and `ModelRequest.live_event/2`. They run
  `async: true` with no node, no processes and no files, in well under a
  second. Sessions run through `PhotonNode.SessionDriver`, which plays the
  coordinator's part with an in-memory log, request, operations and
  timers.
- `test/boundary` calls the node the way the hub connection does
  (`harness_test.exs`, formerly `session_test.exs`). With it are
  `recovery_test.exs`, `shell_test.exs` and `connection_test.exs`, plus
  new `jobs_test.exs`, `skills_test.exs` and `config_test.exs`. The tests
  `docs/verification.md` cites kept their names and file names.
- `test/property` gained `session_property_test.exs`. It plays random
  sessions on the pure core (inputs, resends, stops, answers with valid and
  invalid calls, operations that start, finish, fail, get canceled, crash
  or exit cleanly, timers, settings changes, coordinator restarts) and
  after every handler checks what `Coordinator.tla` checks: replay
  reproduces the session, effects keep the server's view in step, a
  request starts after its turn and only one runs, operations start after
  their status, final statuses follow persisted snapshots (rule 5), a stop
  holds and swallows no input, and the context stays well formed. Once the
  world settles, every input is logged once and answered, and every call
  has one final status. 300 runs take under a second. It passed 15,000
  runs over three seeds, and I checked that it has teeth: putting back F2,
  F4, a request before its turn, F10, or a live change that replay can't
  see each made it fail.
- `test/support` has `PhotonNode.Case`, `PhotonNode.Fixtures` (builders
  with overrides, shared with the boundary tests, which dropped their
  private copies), `PhotonNode.SessionDriver`, `PhotonNode.HarnessCase` and
  `PhotonNode.TestScript`. Tests use `describe` with named setups, and
  logs are captured. `mix.exs` sets a coverage threshold of 85% (86.6% now,
  leaving out the CLI, the packaging task and test support) and has the
  same `precommit` alias as core.

Compatibility. Nothing outside the node had to change. The hub starts the
node with `{PhotonNode, opts}` and sets `config :photon_node, autostart:`
and `llm:`, and both work as before; `PhotonNode.start_link/1`,
`config/0` and `Config.new/1` are unchanged. The wire protocol, the
session log format and the hub database are untouched. These keep their
names, arities and results: `Harness.deliver/3`, `stop/1`, `delete/1`,
`resume_all/0`, `llm_config/0`, `valid_id/1` and `working?/1`;
`Coordinator.start_link/1`, `whereis/1`, `checkpoint/2` and `info/1`; all
of `Store`; `Ops.add/2` and `Ops.cancel/1`; `Connection.live/2`. So do the
messages the test stand-ins rely on: `{:event, ...}`, `{:live, ...}`,
`{:op_update, op}`, the `{:deliver, config, input}` call, `:resend` and
`:cancel`. These went away, with no callers outside the node:
`Harness.busy_ids/0`, `Connection.notify/1` (now `event/3`),
`Coordinator.notify/2` (now `report_op/2`), `Ops.report/2` and a public
`Coordinator.via/1`. `Ops.ViewImage` and `Ops.SkillUse` are no longer
GenServers. The coordinator's process state is now
`%Coordinator{session: %Session{}, ...}`, so anything that reads it with
`:sys.get_state/1` (two tests did) reads `.session`.

How I checked that behavior didn't change:

- The original 49 node tests passed against the new code before I moved
  any of them, after one edit in two tests (the `.session` path above).
  The crash-and-replay property passed with `PHOTON_PROPERTY_RUNS=150`,
  and again at 100 at the end.
- I built the original node (from a copy I took before starting) and the
  new one as throwaway projects in `/tmp`, ran the same 14 scenarios
  through both with the mock model, and compared their session logs after
  normalizing IDs, timestamps, paths, process groups, and the mock's token
  estimates (which depend on the length of the temporary path). The
  scenarios: a command, help, a repeated input, a disallowed tool, an
  image, a slow command whose result wakes a later turn, a stop that kills
  a running command, resuming a call logged without a status, a vanished
  tool, a stop re-armed from the log, a background child, a settings
  change, a nonzero exit, and a heartbeat. The logs were identical in all
  three runs. I also started the new node against a closed port to watch
  the real connection process keep reconnecting while a session ran. The
  copies are deleted.
- TLC. The specs changed only in comments that point at the code (I
  compared them with comments stripped), and I re-ran every config.
  All 16 `NodeSync` configs and the 19 `Coordinator` configs that should
  pass do, each with the same number of distinct states as recorded in
  `specs/tla/NodeSync.md` and `specs/tla/Coordinator.md` (for example
  1,955,546 for `Coordinator-faults.cfg` and 254,532 for
  `NodeSyncFixedNet.cfg`). `Coordinator-witness.cfg` violated all six of
  its witness invariants, as it should, before TLC 2.19 threw the same
  internal `ArrayIndexOutOfBoundsException` the notes describe.

Small differences, none of them visible in a log:

- The machine line of the system prompt reads the hostname when the
  coordinator starts, not at every settings change and replay. It differs
  only if the hostname changes while a coordinator runs.
- The old code computed `get_in(input, ["payload", "mode"])` for every
  accepted input, which raises (after persisting the input) for a `crash`
  input whose payload is a string or a list, and that restarted the
  coordinator. The new code decides by pattern and doesn't raise. Nothing
  sends `crash` inputs.
- A bug in the pure core would now raise before any of that step's effects
  run, where the old code had done some of them already. That matters only
  for a crash, and an empty prefix is still a prefix.
- If the node shuts down while a shell waits for a killed group,
  `terminate/2` finishes the kill but doesn't run the step that waited.
  That step would only report to the coordinator, which shuts down first.

Left as is, on purpose:

- Namespaces (rule 5). The modules keep their names instead of moving
  under `Core` and `Boundary` prefixes, because the specs,
  `docs/verification.md` and the hub's docs cite them. Each module's layer
  is listed in `PhotonNode.Harness`'s moduledoc and in the module map
  above.
- The config in `:persistent_term` and the global names (H13), which the
  hub's embedding relies on.
- The mailbox drain's selective receive with its 1 ms quiet window. It
  decides which inputs share a decision, and `Coordinator.tla` models it.
- Live streaming (H6) and boot reading whole logs (H7).
- `Ops.add/2` still asks `Process.alive?/1`. That is the
  node-op-stale-registry fix.
- `Session` is long, about 970 lines with a fifth of that docs and types.
  It is one state machine, and splitting it would turn its private helpers
  into an internal API.

Results: core 106 passed (16 properties, 90 tests), node 125 passed (16
properties, 109 tests), hub 80 passed (13 properties, 67 tests).
`mix compile --warnings-as-errors` (dev and test) and `mix format
--check-formatted` are clean in node, and hub and core compile and pass
against it.

### apps/hub

2026-10-03. The hub needs all of the book's layers. It holds state in
SQLite, runs task steps and provisioning jobs as processes, and serves
browsers and nodes. So, as in the node, this pass put each piece of code
in the layer it belongs to. Process names, restart policies and the
wire, log and database formats are the same; the one change to the tree
is that the durable trio now has a supervisor of its own.

What moved:

- The scheduler's rules left its GenServer (H4, drift 2, rules 28-30).
  `Durable.Policy` is new and pure: which steps to kill, which marked
  tasks can be aborted (bottom-up), when a waiting task wakes (`wake?/3`
  takes the statuses of the tasks it waits on and whether its signal is
  recorded), what `fail_fast` aborts, whether a pending task starts, what
  a failure does, and the timer's delay. `Durable.Scheduler` reads the
  facts for each task right before it decides, with the same queries in
  the same order as before, and applies each decision in its own commit,
  which re-reads the task and asks the policy again (`abort?/1`,
  `wakeable?/1`, `startable?/1`, `failable?/1`). That keeps the
  interleavings `Durable.tla` checks. Its state is a struct, and its
  moduledoc says what a crash loses and why `notify/2` is a plain send.
- The task kinds decide in pure modules and commit at the edge (drift 2).
  `Durable.Turn` holds a generation's request, what an answer leads to
  (`outcome/2`: an answer, a tool round, or the round limit), and the
  entries, settlements and transitions that record it; `Generation`
  reads, calls the model and commits, and `follow/5` takes the outcome in
  function heads. `Durable.ToolCall` decides whether a call runs
  (`plan/3`: tool gone, unsafe rerun, bad arguments, or execute) and how
  its result is recorded; `ToolTask` finds the tool, runs it and commits.
  `Durable.Inbox` holds the submission rules (`submit_action/3`: an
  earlier request ID, reject, queue, or start a run; `next_input/1`).
  `NodeWatch` and `Routine` got small pure helpers (`call_live?/1`,
  `after_fire/2`, ...).
- The commit boundary is explicit (H5). `Tx.run/1`, which only `Store`
  calls, opens a commit, keeps its change list (still in the Store's
  process dictionary, now `Tx`'s own detail) and hands the changes back.
  `%Tx{}` carries a reference to its commit, and a write through a `Tx`
  that isn't the calling process's open commit raises `ArgumentError`
  before it touches the database. Of everything here, this is the change
  most likely to bite: a misuse that used to write silently now crashes.
  Nothing in the repo did that, and the tests check both sides. Reads go through `Durable.Queries` (one
  query per question, shared by `Durable`, `Tx` and the scheduler), so
  `Durable.busy?/1` no longer builds a `%Tx{}`. What a commit announces is
  the pure `Durable.Changes.summarize/1`, which builds its lists by
  prepending (rule 21). `Store` is a dozen lines of callback, and its
  moduledoc says it is a lock with no state.
- Lifecycle (rules 78-85). `Durable.Supervisor` is new. It runs the task
  supervisor, the Store and the scheduler, `:one_for_one` on purpose (a
  scheduler restart leaves its steps running and fences them), with the
  plan in its moduledoc. `DataCase` starts its `children/0`, so tests run
  the same child specs as the app. `Photon.Application`'s moduledoc writes
  down the whole tree: each child, why it comes where it does, why the
  strategy is `:one_for_one`, and what shutdown does.
- Node sessions (H3). Every write goes through `Durable.Store`, which is
  now the only writer. That covers `start/3`'s insert, `send_input/3`'s
  insert and touch (now one transaction), and `delete/1`'s three deletes
  (one transaction).
  Broadcasts and pushes follow the commit as before. The rules are the
  pure `NodeSessions.Mirror`: where a record goes (`place/3`), what it
  changes (`effect/1`), what a refusal changes (`rejectable?/2`,
  `refused_session/2`), and the shapes the hub stores and sends.
  `subscribe/0` and `subscribe/1` hide the topics.
- The assistant. `Assistant.Prompt` builds the system prompt from
  settings, memory and the time (H9); `Assistant.Memory` edits memory
  (it was a closure inside a commit closure, H14); `Assistant.Report` is
  the one copy of how node work's outcome reads, used by the watcher's
  report and the tool's result, which differ only in their header (H14).
  `NodeWork.resume_result/3` is the F1 decision as a pure function of the
  signal and whether a report was posted. `Photon.Assistant` is now the
  context the assistant page uses: `subscribe/1`, `entries/1`, `busy?/1`,
  `queued/1`, `withdraw/1`, `fresh_start/1`, `cancel_schedule/1`.
- `Photon.Settings` (H9). Functions of a settings map no longer default
  their argument to a file read; `defaults/1`, `key?/2` and `env_key?/2`
  take the environment as a function, and `normalize/2` the defaults.
  `model_label/1` (from the shell hook) and `env_key?/2` (from the
  settings page's `render/1`) moved here.
- Provisioning (H10, H15). Jobs start with `async_nolink` and the server
  monitors them, so a job that dies without reporting is marked failed
  instead of leaving its machine busy. `Provision.Jobs` (the job table's
  rules) and `Provision.Script` (the probe, upload, installer input, ssh
  arguments and failure reasons) are pure; `steps(:install, ...)` is one
  `with` over small steps. `Provision.Lines` moved to
  `provision/lines.ex`.
- `Photon.Tailnet` is a GenServer that creates its cache table in
  `init/1`, in place of a bare `spawn_link` parked on
  `Process.sleep(:infinity)` (drift 6, rules 80, 91, 96). Lookups still
  go straight to the table.
- `NodeTranscript` decides in function heads and builds its list of
  changed items by prepending; `Nodes.roster/2` (from the shell hook) and
  `Nodes.sort/1` are pure.
- The web layer holds no business logic and no I/O in `render/1` (H8).
  The shell hook calls `Nodes.roster/2`, `Settings.model_label/1` and
  `Assistant.busy?/1`. `AssistantLive` talks only to `Photon.Assistant`
  and folds with `Assistant.Transcript` (the entry index, the in-flight
  answer, a call's status), the way `SessionLive` drives `NodeTranscript`.
  `SessionLive` subscribes through `NodeSessions` and reads whether the
  node is online on mount and on `:nodes_changed`. `NodesLive` reads nodes
  and session counts (a count query instead of loading up to a thousand
  rows per node) on mount and on change messages, and runs `tailscale`
  with `start_async`. `SettingsLive` reads the environment in its event
  handlers.
- Plain sends and broadcasts (drift 4, rules 72, 73) say in their docs
  why they are not calls and what bounds them: `Scheduler.notify/2`,
  `Nodes.command/3`, `Durable.live/2`, `ToolAPI.output/2`,
  `NodeSessions.live/2`. `NodeChannel`'s moduledoc says why its join may
  wait two seconds.
- Types (rule 70). Every public function in `apps/hub/lib/photon` has a
  `@spec`, the context modules first, and so do the web modules other
  than function components and the Phoenix scaffolding (`PhotonWeb`, core
  components, layouts, error views). The schemas define `t/0` (several
  specs already named `TaskRecord.t()`, which didn't exist). `Tx.t/0` is
  opaque. `ToolAPI` has a `new/1` constructor and `@enforce_keys`, and
  `Runtime` enforces `:task` (rules 18, 34). `Photon`'s moduledoc lists
  the contexts and where each layer lives.

Tests (rules 43-56):

- `test/core` (171 tests, 0.4 s, `async: true`, no database, no
  processes) covers the pure modules: `Policy`, `Inbox`, `Turn`,
  `ToolCall`, `Changes`, `Context` and `Schema`; the assistant's `Report`,
  `Prompt`, `Memory`, `Transcript`, `MockScript` and the pure parts of
  `NodeWork`, `NodeWatch` and `Routine`; `NodeSessions.Mirror`,
  `NodeTranscript`, `Nodes`, `Settings`, `Provision.Jobs`,
  `Provision.Script`, `Tailnet` and `NodeDist`.
- `test/boundary` (59) calls the contexts through their APIs:
  `durable_test.exs` (now with the H5 tests: a stale `Tx` raises and
  writes nothing, reads need no commit, a raising commit stores nothing),
  the new `durable_lifecycle_test.exs` (the supervisor's children; a
  scheduler crash restarts it alone and work goes on),
  `durable_regression_test.exs`, `node_sessions_test.exs`,
  `node_work_test.exs`, `assistant_test.exs`, the new
  `assistant_tools_test.exs` (every tool through `execute/2`), and
  `node_install_test.exs` (now with the H10 test).
- `test/web` (46): the node channel, controllers, plugs, and new tests
  for each LiveView (`assistant_live_test.exs`, `session_live_test.exs`,
  `nodes_live_test.exs`, `settings_live_test.exs`) that drive the events
  and messages the refactor touched.
- `test/property` (13) is unchanged apart from paths.
- `test/support` has `Photon.Case` (aliases plus fixture imports; its
  moduledoc describes the layout), `Photon.Fixtures` (builders with
  overrides) and `Photon.Eventually` (a bounded poll for OS processes,
  which replaced `node_install_test.exs`'s two sleeps, drift 7). Tests use
  `describe` with named setups, and logs are captured. `mix.exs` sets an
  85% coverage threshold: 87.8% now, against 72.8% for the original code
  measured the same way. The regression tests `docs/verification.md`
  cites kept their names and file names.

Compatibility. The wire protocol, the node session log and the database
schema are untouched; there is no migration. Callers outside the hub
needed no change. These kept their names, arities and results: all of
`Durable` (plus `implements?/3`), `Store.commit/2`, `Tx`'s operations,
`Runtime`, `Scheduler.notify/2`, `sync/0` and `wake?/2`, the task kind and
tool behaviours, `NodeSessions`, `Nodes`, `Assistant`'s old functions,
`NodeWork`, `NodeWatch.report/2`, `Provision.run/2`, `jobs/0`, `topic/0`
and `ssh_reason/1`, `Tailnet.status/0`, `peer?/1`, `own_names/0` and
`parse/1`, and `NodeTranscript`. These changed, with every caller in the
hub updated: `Settings.model/1`, `key?/1`, `llm_config/2` and
`node_config/1` lost their `\\ load()` defaults (`key?` gained an
optional environment argument, `normalize/1` still works);
`Tailnet.start_cache/0` and its custom `child_spec/1` are gone (it is a
GenServer); a `Tx` write outside its commit raises. The rest are
additions.

How I checked that behavior didn't change:

- I kept a copy of the original hub. Its 80 tests, unmodified, pass
  against the new code.
- The other way round, I ran the new boundary and web tests (105) against
  the original code in a throwaway copy, adapting only the calls to new
  functions. 99 pass. Of the six that fail, four pin intended changes
  (the new supervisor module, twice; the H5 guard; the H10 fix) and two
  found incidental differences, listed below.
- I ran the full suite after each step, the final one three times, and
  the properties once more with `PHOTON_PROPERTY_RUNS=150`.
- TLC. The specs changed only in comments that point at the code, now by
  function name instead of stale line numbers (I compared them with
  comments stripped). I re-ran all 16 `NodeSync` configs and all 20
  `Durable` configs. Every one finished with no error and the same number
  of distinct states as recorded in `specs/tla/NodeSync.md` and
  `specs/tla/Durable.md` (for example 15,170,316 for
  `Durable-parallel.cfg`, 6,087,848 for `Durable.cfg` and 254,532 for
  `NodeSyncFixedNet.cfg`). `Coordinator.tla` doesn't model hub code and
  didn't change.

Small differences:

- A tailnet read that crashes (`PHOTON_TAILSCALE` pointing at a file that
  can't be run) now shows as an error on the nodes page. Before, it ran
  in the LiveView process and crashed the page.
- The nodes page updates a node's session count when sessions change.
  Before, the count was computed in `render/1`, which LiveView only
  re-evaluated when the list of nodes changed, so a new session showed
  only after the next node event.
- The session page notices a node going online or offline on
  `:nodes_changed`, as the sidebar always did, rather than at its next
  render.
- A provisioning job that dies without reporting is marked failed; before,
  its machine stayed "already busy" until the hub restarted.
- `send_input/3`'s two writes and `delete/1`'s three are each one
  transaction now, and node-session writes queue behind other commits in
  the Store.
- The durable trio's restarts are counted by its own supervisor (three in
  five seconds) rather than by `Photon.Supervisor`.

Left as is, on purpose:

- Namespaces (rule 5). As in the node, modules keep their names rather
  than move under `Core` and `Boundary` prefixes, because the specs and
  `docs/verification.md` cite them. `Photon`'s and each context's
  moduledoc lists which modules are core.
- The scheduler still scans the live tasks on every reconcile and commits
  each decision on its own. One commit per pass would be cheaper but would
  change the interleavings `Durable.tla` checks.
- The shell hook still rebuilds per tab on every message, the assistant
  page keeps the history's tool results in assigns, and live text is
  re-rendered as Markdown per delta (H6, H8).
- `NodeChannel.join/3` still waits up to two seconds for a replaced
  connection, and `Tailnet.peer?/1` still shells out in the caller on a
  miss (H12). Both are documented.
- `Photon.Supervisor` stays `:one_for_one`; its moduledoc says what a
  `PubSub` or `NodeRegistry` restart would drop.
- `NodeWatch`'s wait for the node's answer still has no deadline (H3's
  safety net); adding one would change behavior.
- A `Provision` restart still loses the job table.
- `ModelProxyController` keeps its request shaping; it is protocol
  plumbing at the edge.
- `DataCase` still wipes every table, so boundary tests run serially
  (H13).
- `.cursor/skills/verify-photon/SKILL.md` names a playground test that was
  deleted before this pass. It is outside `apps/hub` and the docs, so I
  left it.

Results: core 106 passed (16 properties, 90 tests), node 125 passed (16
properties, 109 tests), hub 289 passed (13 properties, 276 tests), up from
80. `mix compile --warnings-as-errors` (dev and test), `mix test
--warnings-as-errors` and `mix format --check-formatted` are clean in the
hub.

### Enforcement pass (all three apps)

2026-10-04. Credo (with Photon's own checks in `tools/credo_checks`),
Boundary and Dialyzer now check the rules in `docs/otp-design-guide.md`;
that guide's last section says how. Making the layering checkable moved a
few things, none of which changes behavior, the wire protocol, the session
log or the database:

- Node: the harness announces log records and live output through
  `Harness.Link`, a behaviour `PhotonNode.Connection` implements (the
  link module is `PhotonNode.Config`'s `:link`, the connection by
  default), so the connection depends on the harness and not the other
  way round. The connection replays through `Harness.records_from/2`.
  The skills section of the system prompt moved from `Harness.Skills`
  (which reads the workspace) to the pure `Harness.SkillPrompt`;
  `Skills.prompt/1` delegates to it.
- Hub: the install script and the node socket URL moved to the pure
  `Photon.InstallScript`; `NodeDist.install_script/1` and
  `Hub.node_socket_url/1` delegate to it, and `Provision.Script` no longer
  depends on either. The node channel registers through
  `Photon.Nodes.register/2` and `unregister/1`, which own the node
  registry and the takeover of a replaced connection.
- Smaller refactors where a check asked for one: long functions split
  into named steps (`Ops.Shell.prepare/1`, `Durable.Context`'s pairing,
  `Durable.Schema.validate/2`, the assistant's mock script and tools,
  `ModelProxyController`, `NodesLive`'s provisioning), `Harness.Context`'s
  result items became maps, `Mirror.session/5` takes the config as an
  option, and `Provision.Lines` collects lines by prepending.
- The coordinator's `session` and the durable steps' `durable_task` log
  metadata are now in the formatter config, so they appear in the logs.

### Step 1: machine tools (all three apps)

2026-10-06. Step 1 of `docs/projects-and-blip.md`, planned in
`docs/plans/step-1-machine-tools.md`, made nodes executors and gave Blip
`shell`, `view_image` and `list_machines` on every machine. It came in two
parts: the first added the new path next to node sessions, the second
deleted what it replaced. The module map and supervision trees above are
the result.

What was added:

- Core: `PhotonCore.Operation` and `PhotonCore.Output` moved here from the
  node, since the hub reads results too, and `PhotonCore.Operation.Wire`
  builds and parses the `op.*` messages for both sides.
- Node: `PhotonNode.Executor`, one process for all of the hub's
  operations, with its journal (`Executor.Journal`), its pure rules
  (`Executor.Rules`, `Executor.Request`) and its hub link
  (`Executor.Link`). Operation processes report to an owner
  (`Ops.Owner`), which is now always the executor.
- Hub: `Photon.Machines` (the registry of connected nodes, folded in from
  `Photon.Nodes`, and the `machine_ops` rows) with its pure
  `Machines.Rules` and `Machines.Roster`; `Photon.MachineTools`, the
  durable tools, with the pure `Translate` and `Wait`; images in Blip's
  conversation served by `BlipImageController`; and a hub-plus-node test
  over a real websocket.

What was deleted:

- Hub: Blip's node-session tools (`run_on_node`, `message_node_session`,
  `check_node_session`, `stop_node_session`, `list_nodes`),
  `Assistant.NodeWork`, `NodeWatch`, `Report` and `Page`;
  `Photon.NodeSessions` and its schemas and `Mirror`;
  `Photon.NodeTranscript`; `PhotonWeb.SessionLive` and `/sessions/:id`;
  `Settings.node_config/1`; the model relay (`ModelRelayController`,
  `NodeAuthPlug`, `POST /node/llm/stream`); `Photon.Nodes`, whose
  registry is now `Photon.MachineRegistry`; the node-sessions migration.
- Node: the whole session harness (`Harness`, `Session`, `Coordinator`,
  `Store`, `Context`, `Inbox`, `ModelRequest`, `Link`, `Skills`,
  `SkillPrompt`, the tool translators, `Ops.SkillUse`, the prompts), the
  `SessionRegistry`, `TaskSupervisor`, `SessionSupervisor` and `:resume`
  children, and the session handlers in `Connection`, which now speaks
  only `ops:1`. `Harness.Ops*`, `Env` and `Image` became `PhotonNode.Ops*`,
  a boundary of their own.
- Core: `LLM.Relay`, `LLM.Relay.Wire`, `LLM.MockAgent` and
  `Operation.new/4`, which minted IDs.
- Specs: `NodeSync` went; `Coordinator` became `Executor`, which models
  the executor and its operation processes; `Durable` models a machine
  tool call in place of node work (`docs/verification.md`).

Layers. Every new decision is in a strict-Boundary pure module, and none
of the new code adds a hub process: a tool call's state is its durable
task and its row, and each node's channel, already a process, is the
transport (rules 3, 31, 89). On the node, `PhotonNode`'s moduledoc writes
down the new lifecycle: `OpRegistry`, `OpSupervisor`, `Executor`,
`Connection`, `:rest_for_one`. `.credo.exs` in each app lists the new
core modules and process names, and drops the deleted ones.

Compatibility. None, on purpose. The hub database and every node install
are wiped: no migration reads old rows, the old database's node keys are
gone with it, and a node without the `ops:1` capability is reported as
outdated rather than sent work.

Results at the end of step 1: core 187 passed (12 properties, 175 tests),
node 98 passed (1 property, 97 tests), hub 483 passed (12 properties, 471
tests), with `mix precommit` clean in all three.

### Step 2: projects and threads (hub and node)

2026-10-06. Step 2 of `docs/projects-and-blip.md`, planned in
`docs/plans/step-2-projects-and-threads.md`, added projects (a purpose and
freeform context files, for any body of work) and threads (durable agent
conversations in a project that work in its folder on any machine). The
module map and supervision trees above are the result.

What was added:

- Hub, domain: `Photon.Projects` with its schemas (`Project`,
  `ContextFile`) and pure `Projects.Rules`; `Photon.Threads`, the
  `"thread"` profile, with its schema (`Thread`), its pure `Rules`,
  `Prompt` and `MockScript`, and four context-file tools
  (`Threads.Tools.*`); `Photon.Assistant.Page`, the page under Blip's
  panel and the note its model sees; `MachineTools.Guide` and
  `MachineTools.MockPhrases`, the prompt lines and mock phrasings Blip and
  threads share.
- Hub, harness: `Tx.announce/3` (a message broadcast only after its
  commit, collected by `Changes` and sent by the `Store`), the optional
  `Profile.workdir/1` that `ToolTask` hands tools in `ToolAPI.workdir`,
  and `Durable.busy/1`, `busy_in_profile/1` and `last_entries/3`.
- Hub, web: the project pages (`ProjectNewLive`, `ProjectLive`,
  `ContextFileLive`, `ThreadLive`) and their words (`ProjectText`); the
  sidebar with projects and their threads (`Shell`, `Layouts`); the
  conversation pieces Blip's panel and a thread page share
  (`ConversationComponents`, `ConversationView`); the thread image route.
- Node: `Ops.Shell` creates a missing working directory before the
  `process` checkpoint, and the node joins with `ops:2`.

What moved or changed:

- `Photon.Assistant.Transcript` became `Photon.Transcript` (with
  `typed/2`), since both conversation pages fold with it.
  `PhotonWeb.BlipImageController` became `ConversationImageController`
  (`blip/2`, `thread/2`). `reasoning/1` moved from `Assistant.Prompt` to
  `Photon.Settings`.
- The machine tools put the conversation's working directory in each
  op's `directory`, and say "your working directory". `Machines.joined/1`
  and `push_for/2` push nothing to a machine connected without `ops:2`,
  and a call parked on one ends with the outdated message.

Layers. No new process and no registered name: projects, files and
threads are rows written in Store commits, a thread runs on the durable
harness as Blip does, and every decision is in a strict-Boundary pure
module (rules 2, 3, 28, 31). A thread's file write happens inside the
commit that records its tool result, and its announcement goes out only
after that commit. `apps/hub/.credo.exs` lists the new core modules in
`FunctionalCore` (with `PhotonWeb.ProjectText`) and adds
`Photon.Projects` and `Photon.Threads` to `ProcessNameOwnership`'s API
modules.

Compatibility. None, on purpose. The new tables come in new migrations
and the hub database is deleted. Nodes join with `ops:2`, and the hub
sends no operations to a node without it, so every node is reinstalled
once.

Results at the end of step 2: core 187 passed (12 properties, 175 tests;
unchanged), node 105 passed (1 property, 104 tests), hub 689 passed (12
properties, 677 tests), with `mix precommit` clean in the node and the hub.

### Step 3: skills and schedules (hub)

2026-10-06. Step 3 of `docs/projects-and-blip.md`, planned in
`docs/plans/step-3-skills-and-schedules.md`, added skills (instructions
an agent loads when a task calls for them, turned on per project and for
Blip) and moved schedules into projects (a project's schedule starts a
new thread there each time or wakes one of its threads; Blip keeps its
own). Only the hub changed. The module map and supervision trees above
are the result.

What was added:

- Hub, skills: `Photon.Skills` with its schemas (`Skill`, `Enablement`),
  the pure `Rules`, `SkillMd` (the SKILL.md subset), `Source` (links,
  GitHub trees and candidates) and `Prompt` (the prompt section and what
  a load returns), `Skills.Fetch` (the only HTTP), `MockPhrases`, and a
  `load_skill` tool for each profile (`Assistant.Tools.LoadSkill`,
  `Threads.Tools.LoadSkill`). Both profiles' prompts list the skills
  enabled for them.
- Hub, schedules: `Photon.Schedules` with its schema (`Schedule`) and
  pure `Rules` (input, arming after an edit, the next time, and what a
  firing does under the consent and overlap rules), and
  `Schedules.Routine`, the `"routine"` task kind.
- Hub, threads: `Threads.start_tx/4` and `send_tx/4` are public, with a
  `:source` and a `:request_id`, so a firing starts or wakes a thread
  inside its own commit; the thread prompt says what a `[Scheduled]`
  message is.
- Hub, web: the Skills page, a skill's page and the install page
  (`SkillsLive`, `SkillLive`, `SkillInstallLive`), the schedule form
  (`ScheduleLive`), the project page's Skills and Schedules sections, the
  thread page's Schedule link, `#nav-skills` in the sidebar; the shared
  `TimeComponents` (times in the browser's zone), `EditorComponents`
  (the unsaved-text guard, tabs and banner, moved out of
  `ContextFileLive`), `ScheduleComponents`, `CoreComponents.switch/1`,
  and the pure `ScheduleText` and `SkillText`.
- Specs: `specs/tla/Durable.tla` models repeating routines with edits
  and deletes, with five new configs (`specs/tla/Durable.md`).

What moved or changed:

- `Photon.Assistant.Routine` became `Photon.Schedules.Routine`. Its task
  is now only a schedule's timer: the definition and the last firing are
  on the row, and every edit or delete replaces or retires the task in
  the same commit, so the step fence keeps an old task from firing.
- Blip's `schedule`, `list_schedules` and `cancel_schedule` work over
  `Photon.Schedules` on Blip's schedules only. `Assistant.stop/0` keeps
  scheduled prompts through `Durable.Submission.background?/1`;
  `Threads.stop/1` still withdraws them.
- The overlap rules are new and cover Blip's schedules too: a
  new-thread schedule skips while its last thread runs, and a prompt
  doesn't queue behind one of its own.
- The Settings checkbox for scheduled work names every schedule, not only
  Blip's. A scheduled thread's first title drops the `[Scheduled] `
  prefix.

Layers. No new process and no registered name: skills and schedules are
rows written in Store commits, a schedule's timer is a durable task, and
a fetch runs in the install page's `start_async` task (rules 2, 3, 31,
61, 89). A skill load and a firing each read what they decide on inside
the commit that applies it. `apps/hub/.credo.exs` lists the new core
modules in `FunctionalCore` (with `PhotonWeb.ScheduleText` and
`PhotonWeb.SkillText`) and adds `Photon.Skills` and `Photon.Schedules` to
`ProcessNameOwnership`'s API modules. `Photon.Threads` is over
`ModuleDependencies`' limit by one once it reads `Photon.Skills`, since it
is both the context and the `"thread"` profile; the check is off for that
module, with the reason above it.

Compatibility. None. Two new migrations add the `skills`,
`skill_enablements` and `schedules` tables, and Blip's old routine tasks
are not carried over, so the hub database is deleted. Nodes are
unchanged.

Results at the end of step 3, after the implementation review: core 187
passed (12 properties, 175 tests; unchanged), node 105 passed (1
property, 104 tests; unchanged), hub 1049 passed (12 properties, 1037
tests). `mix precommit` and `mix dialyzer` are clean in all three apps;
`mix test --cover` gives core 99.1%, node 85.9% and hub 94.7% (thresholds
95, 85 and 85).

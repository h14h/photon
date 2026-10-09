# Photon architecture by OTP layer

This is the developer's map: which part of the code plays which layer from
*Designing Elixir Systems with OTP*, how the processes are supervised, and
where a change has to go through the durable commit line. `ARCHITECTURE.md`
explains the product; `docs/otp-design-guide.md` has the rules these layers
follow; each module's `@moduledoc` has its contract.

The layers:

- **data**: structs, Ecto schemas and the shapes that move between layers
- **functional core**: pure functions over that data (strict Boundary
  sub-boundaries, listed in each app's `.credo.exs` under `FunctionalCore`)
- **boundary**: the APIs callers use and the adapters that touch files,
  network, database, environment and other processes
- **lifecycle**: applications, supervisors, boot work
- **workers**: processes that do the concurrent work

## The three apps

**`apps/core` (`:photon_core`)** is a library with no processes. It holds
the message format (`PhotonCore.Message`), IDs, the model client
(`PhotonCore.LLM`: the Responses API with a Sign in with ChatGPT token, and
a scripted mock), and what the hub and nodes share about operations: the
snapshot (`PhotonCore.Operation`), the `op.*` messages
(`PhotonCore.Operation.Wire`) and output bounds (`PhotonCore.Output`).
Model requests run in whichever process calls `PhotonCore.LLM.stream/3`.

**`apps/node` (`:photon_node`)** runs the hub's operations and nothing else.
One process, `PhotonNode.Executor`, owns a journal of every operation on
disk, starts one worker per operation (`Ops.Shell`, or `Ops.Job` for
`view_image`), monitors them, and forwards their snapshots to the hub
connection. Its decisions are the pure `Executor.Rules` and
`Executor.Request`. The node has no model and no state beyond the journal.
`docs/operations.md` has the protocol.

**`apps/hub` (`:photon`)** is the Phoenix app: the durable harness, the
agents and their tools, every context, and the web UI.

## Hub contexts

Every context below is an API module over the database and the Store's
commit line, with no process of its own unless the table says so. Its pure
decisions are in a `Rules` (or similarly named) module beside it.

| Context | What it owns | Functional core | Data |
| --- | --- | --- | --- |
| `Photon.Durable` | The harness: conversations, entries, inbox, tasks, signals, docs; commits and subscriptions | `Context`, `Schema`, `Inbox`, `Policy`, `Turn`, `ToolCall`, `Changes`, `Queries` | `Conversation`, `Entry`, `Submission`, `TaskRecord`, `Signal`, `Doc` |
| `Photon.Assistant` | Blip: the `"assistant"` profile, its prompt, memory, page notes and 21 tools | `Prompt`, `Page`, `Memory`, `Notice`, `Origin`, `Readout`, mock scripts | (durable docs) |
| `Photon.Threads` | Threads: the `"thread"` profile, titles, state, the board | `State`, `Rules`, `Prompt`, mock scripts | `Thread` |
| `Photon.Projects` | Projects and their context files | `Rules` | `Project`, `ContextFile` |
| `Photon.Skills` | Skills, where each is on, install from a link | `Rules`, `SkillMd`, `Source`, `Prompt` | `Skill`, `Enablement` |
| `Photon.Schedules` | Schedules and their `"routine"` timer tasks | `Rules` | `Schedule` |
| `Photon.Signals` | What reaches Blip unasked: thread updates, questions, digest items | `Rules`, `Text` | `DigestItem` |
| `Photon.Questions` | `ask_blip` questions | `Rules` | `Question` |
| `Photon.Activity` | The log of what Blip did | `Rules` | `Action` |
| `Photon.Ambient` | Ambient mode: the setting, digests and the daily review (`"ambient"` timer tasks) | `Rules`, `Text` | (a durable doc) |
| `Photon.Machines` | Connected nodes and their operations (`machine_ops` rows) | `Rules`, `Roster` | `Op` |
| `Photon.MachineTools` | The `shell`, `view_image` and `list_machines` tools both agents share | `Translate`, `Wait`, `Guide` | |
| `Photon.Transcript` | What a conversation page shows (pure, shared by Blip's panel and thread pages) | itself | |
| `Photon.ChatGPT` | The ChatGPT account: sign-in, tokens, one refresh at a time (a GenServer) | `OAuth` | |
| `Photon.NodeKeys` | Each node's key, its device, revocation | | `Key` |
| `Photon.Provision` | SSH installs, as monitored tasks (a GenServer job table) | `Jobs`, `Script`, `Lines` | |
| `Photon.Settings`, `Photon.Auth`, `Photon.Tailnet`, `Photon.Paths`, `Photon.Events` | Settings file, GUI access, the `tailscale` CLI and its cache, locations, PubSub announcements | `Settings`' functions of a map, `Tailnet.parse/1` | |

`PhotonWeb` is a client of these: its LiveViews call the contexts' APIs,
do no I/O in `render/1`, and put the pages' words in pure `*Text` modules
(`ThreadText`, `ScheduleText`, `SkillText`, `ProjectText`, `ActivityText`,
`AmbientText`). Blip's panel (`BlipLive`) and a thread's page
(`ThreadLive`) draw a conversation with the same pieces
(`ConversationComponents`, `ConversationView`, `Photon.Transcript`).
`PhotonWeb.NodeChannel` is the server layer for a connected node: it hands
every message to `Photon.Machines` and is the only place an `op.start` is
built.

## How a change is made

Every durable write is a commit through `Photon.Durable.Store`, a single
`GenServer.call` writer with no state. Inside a commit, `Durable.Tx` writes
rows and records announcements (`Tx.announce/3`), which the Store
broadcasts through `Photon.Events` only after the commit. Announcements are
hints: every page re-reads committed state on mount and on the hint.

Conversation work runs as durable tasks. `Durable.Scheduler` reads facts,
applies `Durable.Policy`'s decisions in per-task commits, and starts each
step under `Durable.TaskSupervisor`. A step commits through
`Durable.Runtime`, fenced on the task's status and `updated_at`, so a step
left over from a Scheduler restart can't commit. The task kinds:

- `Durable.Generation`: one model request and its outcome.
- `Durable.ToolTask`: one tool call. A tool's result and any domain rows it
  writes (a context file, a schedule, a question) are one commit. A tool
  that waits parks on a durable signal and resumes after a restart.
- `Schedules.Routine` (`"routine"`), `Ambient.Timer` (`"ambient"`) and
  `Threads.Titling` (`"thread_title"`): timers and background work.

Profiles (`Durable.Profile`) give a conversation its model, prompt, tools,
optional working directory (`workdir/1`) and two optional hooks that run
inside commits the harness already makes: `on_settled/3` after a generation
settles, and `on_tool_result/4` after a tool result is stored. The hooks
also run inside the Scheduler's own commit on a Stop or a failed task, so
every hook-path function is total: bad data records less, it never turns
the commit into a crash loop.

A machine tool call is a durable task parked on its op's signal; the op is
a `machine_ops` row; the node's channel carries the messages. There is no
hub process per operation.

## Supervision trees

### apps/node

```
PhotonNode.AppSupervisor  one_for_one     (PhotonNode.Application)
└── PhotonNode  rest_for_one              only when config :photon_node, autostart: true
    ├── PhotonNode.OpRegistry             Registry (unique): operation id -> operation process
    ├── PhotonNode.OpSupervisor           DynamicSupervisor
    │   └── Ops.Shell | Ops.Job           :temporary, one per operation
    │       └── (Shell) Port -> bash wrapper -> the command's own process group
    ├── PhotonNode.Executor               :permanent; owns the journal (<data_dir>/ops), scans and resumes on start
    └── PhotonNode.Connection             Slipstream client; left out when connect: false (tests)
```

- Operations report to the executor through `PhotonNode.Ops.Owner`.
  `report/2` and `checkpoint/2` are calls with no timeout that catch every
  exit, so a snapshot is journaled before the operation goes on and an
  executor crash never takes an operation with it.
- The executor monitors operation processes and decides restarts with
  `Executor.Rules.down/3`; `OpSupervisor` never restarts them.
- An executor crash restarts it and the connection (`rest_for_one`);
  operations keep running and the restarted executor re-monitors them from
  its journal scan. A connection crash resends the journal's snapshots on
  join. A registry or supervisor crash, or a VM restart, resumes from the
  journal, where a shell command's outcome comes from its `canceled`,
  `stopped`, `exit`, `pid` and `unstarted` files.
- Config sits in `:persistent_term` and names are global, so a VM runs at
  most one node.

### apps/hub

`Photon.Application`'s and `Photon.Durable.Supervisor`'s moduledocs hold
their lifecycle plans.

```
Photon.Supervisor  one_for_one                      (Photon.Application)
├── PhotonWeb.Telemetry  Supervisor
├── Photon.Repo                                     Ecto pool (SQLite)
├── Ecto.Migrator                                   migrates at boot, then :ignore
├── Photon.PubSub
├── Photon.Tailnet                                  owns the whois ETS cache
├── Photon.MachineRegistry                          Registry: machine id -> NodeChannel pid
├── Photon.ProvisionTasks                           Task.Supervisor for SSH install jobs
├── Photon.Provision                                job table; fails a job whose task dies
├── Photon.ChatGPT                                  the ChatGPT account
├── Photon.Durable.Supervisor  one_for_one          only when start_durable (tests start children/0)
│   ├── Photon.Durable.TaskSupervisor               one task per durable step (async_nolink)
│   ├── Photon.Durable.Store                        the commit line
│   └── Photon.Durable.Scheduler                    applies Durable.Policy, starts steps
├── PhotonWeb.Endpoint                              Bandit
│   ├── /node/websocket -> NodeSocket -> NodeChannel   one per connected node
│   ├── /live -> the LiveViews, each with BlipLive (sticky) over it
│   └── HTTP -> Router -> controllers, HealthPlug
└── PhotonNode  rest_for_one                        only with :local_node: the built-in node
```

- The hub sets `autostart: false` for `:photon_node`, so the embedded node
  lives under `Photon.Supervisor` instead of its own application.
- Channels and LiveViews are supervised by Phoenix and linked to their
  transports. A channel crash loses its registration and its map of where
  each op's live output goes; the node rejoins and both are rebuilt.
- Projects, threads, skills, schedules, signals, questions, the activity
  log and ambient mode add no processes. Their timers are durable tasks the
  Scheduler wakes, so a hub restart finds them waiting, and a time missed
  while the hub was down fires once when it comes back.
- A skill fetch runs in the install page's `start_async` task, with its
  downloads in `Task.async_stream/3`, so closing the page drops it.
- The durable trio has its own `one_for_one` supervisor (three restarts in
  five seconds), so a Scheduler restart doesn't touch running steps; their
  commits are fenced instead.

## Tests

Each app lays its tests out by layer: `test/core` (pure modules, async),
`test/boundary` (processes, the database, files) and `test/property`, and
in the hub `test/web` and `test/integration` too. The case templates are
`PhotonCore.Case`, `PhotonNode.Case` and `PhotonNode.NodeCase`,
`Photon.Case`, `Photon.DataCase` (resets every table; `@tag :durable`
starts the harness) and `PhotonWeb.ConnCase`. Fixtures are data-only
builders with overrides. Fake profiles and tools (`Photon.TestProfile.*`)
each encode one commit, failure or replay behaviour, so keep them separate.

`apps/hub/test/integration/machine_tools_e2e_test.exs` runs a real node
against the real channel over a Bandit listener with the scripted models,
through every agent feature: machine tools, threads in a project's folder,
schedules, skills, `ask_blip`, the activity log and ambient mode.

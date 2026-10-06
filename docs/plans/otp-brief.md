# OTP brief for machine tools on the hub

A short version of `docs/otp-design-guide.md` for step 1 of
`docs/projects-and-blip.md` (nodes become executors; Blip gets `shell` and
`view_image` on any machine). Rule numbers are the guide's; look one up there
for its reason and enforcement. Today's module map is `docs/architecture.md`.

## The layers

- Data. Structs, schemas, wire messages and string-keyed maps that cross
  processes or the network. `@type t` on every struct, `@enforce_keys` for
  required fields. Constructors and small readers only.
- Functional core. Pure functions over that data: decisions, translations,
  formatting. No processes, `Repo`, PubSub, `Req`, `Logger`, files, ports, env,
  clock or randomness. Take the time and IDs as arguments.
- Boundary. One API module per context in front of whatever does I/O: servers,
  adapters, durable tools, the node channel. It validates once, composes with
  `with`, returns plain data and calls the core for every rule it applies.
- Lifecycle. `application.ex` and supervisors: what starts, in what order,
  what a restart does, written in the supervisor's moduledoc. No logic.
- Workers. Processes that start and stop work outside the static tree (tasks,
  per-operation processes, durable steps). Each needs a reason you can name:
  latency, isolation or scale. The code looks like any boundary.
- Tests. Most on the core (`test/core`). Boundary tests use the public API
  and `assert_receive`, never sleep, and don't retest the core (52, 53, 55).

## The rules that matter here

Tags: `[tool]` caught by precommit or dialyzer, `[review]` judgement only, `[test]` an unchecked habit.

Shape of components
- 2 `[review]` Build only the layers a component needs; a library gets no server or supervisor.
- 3 `[review]` Keep things that belong together in one process; no process per small entity.
- 6 `[tool]` One public API module per context; everything else stays internal (Boundary `exports:`).
- 11 `[tool]` Channels and LiveViews are the server layer; their callbacks call the context API.
- 15 `[review]` Model change as stored facts and derive current state from them.
- 16 `[tool]`/`[review]` Don't wrap data in a process to make it mutable (no get/put GenServers).

Functional core
- 28 `[tool]` Business logic lives in strict-Boundary core modules with no I/O.
- 29 `[tool]` Same inputs, same outputs: pass in the clock and IDs, or allow-list on purpose.
- 30 `[tool]` A server callback calls the core and shapes the reply; at most 15 lines.
- 31 `[review]` Try plain functions first; a process only to control execution, divide work or share state.

Boundary
- 60 `[review]` A boundary only for shared state, an external service, side effects, monitoring or isolation.
- 61 `[review]` Reuse infrastructure you have (Phoenix channels, the durable harness) before writing a server.
- 62 `[tool]` A boundary is a GenServer per process type plus a thin API; the API never hands out pids.
- 64 `[review]` Validate untrusted input once, at the API; servers and the core trust it.
- 67 `[tool]` Errors are data with context: `{:error, reason}` the caller can act on.
- 69 `[tool]` The API returns plain data; internals never leak out.
- 71 `[review]` When a core result decides whether a process lives or dies, the server interprets it.
- 72 `[tool]` Prefer `call` to `cast`; each `send` to another process is allow-listed with its reason.
- 73 `[review]` For high-volume paths, decide what happens under load (sample, bound, shed).
- 75 `[test]` Ignore unknown fields and events, so either side can be updated first.

Lifecycle and workers
- 79 `[review]` Plan each process type: how many, who starts it, when it stops, what a restart does.
- 80 `[tool]` Every long-lived process starts under a supervisor through `start_link`.
- 81 `[review]` Permanent services in the static tree; per-connection or per-op processes dynamic.
- 82 `[tool]` Dynamic children choose `restart:` on purpose (`:temporary` when a restart can't help).
- 83 `[tool]` Find processes by registered name or via tuple, owned by one module.
- 86 `[review]` Decide what a crash loses and whether `init` or a reconnect rebuilds it.
- 87 `[review]` Monitor when you only need to hear that a process died; leave links to supervisors.
- 89 `[review]` A worker process needs a named reason: latency, isolation or scale.
- 92 `[review]` One-off jobs are tasks under a `Task.Supervisor` with `async_nolink`.
- 96 `[tool]` Schedule with `send_after` or GenServer timeouts, never by sleeping.

Rules 74, 76 and 77 (compatibility) don't apply, since the protocol is replaced; 75 still does.

## What the tools catch, and what they don't

`mix precommit` and `mix dialyzer` enforce these, so lean on them:

- Boundary: layer dependencies (6, 11, 28, 69). A new core module gets
  `use Boundary, type: :strict, deps: [...]` naming only core or data modules.
- Photon's Credo checks: `FunctionalCore` (28, 29), `ThinCallbacks` (30),
  `PreferCall` (72), `MessageOwnership` (63), `ProcessNameOwnership` (62, 83),
  `SupervisedProcesses` (80), `NoSleep` (96), `DynamicChildRestart` (82), and
  more for data shapes. Built-ins cover nesting, complexity, `with` and specs.
- Dialyzer with `:unmatched_returns`: every result handled, or dropped with
  `_ =` and a reason comment above it (67).

The checks are only as good as the lists in each app's `.credo.exs`
(`FunctionalCore`, `ProcessNameOwnership`, the `PreferCall` and `NoSleep`
allow lists with reasons). Add new modules there and delete removed ones.

Nothing checks rules 2, 3, 15, 31, 60, 61, 64, 71, 73, 79, 81, 86, 87, 89 or 92.
Apply them by judgement and say why in the moduledoc. This redesign's likely
mistakes are here: an extra process, or a crash nobody planned for.

## How this applies to step 1

Module names are suggestions; the placement is the point.

Data
- The op request (ID, machine, kind, args), its snapshot and the `op.start`,
  `op.cancel` and snapshot messages, as string-keyed maps defined once. Reuse
  the shape of `PhotonNode.Harness.Operation`.

Functional core (hub)
- The tool translators moved from the node (`Harness.Tools.Bash`,
  `Tools.ViewImage`): arguments to an operation, a snapshot to a tool result.
  `Output` is used on both sides, so it moves to `apps/core`.
- The offline decision: given when the machine was last seen and the limit,
  keep waiting or fail with "mm1 has been offline for 10 minutes".
- The op ID, derived from the tool call's ID (passed in, rule 29), so a hub
  restart finds the running op instead of starting another.

Boundary (hub)
- `Photon.Machines`: the context API for online machines, starting and
  cancelling an operation, and taking reports from the channel. It owns the
  registry name and the node commands (62, 83).
- `shell` and `view_image` as `Photon.Durable.Tool` modules, kept outside
  `Photon.Assistant` because threads will share them in step 2. `execute/2`
  calls the core, starts the op through `Photon.Machines` and parks with
  `{:wait, ...}`; `resume/2` turns the final snapshot into a result.
- `PhotonWeb.NodeChannel` stays the per-node server (rule 11) and hands every
  `op.*` event to `Photon.Machines` in callbacks of 15 lines or fewer.

What is durable and what isn't (15, 16, 86)
- Durable: the tool call, its op ID and machine, the wait, and the final
  result, committed as a signal (`Tx.signal/3`) that wakes the parked call.
- In memory: who is online (the registry), live shell output (announced
  through `Photon.Events`, never committed per chunk), op processes on nodes.
- Don't add a hub GenServer per operation (3, 31, 89). The durable task already
  holds the operation's state, and the channel is already a process per node.

Node
- Keep `Harness.Ops`, `OpRegistry`, `OpSupervisor`, `Ops.Shell`, `Ops.Job`
  (`:temporary`, rule 82) and `Connection`. Ops report snapshots through
  `Harness.Link` to the connection instead of to a coordinator.
- Remove the session machinery (`Session`, `Coordinator`, `Context`,
  `Inbox`, `Store`, `ModelRequest`, `Skills`, the session supervisor, the
  resume task) and rewrite the `PhotonNode` lifecycle plan (79, 84). The hub
  loses `NodeSessions`, `NodeTranscript`, `NodeWork`, `NodeWatch`, the
  node-session tools and the model relay.

Lifecycle questions to answer in the plan (86, 87)
- Who monitors an op process now that the coordinator is gone, and what
  snapshot does a crash produce?
- A node restart loses its op processes and keeps no log. A reconnect must not
  rerun a shell command: the hub should ask for the latest snapshot, and an op
  the node doesn't know should come back as interrupted, not started again.
- Which in-flight ops does the hub re-request when a machine reconnects, and
  from which durable facts does it find them?

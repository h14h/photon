# OTP design rules for Photon

The rules come from James Edward Gray II and Bruce A. Tate, *Designing
Elixir Systems with OTP* (Pragmatic Bookshelf, 2019), rewritten as rules we
can check. Page numbers are the book's printed pages (in the P1.0 PDF,
printed page N is PDF page N + 9). Rule numbers are cited in code and
config ("rule 72"), so they never change. A "Note" marks where Photon adds
to the book or where its 2019 code has aged.

The **Enforced by** column says what catches a break:

- **credo**: a Credo check, built in or Photon's own (`PhotonCredo.Check.*`
  in `tools/credo_checks/`), run by `mix credo --strict`.
- **boundary**: `use Boundary` declarations, checked by the compiler, so a
  forbidden reference fails `mix compile --warnings-as-errors`. Between
  apps, the path dependencies add the outer layering: `core` can't call
  `node` or `hub`, and `node` can't call `hub`.
- **types**: `@type t`, `@spec`, behaviours, Elixir 1.20's type checker,
  and Dialyzer.
- **tests**: a test convention no tool checks.
- **review**: needs a person's judgment.

## Project organization

| # | Rule | Enforced by |
| --- | --- | --- |
| 1 | Decide the components, and which layers each needs, before writing code. (pp. 3-4) | review |
| 2 | Build only the layers a component needs; a library of functions gets no processes. (pp. 2, 8, 16, 132) | review |
| 3 | Keep concepts that belong together in one component and one process; don't give each small entity a process. (p. 4) | review |
| 4 | Organize code with modules, not processes. (pp. 11-12, 43) | review; credo `ThinCallbacks` (rule 30) |
| 5 | Make each layer recognizable. Note: Photon's namespaces mix layers (`Executor.Rules` sits beside `Executor`), so instead of layer prefixes each functional-core module is a `type: :strict` sub-boundary and each context a boundary. (pp. 47, 108, 121) | boundary |
| 6 | Expose one API module per component and treat the rest as internal. A context's `exports:` lists its API and the data and contracts callers need. (pp. 121-123, 186) | boundary |
| 7 | Design structs and the core before database schemas. (pp. 50, 173-174) | review |
| 8 | Keep persistence out of the core. Note: the durable harness is persistence-shaped on purpose, and commits at the edge of pure decisions. (pp. 174-175, 181-183) | boundary; credo `FunctionalCore` |
| 9 | Keep the persistence model separate from the core struct, with a transform between them. (pp. 174, 178) | review |
| 10 | Start multi-project code as path dependencies ("poncho" projects). (pp. 175, 184-186) | review |
| 11 | Treat Phoenix channels and LiveViews as the server layer: their callbacks call a context API. `PhotonWeb` uses only what `Photon` exports, never Ecto. (pp. 187-193) | boundary; credo `LiveViewLogic`, `ThinCallbacks` |
| 12 | Wire components with configuration read at runtime, not compile-time attributes or `Mix.env`. (pp. 177, 182-184) | credo `ApplicationConfigInModuleAttribute`, `MixEnv` |

## Data

| # | Rule | Enforced by |
| --- | --- | --- |
| 13 | Design data first, shaped by its main access pattern. (pp. 5, 37-40) | review |
| 14 | Prefer flat data to deep nesting. Stored nested formats (operation snapshots) are read with pattern matches. (pp. 40, 48) | credo `DeepAccessPath` (depth 2) |
| 15 | Model change as new facts and derive current state from them. (pp. 42-44) | review |
| 16 | Don't wrap data in a process to make it mutable. (p. 43) | credo `SupervisedProcesses` (no `Agent`); review |
| 17 | A known, fixed set of fields is a struct in its own module, with `@type t`. (pp. 44-49) | credo `StructType` |
| 18 | Fields that must be given are listed in `@enforce_keys`. (pp. 26, 57) | credo `EnforceKeys` |
| 19 | Atoms only for a small, known set of names; strings for user and generated data. (pp. 23, 28) | credo `UnsafeToAtom` |
| 20 | Integers for exact quantities; references or generated IDs for identity. (p. 23) | review |
| 21 | Read lists from the head and build them by prepending; no index access in loops. (pp. 23-25) | credo `AppendSingleItem`, `IndexAccessInLoop` |
| 22 | Streams for large, unbounded or external data. (p. 25) | review |
| 23 | Maps for keyed data, `MapSet` when only keys matter, keyword lists for options; never rely on map order. (pp. 27-28) | review |
| 24 | Binaries, not charlists; build output as iodata; don't hold large binaries longer than needed. (pp. 29-31) | credo `AccumulatorConcat`; review |
| 25 | Tuples only for small fixed-position data and tagged results. (pp. 31-32) | credo `SmallTuples` |
| 26 | Treat functions as data: pass them in. (pp. 32-33, 59) | review |
| 27 | Reach for ETS and processes before outside caches. (p. 34) | review |

## Functional core

| # | Rule | Enforced by |
| --- | --- | --- |
| 28 | Business logic lives in pure modules: no processes, external services or side effects. Each is a strict sub-boundary that names only core and data modules and the libraries it needs (JSON, Ecto's query and schema macros). (pp. 6, 53, 73) | boundary; credo `FunctionalCore` (no `GenServer`, `Process`, `Task`, `send`, `receive`, `Port`, `File`, `System.cmd`, app env, `Logger`, `:ets`, `:persistent_term`) |
| 29 | Same inputs, same outputs. Take the time, randomness and fresh IDs as arguments, or allow-list the module on purpose. (pp. 6, 54, 88-91) | credo `FunctionalCore` |
| 30 | Server callbacks call the core and shape the reply; logic stays out of them. (pp. 11-12, 113) | credo `ThinCallbacks` (15 lines per clause) |
| 31 | Try plain functions first; use a process only to control execution, divide work, or hold shared state. (p. 57) | review |
| 32 | One module per struct; its functions take the struct first and return it when they transform it. (pp. 55, 62) | credo `Specs`, `StructType`; review |
| 33 | A module is as big as one job needs, with a small public API. (p. 55) | credo `ModuleDependencies` (20) |
| 34 | Give a struct a `new` constructor when it needs defaults, validation or derived fields. (pp. 55-57, 63) | review |
| 35 | Single-purpose functions. (pp. 60, 63, 73) | credo `ABCSize` (30), `CyclomaticComplexity` (8), `FunctionArity` (5) |
| 36 | Name concepts with functions and variables rather than comments. (pp. 59-60, 69, 165) | review |
| 37 | Names as long as they need to be; no abbreviations. (pp. 61-62) | review |
| 38 | Compose: a pipeline first, `with` when steps can fail, a token when context grows. (p. 62) | credo `PipeChainStart`, `NestedFunctionCalls` (3, in `lib/`) |
| 39 | Move a token (the domain struct at a point in time) through transformations. (pp. 62-64, 66) | types |
| 40 | One level of abstraction per function; push plumbing into named helpers. (pp. 64-67, 165) | review |
| 41 | Decide in function heads with patterns and guards; keep the left margin skinny. (pp. 68-70, 73) | credo `Nesting` (2), `CondStatements` |
| 42 | Try the core in IEx before building a boundary; keep example data ready. Photon's scripted models fill this role. (pp. 70-72, 111) | tests |

## Tests

| # | Rule | Enforced by |
| --- | --- | --- |
| 43 | Put most tests on the core (`test/core` in each app). (pp. 12-13, 75) | tests |
| 44 | Build test data in fixtures, not in test bodies. (pp. 76-78) | tests |
| 45 | Fixtures are composable builders with defaults and overrides. (pp. 80-84) | tests |
| 46 | Share helpers from a case module that aliases and imports them (`Photon.Case`, `Photon.DataCase`, `PhotonNode.Case`, `PhotonNode.NodeCase`). (pp. 78-80) | tests |
| 47 | Name preconditions with named setups in `describe` blocks. (pp. 84-87) | tests |
| 48 | Make tests around impure code repeatable on purpose. (pp. 88-91) | tests |
| 49 | Compose long flows as pipelines over the token. (pp. 91-95) | tests |
| 50 | Measure coverage against a threshold: core 95%, node and hub 85% (`mix test --cover`). (pp. 95-96) | `test_coverage` in `mix.exs` |
| 51 | Use property tests, especially for token-based cores. (pp. 96-97) | tests (StreamData) |
| 52 | Don't retest core logic at the boundary. (p. 195) | tests |
| 53 | Test a boundary through its public API. (pp. 13, 196, 199) | tests |
| 54 | Tests that touch named singletons are `async: false`; start expensive dependencies only where needed. (pp. 196-197) | credo `PassAsyncInTestCases` |
| 55 | Never sleep in tests; wait on a notification with `assert_receive`. The one sleep in test support simulates model latency and is allow-listed. (pp. 203-209) | credo `NoSleep` |
| 56 | Capture logs. (pp. 198, 208) | credo `CaptureTestLogs` |
| 57 | Test a boundary's error paths. (pp. 201-202) | tests |
| 58 | Each separately packaged component has its own suite. (pp. 200-202) | tests |
| 59 | A hard-to-write test is a design problem. (p. 199) | review |

## Boundaries

| # | Rule | Enforced by |
| --- | --- | --- |
| 60 | Add a boundary only for shared state, an external service, side effects, monitoring, or failure isolation. (p. 106) | review |
| 61 | Use existing process infrastructure (Phoenix, Ecto, libraries) before your own server. (pp. 106-107, 155) | review |
| 62 | A boundary is a server layer behind a thin API of plain functions; the API never hands out a pid, name or via tuple. (pp. 8, 107) | boundary; credo `ProcessNameOwnership` |
| 63 | Message formats stay in the server's module; callers use its client functions. (pp. 110-111) | credo `MessageOwnership` |
| 64 | Validate untrusted input once, at the API. (pp. 113, 116, 121) | types; review |
| 65 | Validators collect every error rather than stop at the first. (pp. 116-121) | review |
| 66 | Compose fallible steps with `with`, not nested `case`. (pp. 102, 105-106, 122) | credo `Nesting`, `WithClauses`, `RedundantWithClauseResult` |
| 67 | Errors are data with enough context to act on. (pp. 103-105) | types |
| 68 | Keep the API layer thin: validate, stitch services, call servers. (pp. 121, 123) | review |
| 69 | Return plain data from the API; keep internals out. (pp. 116, 123) | boundary; types |
| 70 | Module docs and specs, the API module first. (pp. 7, 123) | credo `ModuleDoc`, `Specs` (every public function in `lib/`) |
| 71 | When a core result decides a process's fate, the server interprets it. (p. 114) | review |
| 72 | Prefer `call` to `cast`. A `cast` or a `send` to another process is allow-listed in the app's `.credo.exs` with its reason. (pp. 125-128) | credo `PreferCall` |
| 73 | Decide what a high-volume server does under load. Note: Logger has had `:logger`'s overload protection since Elixir 1.15. (pp. 125-128) | review |
| 74 | Extend an API with options, never new required arguments. (p. 129) | review; tests |
| 75 | Ignore unknown fields and messages. (p. 129) | tests (protocol tests send unknown fields); review |
| 76 | Never break an existing endpoint; add a new one. (p. 130) | tests (golden wire and stored formats); review |
| 77 | New optional behaviour defaults to the old behaviour. (pp. 182, 204) | review |

## Lifecycle

| # | Rule | Enforced by |
| --- | --- | --- |
| 78 | Supervision is lifecycle, not only failure handling. (pp. 13-15, 131) | review |
| 79 | Plan each process type (count, starter, stop, restart) and write it in its supervisor's moduledoc. (pp. 133, 137) | review |
| 80 | Start every long-lived process under a supervisor. (pp. 132, 136, 142) | credo `SupervisedProcesses` |
| 81 | Permanent services in `application.ex`; per-request processes under a `DynamicSupervisor`. (pp. 138, 140, 143-144) | review |
| 82 | Dynamic children choose `:restart` on purpose. (p. 141) | credo `DynamicChildRestart` |
| 83 | Find processes by name. A registered name is named only by the module that owns it. (pp. 110, 121, 142-143, 147-148) | credo `ProcessNameOwnership` |
| 84 | Order children by dependency and pick the strategy from that (`:rest_for_one` when later children depend on earlier). (pp. 144-146) | review |
| 85 | `shutdown: :infinity` only for supervisors. (p. 146) | credo `WorkerShutdown` |
| 86 | Decide what a crash loses and whether `init` rebuilds it. (pp. 141, 170) | review |
| 87 | Leave links and trapping exits to supervisors; monitor when you only need to hear of a death. (pp. 135-136) | review |
| 88 | Confirm the running tree matches the plan. (pp. 146-150) | tests |

## Workers

| # | Rule | Enforced by |
| --- | --- | --- |
| 89 | Add worker processes only for latency, failure isolation, or scale. (pp. 153-155) | review |
| 90 | Get concurrency from dependencies and frameworks first. (pp. 155-158, 160-161, 171) | review |
| 91 | No naked processes or raw `send`; `send_after` is fine for scheduling. (p. 158) | credo `SupervisedProcesses`, `PreferCall` |
| 92 | Tasks for one-off concurrent jobs. Note: under a `Task.Supervisor` with `async_nolink`. (pp. 158-159) | review |
| 93 | Bound concurrency with `Task.async_stream`. (pp. 159-160) | credo `BoundedTaskConcurrency` |
| 94 | Pool expensive shared resources. (pp. 160-161) | review |
| 95 | Worker code looks like any boundary; what differs is that it starts and stops other processes. (pp. 153, 162) | review |
| 96 | Schedule with timeouts or `send_after`, never by sleeping. Allow-listed sleeps: the model client's retry wait (in the caller's task), a shell operation's `terminate/2`, and the packaged node's keep-alive hook. (pp. 164-166) | credo `NoSleep` |
| 97 | Find and stop processes through their supervisor and registry. (pp. 167-168) | review |

## How the checks run

Each app's `mix precommit` (test env) runs:

```sh
mix compile --warnings-as-errors   # warnings, Elixir 1.20's type checker, Boundary
mix deps.unlock --check-unused
mix format --check-formatted
mix credo --strict
mix test --warnings-as-errors
```

`mix dialyzer` and `mix test --cover` run separately (see `AGENTS.md`).

**Credo.** `tools/credo_checks/shared_checks.exs` holds the checks every app
runs, each commented with its rule number. Each app's `.credo.exs` adds the
checks that need its own lists: the functional-core modules
(`FunctionalCore`), the API modules and registered names
(`ProcessNameOwnership`), the callbacks to keep thin (`ThinCallbacks`), the
LiveView rules (hub), and allow-lists, each entry with its reason
(`PreferCall`, `NoSleep`). Rules about how the system is built apply to
`lib/`; tests get the readability and test-convention rules. The custom
checks are tested in `apps/core`'s suite
(`cd apps/core && mix test ../../tools/credo_checks/test`).

**Boundary.**

- `apps/core`: `PhotonCore` (messages, IDs, operations) is strict and depends
  only on Jason. `PhotonCore.LLM.Error` and `PhotonCore.LLM` are boundaries
  of their own, so another app's core can record a model failure without
  being able to call the HTTP client. Inside the client, `SSE`, `Retry`,
  `HTTPError`, `Mock`, `Responses.Request` and `Responses.Response` are
  strict sub-boundaries.
- `apps/node`: `PhotonNode` holds `Config`, `CLI`, `Connection`, `Executor`
  and `Ops`. The connection depends on the executor, the executor on the
  operation layer and reaches the hub only through `Executor.Link`; the
  operation layer depends only on `PhotonCore`.
- `apps/hub`: each context is a sub-boundary of `Photon` with explicit
  `deps:`; `Photon` exports the contexts; `PhotonWeb` uses only those
  exports. `Photon.Application` sits above both and is the only hub module
  that may use the node app. `Photon.Durable` exports its API, schemas,
  `Tx`, `Runtime` and the tool and task-kind contracts, and keeps `Store`,
  `Scheduler` and its core inside.

**Types.** Every public function in `lib/` has a `@spec` and every struct a
`@type t`. Elixir 1.20 infers types from patterns, guards and bodies across
modules and apps, and reports violations as warnings, which
`--warnings-as-errors` makes failures. It doesn't read `@spec` yet; Dialyzer
does, with `:error_handling`, `:extra_return`, `:missing_return` and
`:unmatched_returns`:

- A result that may carry an error is handled, or dropped with `_ =` and a
  comment saying why (`DiscardNeedsReason`). A named discard
  (`_entry = Tx.append(...)`) needs no comment only for a raising call or a
  module on the check's allow-list (the hub's `Photon.Durable` and
  `Photon.Durable.Tx`, whose writes raise on failure).
- Announcements go through `Photon.Events`, which logs a failed broadcast
  and returns `:ok`.
- Every exception says why: each `.dialyzer_ignore.exs` entry
  (`DialyzerIgnoreReasons`), inline `credo:disable` comment and `@dialyzer`
  attribute (`SuppressionNeedsReason`) sits under a reason comment.

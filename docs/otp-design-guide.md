# OTP design rules for Photon

These rules come from James Edward Gray II and Bruce A. Tate, *Designing
Elixir Systems with OTP* (Pragmatic Bookshelf, 2019). Page numbers are the
book's printed page numbers. In the P1.0 PDF, printed page N is PDF page N + 9.

The book splits a component into layers and gives a mnemonic for them: "Do fun
things with big, loud worker-bees", meaning data, functional core, tests,
boundaries, lifecycle, workers (p. 2). It insists that most components don't
need all six (pp. 2, 16, 132). What follows is the book's advice rewritten as
rules you can check, grouped by layer, with project organization first. Where
I add something the book doesn't say, or where the 2019 code has aged, the
rule says "Note".

Each rule has the page(s), a one-line reason, and how it is enforced here.
"How the rules are enforced" at the end has the commands and where each
tool is configured.

- `credo (builtin: Check)`: a check that ships with Credo 1.7, run by
  `mix credo --strict` with each app's `.credo.exs`.
- `credo (custom: Check)`: one of Photon's own Credo checks,
  `PhotonCredo.Check.*` in `tools/credo_checks/`.
- `boundary`: compile-time dependency rules from the `boundary` library
  (`use Boundary, deps: [...], exports: [...]`). Its compiler reports a
  forbidden reference, which `mix compile --warnings-as-errors` turns into
  a failure. Between apps, the Mix path deps add the outer layering: `core`
  can't call `node` or `hub`, and `node` can't call `hub`.
- `types/specs`: `@type t`, `@spec`, behaviours, Elixir 1.20's type checker
  at compile time, and Dialyzer (`mix dialyzer`).
- `test convention`: a habit in how we write tests that no tool checks.
- `review only`: needs a person's judgment; the rule says why a tool can't
  check it.

Rule numbers run through the whole document so they can be cited ("rule 72").

## Project organization

1. Think before you open the editor: decide the components and which layers
   each one needs. (pp. 3-4)
   - Why: bugs are cheapest to fix before the first line exists.
   - Enforce: review only. Deciding the components is the design work itself;
     no tool sees it.

2. Build only the layers a component needs. A library of functions gets no
   server, no supervisor, no workers. (pp. 2, 8, 16, 132)
   - Why: every layer costs something. "The first way to win the boundary game
     is not to play" (p. 8).
   - Enforce: review only. Whether a layer is needed is a judgment about the
     problem.

3. Keep concepts that belong together in one component and one process. Don't
   give each small entity its own process. (p. 4)
   - Why: a process per chess piece can't enforce the board's integrity.
     Processes split too finely cause the same trouble as global variables.
   - Enforce: review only. A tool can't tell which entities belong together.

4. Organize code with modules, not processes. (pp. 11-12, 43)
   - Why: tying organization to concurrency means a change of process strategy
     rewrites business logic.
   - Enforce: review only, helped by credo (custom: `ThinCallbacks`), which
     keeps logic out of server callbacks (rule 30).

5. Give each layer its own namespace: core modules in one (`Mastery.Core.*`),
   process machinery in another (`Mastery.Boundary.*`), and one top-level API
   module (`Mastery`). (pp. 47, 108, 121)
   - Why: the path tells a reader which rules apply to a file.
   - Enforce: boundary. Photon's namespaces mix layers
     (`PhotonNode.Harness.Session` sits next to `Harness.Coordinator`), and
     the TLA+ specs, `docs/verification.md` and the config cite the current
     module names, so instead of moving modules under layer prefixes each
     functional-core module is a `type: :strict` sub-boundary whose `deps:`
     name only other core or data boundaries, and each context is a
     boundary of its own.

6. Expose one public API module per component, as a Phoenix context does, and
   treat the rest as internal. (pp. 121-123, 186)
   - Why: the API is where developers start reading and the one place where
     changes cost something. Everything behind it stays free to change.
   - Enforce: boundary. Each context's `exports:` lists its API module and the
     data and contracts callers need: `Photon` exports the contexts,
     `Photon.Durable` its API, schemas, `Tx`, `Runtime` and the tool and
     task-kind contracts (not `Store`, `Scheduler` or the core),
     `PhotonNode.Harness` only `Link`, `PhotonCore.LLM` its adapters.

7. Design structs and the core before database schemas, and hold off on
   persistence until the domain's state transitions settle. (pp. 50, 173-174)
   - Why: starting from schemas makes the core thin and the boundary thick, and
     often leaves no core at all.
   - Enforce: review only. The order of design work leaves no trace in the
     code.

8. Keep persistence in its own component and plug it in through a configured
   function or behaviour, not `Repo` calls from the core. (pp. 174-175, 181-183)
   - Why: "Database coupling can be absolutely toxic" (p. 175). A pluggable
     function lets the same component run with or without a database.
   - Enforce: boundary and credo. Core boundaries are strict and can't name
     `Photon.Repo`, Ecto's repo functions or PubSub; credo (custom:
     `FunctionalCore`) flags `*.Repo` calls in core modules. Plugging
     persistence in through a function is review only: the durable harness is
     persistence-shaped on purpose (drift item 2).

9. Keep the persistence model separate from the core struct, and write a
   transform between them. (pp. 174, 178)
   - Why: the two structs solve different problems. One struct serving both
     bloats as their needs drift apart.
   - Enforce: review only. Telling the two models apart needs to know what
     each is for.

10. Start multi-project code as path dependencies ("poncho" projects) and
    extract to git or Hex once the interfaces settle. (pp. 175, 184-186)
    - Why: separate repositories punish a wrong interface; umbrellas force
      every app onto the same dependency versions.
    - Enforce: review only. Photon already works this way.

11. Treat callback frameworks (Phoenix Channels, LiveView) as a replacement for
    your server layer, whose callbacks call your API. (pp. 187-193)
    - Why: `join` and `handle_in` are `start_link` and `handle_cast` under
      other names. The layers don't change.
    - Enforce: boundary, credo. `PhotonWeb` depends only on what `Photon`
      exports, plus `PhotonCore`, and `check: [apps: [:ecto, :ecto_sql]]`
      keeps Ecto out of it. credo (custom: `LiveViewLogic`) keeps repos, Ecto,
      files, ports, HTTP, PubSub, registries and `GenServer` out of LiveViews
      and the node channel, and credo (custom: `ThinCallbacks`) caps
      `handle_event`, `handle_in`, `join` and `handle_params` clauses.

12. Wire components together with configuration, not code: supervision
    children in `application.ex`, choices such as the persistence function in
    config. (pp. 177, 182-184)
    - Why: switching strategy then means editing config.
    - Enforce: credo (builtin: `Warning.ApplicationConfigInModuleAttribute`,
      `Warning.MixEnv`). Note: the book reads config into a module attribute
      (`@persistence_fn Application.get_env(...)`, p. 182), which freezes the
      value at compile time; the check flags exactly this, so config is read
      at runtime. Choosing what to wire through config is review (the node's
      hub link is one, `PhotonNode.Harness.Link`).

## Data

13. Spend design time on data first, and choose shapes by their main access
    pattern (mostly read, or often updated). (pp. 5, 37-40)
    - Why: with the right structure the functions "seem to write themselves".
      With the wrong one, every caller compensates.
    - Enforce: review only. Choosing shapes by access pattern is a judgment.

14. Prefer flat data to deep nesting, for example a map keyed by `{row, col}`
    instead of tuples of tuples. (pp. 40, 48)
    - Why: a deep update rebuilds every level above it, and deep data makes
      pattern matches harder.
    - Enforce: credo (custom: `DeepAccessPath`): `get_in`, `put_in`,
      `update_in`, `pop_in` and `get_and_update_in` paths deeper than two
      levels. Stored formats that are nested already (operation snapshots in
      the session log) are read with pattern matches.

15. Model change as new facts: keep an initial value and a log of changes, and
    compute current state from them. (pp. 42-44)
    - Why: state at a point in time is deterministic, and a logged error can be
      reproduced exactly.
    - Enforce: review only. Whether state is derived from facts is a design
      property.

16. Don't wrap data in a process to make it mutable (a `read_balance` and
    `write_balance` pair). (p. 43)
    - Why: two workers that read and then write will race and lose an update.
      You've rebuilt an object-oriented variable.
    - Enforce: credo (custom: `SupervisedProcesses`) flags `Agent`. A
      GenServer whose whole API is get and put of its state is review only:
      telling a variable from a server needs to know what the calls mean.

17. Find the nouns in the problem. A known, fixed set of fields becomes a
    struct in its own module. (pp. 44-49)
    - Why: the struct's module becomes the home for functions about that noun.
    - Enforce: review only, helped by credo (custom: `StructType`): every
      struct declares `@type t`.

18. Use `@enforce_keys`, or `struct!/2` in a constructor, for fields that must
    be given. (pp. 26, 57)
    - Why: a default that slips through becomes a data integrity bug.
    - Enforce: credo (custom: `EnforceKeys`): a `defstruct` or `defexception`
      with fields that have no default sets `@enforce_keys` or is built by a
      `new` that calls `struct!/2`.

19. Use atoms only for a small, known set of names. Use strings for user data
    and anything generated. (pp. 23, 28)
    - Why: atoms are never garbage collected, and a full atom table crashes the
      VM.
    - Enforce: credo (builtin: `Warning.UnsafeToAtom`).

20. Use integers for exact quantities (money in cents, `div` and `rem` for
    division), and references or generated IDs for identity. (p. 23)
    - Why: floats are estimates.
    - Enforce: review only. Which numbers are exact quantities is domain
      knowledge.

21. Read lists from the head and build them by prepending. Avoid index access
    and `list ++ [item]`. (pp. 23-25)
    - Why: head operations are O(1). Reaching the nth element or appending
      walks the list and copies it.
    - Enforce: credo (builtin: `Refactor.AppendSingleItem`, on `lib/`; custom:
      `IndexAccessInLoop`, which flags `Enum.at`, `Enum.fetch` and
      `:lists.nth` inside `Enum` or `Stream` functions and `for`).

22. Use streams for large, unbounded, or external data. (p. 25)
    - Why: nothing is computed or held until it's needed.
    - Enforce: review only. How large or unbounded the data can get isn't in
      the code.

23. Use maps for data you update often or keep unique by key, `MapSet` when
    only the keys matter, and keyword lists for options. Never rely on map
    order. (pp. 27-28)
    - Why: maps read and update in O(log n). IEx sorting small maps when it
      prints them is not a guarantee.
    - Enforce: review only. The right collection depends on how it's used.

24. Prefer binaries to charlists, build output as iodata instead of repeated
    `<>`, and don't let long-lived processes hold large binaries longer than
    they need to. (pp. 29-31)
    - Why: concatenation copies. Large binaries are shared and reference
      counted, so a process that keeps one alive leaks memory in ways that are
      hard to find.
    - Enforce: credo (custom: `AccumulatorConcat`: `<>` onto the accumulator
      of `Enum.reduce`, `List.foldl`/`foldr` or `for ... reduce:`). The memory
      half is review only.

25. Use tuples for small fixed-position data and tagged results (`{:ok,
    value}`, `{:error, reason}`). Switch to a map once you can't remember what
    a position means. Don't append to tuples or iterate over them.
    (pp. 31-32)
    - Why: positions carry no labels (connascence of position), and appending
      copies the whole tuple.
    - Enforce: credo (custom: `SmallTuples`): tuple literals over three
      elements, or four when the first is an atom tag, and `elem/2` reading
      index 2 or later. OTP's shapes (its messages, IP addresses) are
      ignored. types/specs for result tuples.

26. Treat functions as data: pass them in (generators, checkers, callbacks),
    and send code to the data rather than data to the code. (pp. 32-33, 59)
    - Why: a function normalizes options cheaply and avoids copying data
      between processes or machines.
    - Enforce: review only. Whether to pass a function is a design choice.

27. Leave Elixir's data structures where they fit badly (number crunching on
    mutable arrays, durable relational data), but reach for ETS and processes
    before Redis or memcached. (p. 34)
    - Why: the BEAM already covers caches, pools and job queues, with
      supervision included.
    - Enforce: review only. A judgment about the data and the load.

## Functional core

28. Keep business logic in a functional core: modules of functions with no
    processes, no external services, and as few side effects as you can
    manage. (pp. 6, 53, 73)
    - Why: it separates the domain's complexity from the complexity of the
      process machinery, so each can be handled alone.
    - Enforce: boundary and credo. Every functional-core module (the tables
      below) is a `type: :strict` sub-boundary, so it may depend only on the
      core and data boundaries and the libraries its `deps:` name (JSON,
      Ecto's query and schema macros), never on a context API, `Photon.Repo`,
      PubSub, `Req`, `Logger` or the model client. credo (custom:
      `FunctionalCore`) covers what boundary can't see, Elixir's own modules:
      no `GenServer`, `Process`, `Task`, `send`, `receive`, `spawn`, `Port`,
      `File`, `System.cmd`, `Application` env, `Logger`, `:ets` or
      `:persistent_term` in a core module's functions.

29. Aim for same inputs, same outputs. When a core function needs the time,
    randomness, or a fresh ID, decide on purpose whether to take it as an
    argument or pay for it in the tests. (pp. 6, 54, 88-91)
    - Why: every impure call makes tests less repeatable. The book keeps
      `Enum.random` in its core and shows the test cost.
    - Enforce: credo (custom: `FunctionalCore`): the clock, randomness and ID
      generators in core modules, unless allow-listed for the module. The
      allow list is the decision made on purpose: `Harness.Session` and
      `Harness.Operation` mint IDs (tests match on prefixes), and
      `PhotonCore.ID` is the ID generator.

30. Keep state handling and business logic in separate modules. A server
    callback calls the core and shapes the reply. (pp. 11-12, 113)
    - Why: putting logic inside the state loop "conflates two concerns:
      organization and concurrency" (p. 11).
    - Enforce: credo (custom: `ThinCallbacks`): each `handle_call`,
      `handle_cast`, `handle_info` and `handle_continue` clause (and the
      framework callbacks per app) is at most 15 lines.

31. Try plain functions first. Use a process only to control execution,
    divide work, or hold shared state that functions can't. (p. 57)
    - Why: functions compose and test more easily, and most problems don't need
      a process.
    - Enforce: review only. A judgment about the problem.

32. Group functions with the data they manage: one module per struct, each
    public function taking that struct first and, if it transforms it,
    returning it. (pp. 55, 62)
    - Why: functions that take and return the module's struct pipe, and it's
      obvious where a new function goes.
    - Enforce: types/specs: credo (builtin: `Readability.Specs`) requires a
      `@spec` on every public function in `lib/`, and credo (custom:
      `StructType`) a `@type t` on every struct, so `f(t(), ...) :: t()` can
      be written and Dialyzer checks it. Where functions live is review.

33. Make a module as big as one job needs, with a small public API and private
    details. (p. 55)
    - Why: small interfaces keep the interactions between modules simple
      ("layers inside of layers").
    - Enforce: credo (builtin: `Refactor.ModuleDependencies`, at most 20
      Photon modules, the ones a `use Boundary` names included); review.

34. Give a struct a `new` constructor when building one needs defaults,
    validation, or derived fields, and build it only through that.
    (pp. 55-57, 63)
    - Why: one place derives fields such as the compiled template, and nobody
      can skip it.
    - Enforce: review only. A check would have to tell `%Mod{}` patterns from
      constructions across files, and Ecto schemas are built by their context
      on purpose. credo (custom: `EnforceKeys`) accepts a `new` that calls
      `struct!/2` as the way in.

35. Write single-purpose functions. (pp. 60, 63, 73)
    - Why: decoupled concepts are the base of any design, and small functions
      compose.
    - Enforce: credo (builtin: `Refactor.ABCSize` at 30 on `lib/`,
      `Refactor.CyclomaticComplexity` at 8, `Refactor.FunctionArity` at 5,
      private functions included).

36. Name concepts with functions and variables instead of explaining them in
    comments, even when the function is a one-line `Map.put`.
    (pp. 59-60, 69, 165)
    - Why: the compiler checks names. Nothing checks comments.
    - Enforce: review only. Nothing can judge whether a name explains enough.

37. Make names as long as they need to be (`compute_cart_tax_in_cents`) and
    avoid abbreviations. (pp. 61-62)
    - Why: a short name drops exactly the context that prevents a business bug,
      like dollars versus cents.
    - Enforce: review only. As for rule 36.

38. Shape code for composition: a pipeline first, `with` when steps can fail,
    a token when the context gets complex. (p. 62)
    - Why: these are Elixir's units of composition. Nested calls and nested
      `case` bury the story.
    - Enforce: credo (builtin: `Refactor.PipeChainStart`, and
      `Readability.NestedFunctionCalls` with `min_pipeline_length: 3` in
      `lib/`: a chain of three or more calls on one value is a pipeline, while
      two-level nesting like `File.rm(path(id))` stays, since a one-step pipe
      reads worse; nesting and `with` checks under rules 41 and 66).

39. Use a token (the domain struct at one point in time, like `Plug.Conn` or
    `Ecto.Changeset`) and move it through transformations. (pp. 62-64, 66)
    - Why: a complex flow becomes a pipeline of small steps that each take and
      return the token.
    - Enforce: types/specs (`@type t` and `@spec` everywhere, rule 32).

40. Write each function at a single level of abstraction. Push low-level map
    plumbing into a named helper. (pp. 64-67, 165)
    - Why: `Map.put(quiz, :current_question, ...)` next to
      `move_template(:used)` makes the reader switch levels. Awkward plumbing
      hidden in a helper is read only by whoever changes it.
    - Enforce: review only. Levels of abstraction are a reading judgment.

41. Keep the left margin skinny: decide in function heads with pattern
    matching and guards rather than `if`, `cond` and `case`, and name boolean
    arguments in the head (`false = _mastered`). (pp. 68-70, 73)
    - Why: each clause reads as one business rule, and a failure arrives with
      the arguments that caused it.
    - Enforce: credo (builtin: `Refactor.Nesting` with `max_nesting: 2`,
      `Refactor.CondStatements`, `Refactor.CyclomaticComplexity`).

42. Try the core in IEx before building a boundary, and keep ready-made
    example data for exploring it. (pp. 70-72, 111)
    - Why: it's a cheap integration check while the core is still easy to
      change.
    - Enforce: test convention (shared example builders; in Photon the mock
      models fill this role).

## Tests

43. Put most of the tests on the core. (pp. 12-13, 75)
    - Why: no processes or external conditions, so tests are fast and
      predictable, and that's where the logic lives.
    - Enforce: test convention (`test/core` in each app). Not checked: a tool
      can't weigh where tests belong.

44. Build test data in fixtures (functions that return data), not inside test
    bodies. (pp. 76-78)
    - Why: setup crowds the screen and the reader's head, and hides what the
      test is for. "You must get setup right to get the rest of your tests
      right" (p. 77).
    - Enforce: test convention.

45. Write fixtures as composable builders with defaults and overrides
    (`template_fields(overrides \\ [])` using `Keyword.merge`), plus one-shot
    builders for the common complex cases. (pp. 80-84)
    - Why: one call builds a complex structure, small builders combine into
      custom ones, and any field can be overridden.
    - Enforce: test convention.

46. Share test helpers from a support module whose `__using__` aliases the
    modules under test and imports the builders. (pp. 78-80)
    - Why: it removes the same alias block from every test file.
    - Enforce: test convention (Photon has `Photon.Case`, `Photon.DataCase`,
      `PhotonNode.Case` and `PhotonNode.HarnessCase`).

47. Name preconditions with named setups inside `describe` blocks
    (`setup [:quiz]`, each taking the context and returning `{:ok, context}`),
    and pattern match what a test needs in its head. (pp. 84-87)
    - Why: the `describe` names the scenario and the setups name what it
      assumes.
    - Enforce: test convention.

48. Make tests repeatable around impure code: assert shape and bounds for
    timestamps, restrict generators to one choice, use
    `Stream.repeatedly |> Enum.find` for "eventually", or inject a
    deterministic function. (pp. 88-91)
    - Why: a test against a moving value flakes. Which trade-off you choose
      matters less than choosing one on purpose.
    - Enforce: test convention.

49. Compose tests as pipelines over the token, with assertion helpers that
    return the token. (pp. 91-95)
    - Why: a long flow (right, wrong, right, right, finished) reads as a story.
    - Enforce: test convention.

50. Measure coverage and set a threshold. (pp. 95-96)
    - Why: you should know what isn't tested, and notice when that grows.
    - Enforce: test convention: each `mix.exs` sets a threshold
      (`test_coverage: [summary: [threshold: N]]`: core 95, node and hub 85)
      and `mix test --cover` fails below it. `mix precommit` runs the tests
      without cover to stay fast.

51. Consider property-based tests, especially for token-based cores.
    (pp. 96-97)
    - Why: generated inputs reach cases nobody would write by hand.
    - Enforce: test convention (StreamData).

52. Don't retest core logic at the boundary. Boundary tests cover processes,
    timing, and external interfaces. (p. 195)
    - Why: layering lets each test deal with "one sliver of complexity"
      (p. 210).
    - Enforce: test convention.

53. Test the boundary through its public API, the way a client would.
    (pp. 13, 196, 199)
    - Why: it checks the contract callers rely on and survives refactoring
      behind it.
    - Enforce: test convention.

54. Make tests that touch named singletons `async: false`, and switch on
    expensive dependencies (database sandbox, persistence) only in the tests
    that need them. (pp. 196-197)
    - Why: concurrent tests collide on shared named processes, and an unneeded
      database slows every test.
    - Enforce: credo (builtin: `Refactor.PassAsyncInTestCases`): every case
      says `async:`.

55. Never sleep in tests. Give timed code an optional notification hook (a
    `notify_pid`, a PubSub event) and wait for it with `assert_receive`.
    (pp. 203-209)
    - Why: sleep too long and the suite is slow; too short and it flakes. The
      same hook is what a UI needs anyway.
    - Enforce: credo (custom: `NoSleep`, on `lib/` and `test/`). The one sleep
      in test support simulates model latency inside a step task, allow-listed
      with that reason.

56. Capture logs so test output stays quiet, and assert on a log line when it
    matters. (pp. 198, 208)
    - Why: noise hides failures.
    - Enforce: credo (custom: `CaptureTestLogs`): a `test_helper.exs` that
      starts ExUnit sets `capture_log: true`.

57. Test the error paths of boundary services, for example that a raising
    callback rolls back its transaction. (pp. 201-202)
    - Why: the boundary is where outside failures land.
    - Enforce: test convention.

58. Give each separately packaged component its own test suite.
    (pp. 200-202)
    - Why: a component that ships on its own has to pass on its own.
    - Enforce: test convention (each app runs its own `mix test` and `mix
      precommit`).

59. Treat a hard-to-write test as a design problem: "if your abstraction is
    right, your tests should be simple" (p. 199).
    - Why: test pain usually points at a layer doing two jobs.
    - Enforce: review only.

## Boundaries

60. Add a boundary only for one of these: shared state across processes, one
    API in front of an external service, managing side effects such as
    logging or file I/O, monitoring resources, or isolating a critical
    service from failure. (p. 106)
    - Why: the boundary is "an optional layer of impure integration code".
    - Enforce: review only. Whether a boundary is warranted is a judgment.

61. Use process infrastructure you already have (Phoenix, Ecto, a library)
    before writing your own server. (pp. 106-107, 155)
    - Why: it's already debugged and supervised.
    - Enforce: review only.

62. Build a boundary in two parts: a server layer with one GenServer per
    process type, and a thin API of plain functions in front of it.
    (pp. 8, 107)
    - Why: clients call functions and never see the messaging.
    - Enforce: boundary (only the API module is exported, rule 6) and credo
      (custom: `ProcessNameOwnership`, whose API part flags a public function
      of an API module that hands out a pid, a name or a via tuple).

63. Hide message formats behind client functions in the GenServer's own
    module. Callers never write `GenServer.call(server, {:message, ...})`.
    (pp. 110-111)
    - Why: an exposed message tuple couples every caller to the server's
      internals.
    - Enforce: credo (custom: `MessageOwnership`): `GenServer.call`/`cast`
      with a literal message only in a module that has the matching
      `handle_call`/`handle_cast` clause.

64. Validate untrusted input once, at the API layer, the closest common access
    point to users. Servers and the core trust what they're given.
    (pp. 113, 116, 121)
    - Why: validation written exactly once keeps the servers clean.
    - Enforce: types/specs on the API; where validation happens is review.

65. Have validators collect every error as `{field, message}` rather than stop
    at the first. (pp. 116-121)
    - Why: the user fixes everything in one round, and validators compose by
      reducing over the error list.
    - Enforce: review only.

66. Compose steps that can fail with `with`, not nested `case`, and don't pipe
    through functions that can fail. (pp. 102, 105-106, 122)
    - Why: `with` keeps the happy path readable and gathers error handling in
      one place.
    - Enforce: credo (builtin: `Refactor.Nesting`, `Refactor.WithClauses`,
      `Refactor.RedundantWithClauseResult`).

67. Treat errors as data: turn exceptions from risky work into
    `{:error, reason, context}` with enough context to act on, so a pipeline
    can report partial success or stop with context. (pp. 103-105)
    - Why: exceptions don't compose, and a bare error code loses the context.
    - Enforce: types/specs (`{:ok, t} | {:error, term}` on boundary functions,
      checked by Dialyzer).

68. Keep the API layer thin. It validates, stitches services together and
    calls servers. No business logic. (pp. 121, 123)
    - Why: a thin layer makes the cost of changing a public function visible.
    - Enforce: review only. What counts as business logic needs judgment.

69. Return plain data from the API and keep server and core internals out of
    what clients see. (pp. 116, 123)
    - Why: whatever leaks out becomes part of the contract.
    - Enforce: boundary (internals aren't exported, so they can't leak into
      callers' code) and types/specs (public specs name the API's own types).

70. Put module docs and typespecs on the API module first. (pp. 7, 123)
    - Why: the API is where public ceremony belongs; internals can wait until
      they settle.
    - Enforce: credo (builtin: `Readability.ModuleDoc`, and
      `Readability.Specs` on every public function in `lib/`, not only the API
      modules).

71. When a core result decides what the process does (stop because the quiz
    is finished), interpret it in the server, not the core. (p. 114)
    - Why: whether a process lives or dies is process machinery.
    - Enforce: review only.

72. Prefer `call` to `cast`. Use `cast` (or a bare `send` to another process)
    only to notify many processes or start many workers, and only on purpose.
    (pp. 125-128)
    - Why: a caller can only go as fast as the server answers, which is back
      pressure for free. Casts can flood a mailbox.
    - Enforce: credo (custom: `PreferCall`): `GenServer.cast`, `handle_cast`,
      and `send`, `Process.send` or `send_after` to another process, unless
      the module is allow-listed in `.credo.exs` with the reason (the
      scheduler's notify, node commands, provisioning progress, the node's hub
      link, operation snapshots and requests).

73. For high-volume servers, watch the mailbox and decide what happens under
    load: switch callers to synchronous, or shed messages, as the logger does.
    (pp. 125-128)
    - Why: an overflowing mailbox fails late and is hard to debug.
    - Enforce: review only (telemetry on `:message_queue_len`). Note: the
      Logger code the book quotes predates Elixir 1.15, when Logger moved onto
      Erlang's `:logger`. That handler has its own overload protection built
      on the same idea.

74. Extend an API with options, never with new required arguments or fields.
    (p. 129)
    - Why: a new requirement forces client and server to upgrade together.
    - Enforce: review only; test convention (keep old-shape requests in the
      protocol tests).

75. Ignore what you don't understand: unknown fields, unknown messages, empty
    optional fields. (p. 129)
    - Why: then either side can deploy first.
    - Enforce: test convention (send unknown fields and events in protocol
      tests); review for catch-all clauses.

76. Never break an existing endpoint. Add a new one for new behavior.
    (p. 130)
    - Why: compatibility you never break beats version numbers that announce
      breakage.
    - Enforce: test convention (golden tests for wire messages and stored
      formats); review.

77. Give optional new behavior a default that keeps the old behavior (the
    persistence function defaults to doing nothing; `notify_pid \\ nil`).
    (pp. 182, 204)
    - Why: existing callers and tests keep working unchanged.
    - Enforce: review only.

## Lifecycle

78. Treat supervision as lifecycle (start, stop and restart cleanly), not only
    as failure handling. (pp. 13-15, 131)
    - Why: "Get the lifecycle right and you have a very good chance to get
      failure recovery right as well" (p. 14).
    - Enforce: review only.

79. Plan each process type: how many there are, who starts them, when they
    stop, what a restart should do. Write it down. (pp. 133, 137)
    - Why: the supervision tree is easy to get right once these answers exist.
    - Enforce: review only (the plan is in each supervisor's moduledoc).

80. Start every long-lived process under a supervisor, through `start_link`.
    Never spawn one directly. (pp. 132, 136, 142)
    - Why: "Don't start processes directly; start them through a supervisor"
      (p. 142). The supervisor restarts it and shuts it down in order.
    - Enforce: credo (custom: `SupervisedProcesses`, on `lib/`): `spawn`,
      `spawn_link`, `spawn_monitor`, `Process.spawn`, `:proc_lib` spawns,
      `Task.start`, `GenServer.start` and `Agent`, unless allow-listed with a
      reason (none are).

81. List permanent services in `application.ex`. Start per-user or
    per-request processes on demand under a `DynamicSupervisor`.
    (pp. 138, 140, 143-144)
    - Why: only the permanent infrastructure belongs in the static tree.
    - Enforce: review only.

82. Give dynamic processes a deliberate child spec: a unique `:id`, the
    `:start` call, and a chosen `:restart` (`:temporary` when a restart can't
    help). (p. 141)
    - Why: a child spec is a policy, not boilerplate.
    - Enforce: credo (custom: `DynamicChildRestart`): every project module
      started with `DynamicSupervisor.start_child`, directly or through a
      child spec computed in the same function, chooses `restart:` in its
      `use` options or `child_spec/1`.

83. Find processes by name, not pid: the module name for a singleton, a
    `Registry` `:via` tuple for the rest. APIs take names.
    (pp. 110, 121, 142-143, 147-148)
    - Why: pids change when processes restart.
    - Enforce: credo (custom: `ProcessNameOwnership`): each registered name
      (registries, task supervisors, `Photon.PubSub`) is named only by the
      modules that own it, listed in `.credo.exs`, so callers go through the
      owner's API with IDs. The node channel now registers through
      `Photon.Nodes.register/2`.

84. Order children by dependency and choose the strategy from that. Startup
    is about order, shutdown about timing, restart about dependencies; use
    `:rest_for_one` when later children depend on earlier ones. (pp. 144-146)
    - Why: a restart has to bring dependents back in a state that matches.
    - Enforce: review only.

85. Set shutdown on purpose: a timeout or `:brutal_kill` for workers,
    `:infinity` for supervisors and never for workers. (p. 146)
    - Why: a worker that never stops blocks the whole shutdown.
    - Enforce: credo (custom: `WorkerShutdown`): `shutdown: :infinity` only
      with `type: :supervisor`.

86. Decide what a crash loses (timers, in-memory state) and whether `init`
    should rebuild it. (pp. 141, 170)
    - Why: the book's proctor loses its scheduled timeouts on a crash unless
      `init` reloads them.
    - Enforce: review only.

87. Leave links and exit trapping to supervisors. Use a monitor when you only
    need to hear that a process died. (pp. 135-136)
    - Why: monitors are one-way and don't take the watcher down with them.
    - Enforce: review only.

88. Look at the running tree (`:observer`, `Supervisor.which_children`,
    `Registry.lookup`) to confirm the lifecycle you planned. To debug, call
    the core with the inputs you find there. (pp. 146-150)
    - Why: a pure core makes any captured state a reproducible test case.
    - Enforce: test convention (boundary tests assert on registry entries and
      children).

## Workers

89. Add worker processes only for a reason you can name: latency
    (concurrency), failure isolation, or scale. (pp. 153-155)
    - Why: concurrency has a price, and "it's the interactions between
      processes" that make systems complex (p. 164).
    - Enforce: review only.

90. Get concurrency from dependencies and frameworks first (Ecto's pool,
    Phoenix channels, Poolboy). (pp. 155-158, 160-161, 171)
    - Why: they already solved the hard parts.
    - Enforce: review only.

91. Avoid naked processes and raw `send`; use OTP abstractions.
    `Process.send_after` and `:timer.send_interval` are fine for scheduling.
    (p. 158)
    - Why: "Elixir can't manage what it doesn't know about."
    - Enforce: credo (custom: `SupervisedProcesses` and `PreferCall`, rules 80
      and 72).

92. Use tasks for one-off concurrent jobs. (pp. 158-159)
    - Why: a task is the smallest OTP-aware unit of concurrent work.
    - Enforce: review only. Note: in a long-running system, start them under a
      `Task.Supervisor` (`async_nolink`) so a crash doesn't take the caller
      with it. The book's examples use bare `Task.async`.

93. Bound concurrency: use `Task.async_stream` (its `max_concurrency` defaults
    to the scheduler count) instead of mapping `Task.async` over a list.
    (pp. 159-160)
    - Why: unbounded tasks remove back pressure and can swamp a connection
      pool.
    - Enforce: credo (custom: `BoundedTaskConcurrency`): `Task.async`,
      `Task.start` and the `Task.Supervisor` equivalents inside
      `Enum`/`Stream` functions or `for`.

94. Use a pool when many requests share a few expensive resources.
    (pp. 160-161)
    - Why: it throttles demand down to what the resource can take.
    - Enforce: review only.

95. Write worker code like any boundary (an API plus a GenServer). What makes
    it a worker is that it starts and stops other processes outside the
    lifecycle policy, like the book's quiz proctor. (pp. 153, 162)
    - Why: the code looks the same; the process organization is what differs.
    - Enforce: review only.

96. Schedule inside a process with GenServer timeouts or `Process.send_after`,
    never by sleeping. (pp. 164-166)
    - Why: a sleeping process can't read its mailbox.
    - Enforce: credo (custom: `NoSleep`): `Process.sleep` and `:timer.sleep`
      in `lib/` only where allow-listed with a reason: the model client's
      retry wait (it runs in the caller's task), a shell operation's
      `terminate/2` (a stopping process can't take messages) and the packaged
      node's keep-alive hook.

97. Find and stop processes through their supervisor and registry
    (`DynamicSupervisor.which_children`, `Registry.keys`,
    `GenServer.stop(via(name))`). (pp. 167-168)
    - Why: names and supervisors survive restarts; remembered pids don't.
    - Enforce: review only, helped by credo (custom: `ProcessNameOwnership`).

## Applying this to Photon

Photon has three Mix projects linked by path dependencies, which is the
book's poncho layout (rule 10). The dependency direction is fixed by Mix:
`core` knows nothing of the others, `node` uses `core`, and `hub` uses both
(it can run a node in its own VM). Each app holds several of the book's
layers. The tables below say which modules play which part.

### apps/core (`:photon_core`)

| Layer | Modules |
| --- | --- |
| Data | `PhotonCore.Message` (string-keyed maps that round-trip through JSON), the LLM request, config and response maps (typed in `PhotonCore.LLM`), `PhotonCore.LLM.Error`, the `%ChatCompletions.Response{}` token |
| Functional core | `PhotonCore.LLM.SSE`, `PhotonCore.LLM.Retry`, `PhotonCore.LLM.ChatCompletions.Request` and `.Response` (the wire format and the stream fold), `PhotonCore.Message`, `PhotonCore.ID.encode/3`, the mock scripts behind `PhotonCore.LLM.Mock` |
| Boundary | `PhotonCore.LLM` (the API) in front of `PhotonCore.LLM.ChatCompletions` (the HTTP adapter) and `PhotonCore.LLM.Mock`: one API in front of an external service, with retries. No server. |
| Lifecycle | None. There's no application module. |
| Workers | None. Callers run requests in their own tasks. |

This is the book's library case (rule 2): it doesn't need a process, so it has
none. Keep it that way. `PhotonCore.LLM` sleeps between retries, which is fine
because it runs in the caller's process and both callers are tasks. Calling
`LLM.stream` from a GenServer callback would break rule 96.

### apps/node (`:photon_node`)

| Layer | Modules |
| --- | --- |
| Data | Session log records (`Harness.Store` moduledoc), inputs (`Harness.Inbox`), operation snapshots (`Harness.Operation`), `PhotonNode.Config`, the `%Harness.Session{}` token |
| Functional core | `Harness.Session` (the session state machine: replay, inputs, turns, tool calls, stops, timers as effects), `Harness.Context`, `Harness.Inbox`, the `Harness.Tools.*` translators, `Harness.Output`, `Harness.Operation`, `Harness.Image`, `Harness.SkillPrompt` (the skills section of the system prompt) |
| Boundary | API: `PhotonNode.Harness` (`deliver`, `stop`, `delete`, `resume_all`, `records_from`). Servers: `Harness.Coordinator` (one per session; runs `Session` steps and their effects), `Harness.Ops` (API over operation processes), `Harness.Store` (log file I/O, owned by the coordinator). The hub link: `PhotonNode.Connection`, which implements `Harness.Link`, the contract the harness announces records and live output through, so the harness doesn't depend on the connection |
| Lifecycle | `PhotonNode` supervisor with `:rest_for_one`: registries, task supervisor, the operation and session dynamic supervisors, the connection, then a one-shot resume task, with the plan in its moduledoc. `PhotonNode.Application` starts it. |
| Workers | One process per operation (`Ops.Shell`, or `Ops.Job` for the one-shot `ViewImage` and `SkillUse` jobs) under `OpSupervisor`; model requests (`Harness.ModelRequest`) as tasks under `Harness.TaskSupervisor`; grace, heartbeat and idle-stop timers |

### apps/hub (`:photon`)

| Layer | Modules |
| --- | --- |
| Data | Ecto schemas `Photon.Durable.{Conversation, Entry, TaskRecord, Submission, Signal, Doc}` and `Photon.NodeSessions.{Session, Event, Input}`, each with `t/0`; messages from `PhotonCore.Message`; the `%NodeTranscript{}` token |
| Functional core | `Photon.Durable.{Context, Schema, Inbox, Policy, Turn, ToolCall, Changes, Queries}`, `Photon.Assistant.{Prompt, Memory, Report, Transcript, MockScript}`, `Photon.NodeSessions.Mirror`, `Photon.NodeTranscript`, `Photon.Provision.{Jobs, Script}`, `Photon.Provision.Lines` (pure apart from the `log` function it's handed), `Photon.InstallScript` (the install script and the node socket URL), `Photon.Markdown`, `Photon.Tailnet.parse/1`, and `Photon.Settings`' functions of a settings map |
| Boundary | APIs: `Photon.Durable`, `Photon.NodeSessions`, `Photon.Assistant` (Blip's context), `Photon.Nodes`, `Photon.Settings`, `Photon.Provision`. Servers: `Durable.Store` (the single commit line, a lock with no state), `Durable.Scheduler` (applies `Durable.Policy`), `Photon.Provision` (the job table), `Photon.Tailnet` (owns its cache table). Framework callbacks (rule 11): `PhotonWeb.NodeChannel` and the LiveViews, which call the contexts and do no I/O in `render/1` |
| Lifecycle | `Photon.Application` with `:one_for_one`, plan in its moduledoc: repo, migrator, PubSub, `Tailnet`, `NodeRegistry`, provisioning, `Photon.Durable.Supervisor` (`:one_for_one`: task supervisor, store, scheduler; plan in its moduledoc), endpoint, optional local node |
| Workers | Durable task steps under `Durable.TaskSupervisor` (`async_nolink`, monitored by the scheduler); the task kinds `Assistant.NodeWatch` and `Assistant.Routine`, which do the job of the book's proctor (rule 95); provisioning jobs under `ProvisionTasks` (`async_nolink`, monitored by `Provision`); `NodesLive`'s `tailscale` task (`start_async`) |

### Where Photon already follows the book

- Both harnesses store facts, not mutable state (rule 15). The node's session
  log is append-only, and the coordinator rebuilds its state by replaying the
  log through the same `apply` path it uses live. The hub commits entries and
  task transitions before anything is shown.
- The node's tools are pure translators and `Harness.Context` does no I/O
  (rule 28). `PhotonNode.Config` uses `@enforce_keys` (rule 18).
- `PhotonNode.Harness.deliver/3` validates the session ID and input at the
  entry point and composes the steps with `with` (rules 64, 66).
- Sessions and operations are found through `Registry` via tuples, not pids
  (rule 83). Restart policies are chosen per type: coordinators are
  `:transient`, operations `:temporary` (rule 82). `PhotonNode` uses
  `:rest_for_one` because the connection and the resume task depend on the
  registries and supervisors started before them (rule 84).
- Model requests run under a `Task.Supervisor` with `async_nolink` and are
  monitored (rule 92).
- `Durable.Store.commit/1` is a `GenServer.call` through a single writer, so
  writers get back pressure from the database (rule 72). Nothing in the repo
  uses `GenServer.cast`.
- `PhotonWeb.NodeChannel` is thin: it hands everything to `NodeSessions` and
  `Nodes`, and ignores events it doesn't know (rules 11, 75). The coordinator
  and operations also drop unknown messages. No web module touches the repo.
- Hub tests wait on PubSub (`DataCase.await_change/3`, `await_entry/3`)
  instead of sleeping, and start the durable processes with
  `start_supervised!` (rule 55).

### Where it drifts, roughly in order of payoff

1. `Harness.Coordinator` is 826 lines, and much of it is core logic living in
   the GenServer (rules 28, 30): replaying records (`apply_item`,
   `apply_input`, `overlay`), deciding when a turn starts (`decide`,
   `pending`, `idle?`), and scheduling tool calls. A pure session module with
   something like `apply(state, record)` and `decide(state)` returning effects
   could be tested without processes and files. The GenServer would keep the
   rest: persist, dispatch, arm timers. The log format wouldn't change.
   Status: done. `Harness.Session` is that module (a token that collects
   effects), and `Coordinator` runs it; see the node section of the
   refactor log in `docs/architecture.md`.
2. Each hub task kind (`Durable.Generation`, `Durable.ToolTask`,
   `Assistant.NodeWatch`, `Assistant.Routine`) mixes decisions with
   `Runtime.commit` and model calls inside `step/3`. Committing before showing
   is the point of the durable design, and the book allows persistence-shaped
   code when that's the problem (p. 174). Still, the choice each phase makes
   could be a pure function of the task and its entries, with the commit at
   the edge (rules 7, 28). The same goes for `Durable.Scheduler.wake?/2`,
   which reads signals and task statuses from the repo in the middle of
   deciding; handed those as arguments, it would be pure. Status: done in
   the hub refactor (see its refactor log in `docs/architecture.md`).
   `Durable.Turn`, `Durable.ToolCall`, `Durable.Inbox` and
   `Durable.Policy` (whose `wake?/3` takes the statuses and the signal as
   facts) are pure, and the task kinds and the scheduler commit what they
   decide. Each decision still commits on its own, re-checking its task,
   so the interleavings `Durable.tla` checks are unchanged.
3. There are no typespecs: zero `@spec` across the three apps. Start with the
   API modules, `PhotonCore.LLM`, `PhotonNode.Harness`, `Photon.Durable`,
   `Photon.NodeSessions` and `Photon.Assistant` (rule 70). Status: every
   public function in `apps/core` now has a spec (see the refactor log in
   `docs/architecture.md`), and so does every public function in
   `apps/node`'s `lib`, `PhotonNode.Harness` first, and every public
   function in `apps/hub/lib/photon` plus the hub's web modules other than
   function components and the Phoenix scaffolding. Those have specs now
   too, and Credo's `Readability.Specs` requires one on every public
   function in `lib/`.
4. Bare `send` is the notification mechanism in `Harness.deliver/3`,
   `Coordinator.notify/2`, `Connection.notify/1`, `Scheduler.notify/2` and
   `Nodes` (rule 72). Most of these are deliberate: inputs are stored on both
   sides and deduplicated by ID, so a lost message is recovered by
   redelivery. The producers feeding `PhotonNode.Connection` are rate limited
   too (shell output is sampled once a second in bounded chunks). Say so in
   the moduledocs, so the next person doesn't add a fast producer to the same
   path (rule 73). Status: done on the node (`Connection`, `Coordinator`,
   `Ops`, `ModelRequest`, `Ops.Shell`); the client functions are now
   `Connection.event/3` and `Coordinator.report_op/2`. On the hub,
   `Scheduler.notify/2`, `Nodes.command/3`, `Durable.live/2`,
   `ToolAPI.output/2` and `NodeSessions.live/2` say the same in their docs.
5. `Ops.Shell` sleeps with backoff inside its GenServer while it waits for a
   killed process group to exit, for up to `@term_grace_ms` (5 seconds)
   (rule 96). The cost is one operation that can't answer `:resend` or
   `:cancel` for a few seconds. A `send_after` poll would fix it. Status:
   fixed that way. Messages that arrive during the wait are postponed and
   handled in order once the group is gone, so the shell handles them in
   the same order as before; only `terminate/2` still waits in place.
6. `Photon.Tailnet.start_cache/0` owns its ETS table with `spawn_link` and
   `Process.sleep(:infinity)` (rules 80, 91). It's started from a supervisor
   through `child_spec/1`, so the lifecycle mostly works, but the process
   doesn't speak OTP. A small GenServer that creates the table in `init/1` is
   the standard form. Status: fixed that way; lookups still go straight to
   the table.
7. `hub/test/photon/node_install_test.exs` sleeps 100 ms twice while waiting
   for OS processes (rule 55). `assert_receive` can't see OS processes, so the
   fix is a bounded "eventually" poll like the book's `eventually_match`
   (p. 90). No test file uses `describe` or named setups yet (rule 47), and
   no coverage threshold is set (rule 50). Status: fixed with a bounded
   poll (`Photon.Eventually`); the hub's tests are laid out by layer, use
   `describe` with named setups and shared fixtures, and `mix.exs` sets an
   85% threshold.
8. Neither Credo nor `boundary` is a dependency, and `mix precommit` runs only
   compile, unused-deps, format and test. Status: done; see the next section.
   Making the layering checkable took four small moves, none of which
   changes behavior: the harness announces to the hub through
   `Harness.Link` (the connection implements it) instead of calling
   `PhotonNode.Connection`, and the connection replays through
   `Harness.records_from/2` instead of reading `Harness.Store`; the pure
   half of `Harness.Skills` moved to `Harness.SkillPrompt`; the install
   script and socket URL moved from `NodeDist` and `Hub` (which still
   delegate) to the pure `Photon.InstallScript`, so `Provision.Script`
   depends on no boundary module; and the node channel registers through
   `Photon.Nodes.register/2` instead of naming `Photon.NodeRegistry`.

### How the rules are enforced

Each app runs every check with `mix precommit` (in the test environment):

```sh
mix compile --warnings-as-errors   # compiler warnings, Elixir 1.20's type checker, boundary
mix deps.unlock --check-unused
mix format --check-formatted
mix credo --strict
mix test --warnings-as-errors
```

`mix dialyzer` is separate, since its first run builds the PLTs (about
three minutes per app; later runs take seconds to a minute). `mix test
--cover` checks the coverage threshold (rule 50).

**Credo.** `tools/credo_checks/shared_checks.exs` holds the checks every
app runs: Credo's defaults plus the opt-in ones named in the rules above,
set to the book (nesting 2, cyclomatic complexity 8, ABC size 30, arity 5,
module dependencies 20), and the custom checks that need no per-app lists.
Each app's `.credo.exs` adds what needs its own module lists: the
functional-core modules (`FunctionalCore`), the API modules and process
names (`ProcessNameOwnership`), the callbacks to keep thin
(`ThinCallbacks`), the LiveView rules (hub), and the allow lists, each
entry with its reason (`PreferCall`, `NoSleep`). Rules about how the system
is built apply to `lib/`; tests get the readability and test-convention
rules. The custom checks live in `tools/credo_checks/lib` and are tested in
`apps/core`'s suite (`tools/credo_checks/test`).

| Custom check | Rules |
| --- | --- |
| `FunctionalCore` | 28, 29 |
| `ThinCallbacks` | 30 (and 4, 11) |
| `LiveViewLogic` | 11 |
| `PreferCall` | 72, 91 |
| `MessageOwnership` | 63 |
| `ProcessNameOwnership` | 62, 83, 97 |
| `SupervisedProcesses` | 16, 80, 91 |
| `NoSleep` | 55, 96 |
| `BoundedTaskConcurrency` | 93 |
| `DynamicChildRestart` | 82 |
| `WorkerShutdown` | 85 |
| `EnforceKeys` | 18 |
| `StructType` | 17, 32, 39, 69 |
| `DeepAccessPath` | 14 |
| `SmallTuples` | 25 |
| `AccumulatorConcat` | 24 |
| `IndexAccessInLoop` | 21 |
| `CaptureTestLogs` | 56 |

**Boundary.** Every app has the `:boundary` compiler, so a forbidden
reference is a compiler warning, and an error under `--warnings-as-errors`.
The layering it encodes:

- `apps/core`: `PhotonCore` (the message format and IDs) is strict and
  depends only on Jason. `PhotonCore.LLM.Error` and `PhotonCore.LLM` (the
  model client) are top-level boundaries of their own, so another app's
  functional core can use the message format and record a model failure
  without being able to call the HTTP client. Inside the client, `SSE`,
  `Retry` and the wire format (`ChatCompletions.Request`, `.Response`,
  `.Wire`) are strict, pure sub-boundaries.
- `apps/node`: `PhotonNode` (the supervisor) holds `Config`, `CLI`,
  `Connection` and `Harness`. The connection depends on the harness; the
  harness only on `Config` and the node's config accessor, and reaches the
  hub through `Harness.Link`. Each functional-core module of the harness is
  a strict sub-boundary that may name only other core modules.
- `apps/hub`: each context (`Durable`, `NodeSessions`, `Assistant`,
  `Nodes`, `Settings`, `Provision`, `Repo`, and so on) is a sub-boundary of
  `Photon` with explicit `deps:`; `Photon` exports the contexts; `PhotonWeb`
  depends only on those exports and never on Ecto; `Photon.Application`
  sits above both, and is the only hub module that may use the node app
  (it starts the embedded node). `Photon.Durable` exports its API, its schemas, `Tx`,
  `Runtime` and the tool and task-kind contracts, and keeps `Store`,
  `Scheduler`, the built-in task kinds and its functional core inside. The
  functional-core and data modules are strict sub-boundaries: data depends
  on Ecto's schema macros only, and the core on data, other core modules
  and the `Durable.Tool` contract.

What boundary can't see, Elixir's own modules (`GenServer`, `Process`,
`File`, `System`), the `FunctionalCore` check covers.

**Types.** Every public function in `lib/` has a `@spec`
(`Readability.Specs`) and every struct a `@type t` (`StructType`).
Elixir 1.20 infers types from patterns, guards and function bodies, across
clauses and across modules, including the path dependencies, and reports
violations as compile warnings; `--warnings-as-errors` on compile and test
makes them failures. It doesn't read `@spec` yet, so the specs serve
readers and Dialyzer, which runs with `:error_handling`, `:extra_return`
and `:missing_return`, so a spec that is wider or narrower than what the
function returns is reported. The few findings that aren't bugs are listed,
with reasons, in each app's `.dialyzer_ignore.exs`. `:unmatched_returns` is
on, so every ignored result is a visible decision:

- Results that can't fail don't need ignoring. Announcements go through
  `Photon.Events`, which logs a failed broadcast or subscription and returns
  `:ok`; timer cancels and similar helpers return `:ok` and say why the
  underlying result doesn't matter.
- A result that may carry an error is handled, or dropped with `_ =` and a
  comment saying why (`PhotonCredo.Check.DiscardNeedsReason`).
- A named discard (`_entry = Tx.append(...)`) needs no comment only when the
  call can't carry an error: a raising (`!`) function, or a module on the
  check's allow-list, with its reason (the hub lists `Photon.Durable` and
  `Photon.Durable.Tx`, whose writes raise on failure).
- Every other exception says why too: each `.dialyzer_ignore.exs` entry sits
  under a reason comment (`DialyzerIgnoreReasons`), and so does every inline
  `credo:disable` comment and `@dialyzer` attribute (`SuppressionNeedsReason`).

Turning it on found real gaps: an unchecked workspace `mkdir`, a stale
shell exit file whose failed removal went unnoticed, and a node-session
delete that ignored the database's answer.

# unreal-agent → Elixir/OTP porting spec

Source: `github.com/unreallabsai/unreal-agent` at `1b9f778453f411c029b39b85102aaefb95e7e48d` (2026-09-23). Module `github.com/unreallabsai/unreal-agent`, Go 1.27, `encoding/json/v2`, stdlib `uuid`.

This document describes what the Go code does, including its quirks, so an OTP port can match it on the wire, on disk, and in what the model sees. Paths below are relative to the upstream repo root. "OTP note" callouts mark places where the Go design comes from Go itself (goroutines, channels, `context`) and a port should do it differently.

---

## 0. Map of the code

| Area | Files |
| --- | --- |
| Session identity | `harness/session/session.go` |
| Inbox | `harness/inbox/inbox.go`, `local.go` |
| Coordinator | `harness/coordinator/coordinator.go`, `loop.go` |
| Session store interface | `harness/sessionstore/sessionstore.go`, `itemjson.go` |
| Local file store | `harness/sessionstore/localfile/{codec,state,store,list}.go` |
| Context builder | `harness/contextbuilder/{contextbuilder,builder,skills}.go`, `prompts/*.md` |
| LLM types | `harness/llm/{model,adapter,itemjson}.go` |
| Responses API adapter | `harness/llm/responsesapi/{adapter,request,response,stream,retry}.go` |
| Provider clients | `harness/llm/clients/{openai,fireworks,openrouter,ollama,openaicodex}` |
| Tools | `harness/tool/{tool,registry,static,skill_use,output}.go`, `tool/bash/bash.go`, `tool/viewimage/viewimage.go` |
| Operations | `harness/operation/{operation,output,value,shell,image,skill_use,local_manager,remote_job,remote_job_handler,remote_job_output}.go` |
| Primitives | `harness/primitives/{process,file,file_create_unix,remote,remote_sse,sse,timer,compute,primitive_*}.go` |
| Runner | `cmd/unreal-agent-runner/{main,tools}.go`, `cmd/internal/agentrunner/{run,config,providers,usage}.go` |

There is **no context truncation or compaction** in this code. `contextbuilder.Report` and `session.TurnCompaction` exist as hooks, but nothing produces them. The full history goes to the model on every turn (§7.5).

---

## 1. Architecture in one page

```
            Submit(Input)                      Updates() <-chan Operation
 runner ───────────────► Inbox ──Output()──┐        ┌──── OperationManager (actor runtime)
 (heartbeat timer also submits here)       ▼        ▼          ▲ Add(op) / Cancel(id, reason)
                                     ┌───────────────────┐      │
                                     │    Coordinator    │──────┘
                                     │ (single goroutine │──── Respond(ctx, req) ──► LLM Adapter (goroutine per turn)
                                     │   select loop)    │
                                     └───────┬───────────┘
                    AppendInput/Turn/ModelResponse/ToolCallStatus, SaveOperation
                                             ▼
                                       Session Store ──observer (sync)──► runner writes JSONL to stdout
                                             ▲
             ContextBuilder (pure, in-memory) ◄── coordinator feeds every item it applies
             Tool Registry → Translators (pure; run on the coordinator loop)
```

- **Input**: an event with a caller-supplied, globally unique ID that stays stable across redeliveries.
- **Inbox**: in-memory dedupe of inputs for one session.
- **Session**: append-only persisted history. It can be forked.
- **LLM turn**: one logical model request, managed by the coordinator.
- **Tool translator**: validates a tool call and turns it into zero or more *operations*. It runs synchronously on the coordinator loop and does no I/O. It also formats a recorded call status plus operation snapshots into model-facing output.
- **Operation**: a versioned, serializable description of work, advanced by an actor in the operation manager through *primitives* (process, file I/O, HTTP, timer, compute).

Ordering rules the code enforces (tests depend on them):

1. An input is applied to local state, then persisted, before it can influence a model request.
2. A `turn` item is persisted before the LLM request starts.
3. A `model_response` is persisted before its tool calls are translated.
4. A `tool_call_status` that carries new operations is persisted before those operations go to the manager.
5. An operation update is persisted (`SaveOperation`) before it can complete a tool call.
6. Any persistence failure is fatal: `Run` returns the error.

---

## 2. JSON conventions (Go `encoding/json/v2`)

Persisted and stdout JSON comes from Go structs with **no JSON tags**, so keys are the Go field names in PascalCase (`"Sequence"`, `"RecordedAt"`, `"Kind"`, `"Data"`, `"TurnID"`, `"CallID"`, …). Exceptions are noted where the code has tags (`logRecord` uses lowercase `type`/`data`; the runner request and error event use snake_case).

json v2 behaviors the port has to match:

- Keys come out in struct field order. The orders are listed in §3.
- `omitzero` omits zero values. Fields without it are always present: `""`, `0`, `false`, `null`.
- A nil slice encodes as `[]`, but a nil **`[]byte`** encodes as `""`. Every `[]byte` encodes as **standard base64**. This applies to `ShellState.InlineOut/InlineErr/InlineOutTail/InlineErrTail` and `SkillUseState.Content`.
- Pointers encode as `null` when nil (`"PendingExitCode":null`, `"Result":null`, `"Failure":null`).
- `time.Time` encodes as RFC 3339 with nanoseconds and trailing zeros trimmed, in UTC (`"2026-09-22T19:37:47.30313177Z"`).
- Unmarshal is **case-sensitive** and rejects duplicate object keys. Unknown keys are ignored unless `RejectUnknownMembers` is set, which happens for control payloads and the runner request.
- Strings with invalid UTF-8 make marshal fail. Every path that touches arbitrary bytes sanitizes them to U+FFFD first.
- `json.Deterministic(true)` (used for LLM request bodies) sorts map keys.

> OTP note: Jason does not keep map key order. For byte-stable output (session files, stdout, and above all LLM request bodies, where prefix caching depends on byte-identical prefixes), encode with ordered structures (`Jason.OrderedObject`, or iodata built by hand) in the orders given here. Go timestamps carry nanoseconds; Erlang gives microseconds. Parse leniently, and emit RFC 3339 with up to 9 fractional digits and trailing zeros trimmed.

---

## 3. Data model (exact field names and order)

### 3.1 Session identity (`harness/session`)

```
Session { ID string, CreatedAt time }                 // ID: [A-Za-z0-9-]+ (store validation)
Turn    { ID TurnID, PreviousTurnID TurnID, Type TurnType }   // Type: "regular" | "compaction"
```

### 3.2 Inbox input (`harness/inbox`)

```
Input          { ID string, Kind "external"|"control"|"crash", Payload json (omitzero) }
ControlMessage { Mode string, Reason string, Parameters any (omitzero) }
Settings       { ReasoningEffort string (omitzero) }   // "low"|"medium"|"high"|"xhigh"|"max"
```

Control modes: `"hard"`, `"when_idle"`, `"heartbeat"`, `"settings"`.

### 3.3 LLM types (`harness/llm`)

```
Item       { ProviderID string, Type "message"|"tool_call"|"tool_result"|"reasoning", Data <by Type> }
Message    { Role "user"|"assistant"|"system", Text string, Phase string }
ToolCall   { CallID string, Name string, Arguments string }          // Arguments = raw JSON text from the provider
ToolResult { CallID string, Output []ToolResultOutput }
ToolResultOutput { Kind "text"|"image", Value string }               // image Value = URL or data: URL
Reasoning  { Summary []string (omitzero), Raw json (omitzero) }      // Raw = provider item verbatim
Tool       { Type "function"|"hosted", Name, Description, Parameters map }
Model      { ID string, MaxOutputTokens *int64, ReasoningEffort string }
Request    { Model, Input []Item, Tools []Tool }
Response   { ID string, Stop "complete"|"max_output_tokens"|"refused"|"", Output []Item (omitzero), Usage, Failure *Failure }
Usage      { InputTokens, CachedInputTokens, CacheWriteInputTokens, OutputTokens, ReasoningTokens int64, Raw json (omitzero) }
Failure    { Code string, Message string }
```

`InputTokens` includes cached and cache-write tokens. `OutputTokens` includes reasoning tokens.

### 3.4 Session store items (`harness/sessionstore`)

```
Item           { Sequence uint64, RecordedAt time, Kind "fork"|"input"|"turn"|"model_response"|"tool_call_status", Data <by Kind> }
Fork           { ParentID SessionID, PreviousTurnID TurnID }
ModelResponse  { TurnID, Response llm.Response }
ToolCallStatus { TurnID, CallID string, Status tool.CallStatus, Operations []Operation (omitempty) }
tool.CallStatus{ Error string, ErrorTruncated bool (omitzero), WaitingFor []OperationID (omitzero) }
ResumeState    { Snapshot{Session}, Operations []Operation, ExternalInputIDs []InputID }
```

`Data` is decoded according to `Kind`. `null` Data is an error.

### 3.5 Operation (`harness/operation`)

```
Operation { MaxOutputLength int (omitzero), ID string, Type string, Version uint32,
            Status "ready"|"awaiting"|"canceling"|"completed"|"failed"|"canceled",
            State json (omitzero), Idempotency json (omitzero) }
Spec      { MaxOutputLength (omitzero), Type, Version, State (omitzero), Idempotency (omitzero) }
```

Terminal statuses are `completed`, `failed`, and `canceled`. `Idempotency` is passed through untouched. Built-in operations never set it; it exists for remote or proxy managers.

| Type | Version | State struct |
| --- | --- | --- |
| `shell` | 3 | `ShellState` (§9.3) |
| `view_image` | 1 | `ViewImageState` (§9.4) |
| `skill_use` | 1 | `SkillUseState` (§9.5) |
| `value` | 1 | `ValueState { Value json }` (test-only; ready→completed, canceling→canceled) |
| `remote_job` | 2 | `RemoteJobState` (§9.6) |

---

## 4. Session store (`localfile`)

### 4.1 Files on disk

- Directory: `-session-directory`, which defaults to `${XDG_STATE_HOME or $HOME/.local/state}/unreal-agent/sessions`. Created with mode `0700`.
- One file per session: `<dir>/<sessionID>.session.jsonl`. The session ID must match `^[A-Za-z0-9-]+$`.
- Operation artifacts (written by the shell operation, not the store): `<dir>/operations/<sessionID>/<operationID>/{out,err}`. Directories `0700`, files `0600`.
- `ListSessions` reads the directory only. It returns `{ID, LastUpdatedAt = file mtime UTC}`, sorted by ID, and skips invalid names and files it can't stat.

### 4.2 Record format (format version **2**)

Each line is one record: `{"type": <recordType>, "data": <object>}\n`. A record never contains a raw newline.

```jsonl
{"type":"session","data":{"Version":2,"Session":{"ID":"golden-session","CreatedAt":"2026-08-27T10:00:00Z"}}}
{"type":"item","data":{"Item":{"Sequence":1,"RecordedAt":"…","Kind":"input","Data":{"ID":"input-1","Kind":"external","Payload":{"message":"hello"}}}}}
{"type":"item","data":{"Item":{"Sequence":2,"RecordedAt":"…","Kind":"turn","Data":{"ID":"turn-1","PreviousTurnID":"","Type":"regular"}}}}
{"type":"item","data":{"Item":{"Sequence":3,"RecordedAt":"…","Kind":"model_response","Data":{"TurnID":"turn-1","Response":{"ID":"response-1","Stop":"complete","Output":[{"ProviderID":"message-1","Type":"message","Data":{"Role":"assistant","Text":"working","Phase":"commentary"}},{"ProviderID":"reasoning-1","Type":"reasoning","Data":{"Summary":["inspect"],"Raw":{"encrypted":"opaque"}}}],"Usage":{"InputTokens":10,"CachedInputTokens":2,"CacheWriteInputTokens":1,"OutputTokens":4,"ReasoningTokens":3,"Raw":{"provider_total":14}},"Failure":null}}}}}
{"type":"item","data":{"Item":{"Sequence":4,"RecordedAt":"…","Kind":"tool_call_status","Data":{"TurnID":"turn-1","CallID":"call-1","Status":{"Error":"","WaitingFor":["operation-1"]}}},"Operations":[{"ID":"operation-1","Type":"test","Version":1,"Status":"ready","State":{"step":1},"Idempotency":{"key":"one"}}]}}
{"type":"operation","data":{"Operation":{"ID":"operation-1","Type":"test","Version":1,"Status":"awaiting","State":{"step":2},"Idempotency":{"key":"one"}}}}
```

| `type` | `data` | Rules |
| --- | --- | --- |
| `session` | `{Version int, Session {ID, CreatedAt}}` | Must be line 1 and the only header. `Version==1` → error `legacy session format version 1 cannot be resumed`. Any other version ≠2 → `unsupported session format version N`. `CreatedAt` must not be zero. The ID must equal the requested ID (`file contains session "X"`). |
| `item` | `{Item <Item>, Operations []Operation (omitempty)}` | `Item.Sequence` must equal the previous item count + 1 (contiguous from 1). `RecordedAt` must not be zero. Only `tool_call_status` may carry `Operations`. **In the file, the status's `Data.Operations` is stripped and moved to the record-level `Operations`.** |
| `operation` | `{Operation <Operation>}` | A full latest-state snapshot for an operation that already exists. It may not change `Type`/`Version`. It may not appear before the last `fork` item. |

### 4.3 Write protocol (durability)

- **Create / Fork** encode the whole initial log, write it to `<dir>/.session-*.tmp`, `fsync`, `rename` onto the target (**this replaces an existing session file**), then `fsync` the directory.
- **Append**: open `O_WRONLY|O_APPEND`, **truncate to the last committed size** (this drops a torn partial line from a crash), write one line, `fsync`. Each append is a separate open/sync/close.
- **Read**: everything after the last `\n` is ignored as an uncommitted tail.
- A per-store-instance cache keeps `(sessionHead, committedSize)` for each session so appends don't re-read the file. Any failed write evicts the cache entry. The cache assumes one writer per session. The `Store` interface says it "does not serialize methods for the same session ID".

> OTP note: use one store process per session (a GenServer that owns the file). That serializes writes naturally and holds the head and committed size in its state. `:file.sync/1` covers file fsync. Erlang's `:file` can't fsync a directory, so a NIF/port or `sync -f <dir>` is needed if you want exact rename durability.

### 4.4 Validation on append (the "session head")

The head tracks the item sequence, `latestTurnID`, all turn IDs, **owned** turns, responded turns, the `(turnID, callID)` keys that have a status, and the operation list and positions.

- `AppendInput`: `input.Validate()` must pass (§5).
- `AppendTurn`: `ID` must not be empty. `PreviousTurnID` must equal the head's `latestTurnID` (initially `""`). The ID must be new. The turn is marked owned and becomes latest.
- `AppendModelResponse`: the turn must be **owned**, which excludes turns inherited through a fork. At most one response per turn.
- `AppendToolCallStatus`: the turn must be owned and `CallID` must not be empty.
  - **First status** for `(turn, call)`: every operation must pass `validateOperation`, have a unique ID within the batch and the session, and match the status:
    - `Error != ""` → `WaitingFor` and operations must both be empty.
    - otherwise → at least one operation, `len(WaitingFor) == len(ops)`, no repeated IDs, and every waited ID must be one of the initialized ops.
    - Then the operations are *initialized* (appended to the head's operation list).
  - **Later statuses** for the same key are appended as new items with no further validation. Their `Operations` are stored as snapshots but initialize nothing. This is how completions are recorded (§6.6).
- `SaveOperation`: the operation must exist in the head. `Type`/`Version` must not change. It replaces the head's latest state.
- `validateOperation`: ID, Type non-empty; Version ≠ 0; Status one of the six; `State`/`Idempotency` valid JSON if present.

### 4.5 What gets persisted, and when (coordinator → store)

| Event | Store call | Record(s) | Emitted on stdout? |
| --- | --- | --- | --- |
| Inbox input accepted (any kind, including settings, stops, heartbeats) | `AppendInput` | `item/input` | yes |
| Turn starts | `AppendTurn` | `item/turn` | yes |
| Model response for the current turn | `AppendModelResponse` | `item/model_response` | yes |
| Tool call translated | `AppendToolCallStatus` with initial op snapshots (`ready`) | `item/tool_call_status` + record-level `Operations` | yes, with `Data.Operations` inline |
| Each operation checkpoint from the manager | `SaveOperation` | `operation` | **no** |
| All ops of a call reached terminal | `AppendToolCallStatus` (same `Status`, terminal snapshots) | `item/tool_call_status` | yes |
| Fork | `Fork` | new file; emits the `fork` item only | yes (fork item) |

### 4.6 Resume (`Store.Resume`)

1. Decode the log: replay items through the head (inherited items, those at or before the last fork, go through `inheritItem` without ownership checks), and fold `operation` records into latest states.
2. Return `ResumeState`:
   - `ExternalInputIDs`: the IDs of all `input` items with `Kind=="external"`, in order. Control, heartbeat, and crash IDs are not included.
   - `Operations`: every operation the session owns whose **latest** state is non-terminal, **or** whose latest terminal state was never recorded in a `tool_call_status` snapshot. Precisely: walk statuses in order, keep a `pending` set where a non-terminal snapshot adds the ID and a terminal snapshot removes it, and include an op if `!terminal(latest) || id ∈ pending`.
   - `Snapshot{Session}`.

The coordinator rebuilds the rest by paging through `Items(after, 256)` (§6.10).

### 4.7 Fork (`Store.Fork(ctx, childID, parentID, previousTurnID)`)

- `childID ≠ parentID`. The parent must be readable.
- **Boundary**: scan the parent's items in order. `boundary` = the index of the last item that refers to `previousTurnID` (its `turn` item, its `model_response`, or any `tool_call_status` with that `TurnID`) **before the next `turn` item after the first match**. Statuses for that turn recorded after a newer turn are excluded. If nothing matches → `fs.ErrNotExist`.
- The child file holds `parent.Items[0..boundary]` copied **with their original Sequence/RecordedAt**, with `ToolCallStatus.Operations` stripped (a TODO in the code), followed by a new `fork` item `{ParentID, PreviousTurnID}` at `Sequence = boundary+1`.
- After the fork item, owned turns, responded turns, status keys, and operations reset. `latestTurnID` stays the parent's last inherited turn, so the child's first turn has `PreviousTurnID = previousTurnID`.
- Observers get only the fork item.

**Known upstream gap** (marked FIXME/TODO): inherited tool calls whose results came from operations lose those results in the child. Operation snapshots are stripped and the coordinator clears tool calls and operations on `fork`, so the child's context can contain a `function_call` with **no** `function_call_output`, which OpenAI rejects. Error-status results (no operations) do survive. Pending-input accounting is also carried across the fork as-is.

### 4.8 Observers

`AddObserver(fn(sessionID, Item))` is called **synchronously after** each successful item append, including the fork item, in registration order. Observers do not see operation records. For `tool_call_status` the observer gets the canonical item with `Data.Operations` re-attached.

> OTP note: Go calls observers inline on the coordinator goroutine, so the stdout write applies backpressure to the loop, and an output failure cancels the run. In OTP, either keep the write synchronous inside the store process or send to a writer process. If you do the latter, decide what an output failure means (the runner treats it as fatal).

---

## 5. Inputs and the inbox

### 5.1 Validation (`Input.Validate`)

- `ID` must not be empty.
- `Kind` is `external`, `control`, or `crash`.
  - `control`: `Payload` is decoded with **RejectUnknownMembers** into `{Mode, Reason, Parameters}`.
    - Only `settings` may have `Parameters`. Any other mode with parameters → `control mode "X" does not accept parameters`.
    - `hard`, `when_idle`: `Reason` is free text and may be empty.
    - `heartbeat`: `Reason` must not be empty.
    - `settings`: `Parameters` is decoded (RejectUnknownMembers) into `Settings`. `ReasoningEffort` must be one of the five valid values. **The empty string is invalid.**
    - Anything else → `unsupported control mode "X"`. Old sessions that contain `"Mode":"soft"` fail to resume with this error.
  - `external` and `crash` have no payload schema here. `Payload`, if present, must be valid JSON.
- The coordinator also requires an `external` payload to be a **JSON string** (the user text). Otherwise `AddExternalInput` fails *before* persistence and `Run` returns `add input "<id>" to context: …`.
- `crash` inputs are accepted and persisted but have no effect: they don't enter context and don't count toward pending inputs. Nothing in the repo produces them.

### 5.2 Dedupe (`inbox.New(ctx, seenIDs)`, `Submit`, `Output`)

- An in-memory `seen` set per session, seeded with `ResumeState.ExternalInputIDs`. An empty seed ID → error.
- `Submit` validates, then hands the input to the inbox goroutine. A duplicate `ID` (**across all kinds**, the first one wins) is silently dropped and `Submit` returns `nil`. Accepted inputs go into an unbounded FIFO. `Submit` never waits for the consumer, and payloads are cloned.
- `Output()` yields accepted inputs in submission order. It closes when the inbox context ends.
- Consequence: an external `message_id` resent in a later run is ignored, because its ID was persisted. Control and heartbeat IDs are only deduped within one process lifetime.

> OTP note: the inbox can be a MapSet plus a `:queue` inside the coordinator, or a small GenServer. Keep FIFO order and the "drop duplicates silently, return :ok" contract.

---

## 6. Coordinator

### 6.1 State

```
currentTurnID, currentTurnType
toolCalls: map[(turnID, callID)] → { toolCall, status *CallStatus (nil = untranslated), operations set }
operations: map[opID] → latest Operation
availableInputs   // count of things the model must see: external inputs + heartbeats + finished tool calls
deliveredInputs   // availableInputs as of the start of the last turn that got a response
currentTurnInputs // availableInputs when the current turn's Turn item was applied
callModel bool    // "start a turn now" flag
grace timer + graceToolCalls set
cancelModel       // non-nil while an LLM request is in flight
stop { request ControlMessage, cancellationRequested bool }
```

`pendingInputs = availableInputs - deliveredInputs`.

### 6.2 Constants

| Name | Value |
| --- | --- |
| `historyPageSize` | 256 |
| `slurpIdleTimeout` | 1 ms |
| `slurpMaxItems` | 100 |
| `toolCallRunGracePeriod` | 1 s |
| `ToolHeartbeatInterval` | dependency. Runner default **10 min**, `0` disables, negative → `Run` error `tool heartbeat interval must not be negative` |

### 6.3 Applying an item to local state (`addItemToLocalState`)

The same function runs for live items and for replay, so replay rebuilds exactly the same state.

- **fork**: clear `toolCalls`, `operations`, and grace.
- **input**:
  - `external` → `ContextBuilder.AddExternalInput` (staged user message), `availableInputs++`.
  - `control` → `ContextBuilder.AddControlMessage`. Settings change the reasoning effort immediately; heartbeat stages a user message. A **heartbeat** also does `availableInputs++`. Stop modes have no context effect.
- **turn**: set `currentTurnID/Type`, set `currentTurnInputs = availableInputs`, and `ContextBuilder.Commit()` (staged suffix → committed prefix).
- **model_response**:
  - If it belongs to the current turn and that turn is a compaction turn, it is ignored for context and scheduling.
  - Otherwise → `ContextBuilder.AddModelResponse` (appends all output items to the committed prefix). If `TurnID == currentTurnID`, set `deliveredInputs = currentTurnInputs`. Register each `tool_call` output as an untranslated tool call keyed `(TurnID, CallID)`.
- **tool_call_status**:
  1. Overlay every op snapshot in `Operations` into `operations`.
  2. If the call is tracked, set `status` and add `WaitingFor` IDs to the call's op set.
  3. **Add the tool result** (`addToolResultToLocalState`):
     - The call is untracked → nothing. This is an "orphaned" status and is accepted.
     - No translator resolves (tool unavailable) → if the status is error-only, add the result `[text: status.Error]` (raw, no prefix) and finish the call. Otherwise nothing; restore will already have failed (§6.11).
     - Some waited op is missing from the call's set or from `operations` → nothing, so no result is added.
     - Otherwise → `TranslateResult(callID, status, ops in WaitingFor order)`. A translation error is fatal. `running = !all waited ops terminal`, then `ContextBuilder.AddToolResult(callID, output, running)`. If not running → **finish** the call: delete it from `toolCalls`, remove it from the grace set (and clear grace if the set is empty), and `availableInputs++`.
- A call with an error status and no operations is "all terminal" (empty set), so it finishes immediately.

### 6.4 The event loop (`Run`)

```
restore()                                   // §6.10
statuses = scheduleToolCalls()              // translate calls recorded without a status
reconcileToolCalls()                        // record completions known from saved op states
dispatch every non-terminal op to manager   // Add(op) (cloned)
if any status needs a response (§6.5) or pendingInputs > 0: requestModelResponse()

loop:
  heartbeat timer: armed when entering "waiting only for tool calls", disarmed when leaving (§6.9)
  select one of:
    ctx done                 → return ctx.Err()
    inbox output (1 input)   → processInputs([input])        (closed → error "inbox output closed")
    operation update (1)     → processOperations([update])   (closed → error "operation updates closed")
    heartbeat timer          → postHeartbeat()
    grace timer              → clearToolGrace()
    model result             → if no request in flight or turnID != currentTurnID: ignore
                               else processModelResponse()
  callModel = processEvents()                               // slurp + reconcile (§6.7)
  if stop mode == hard: handleStop(); if no pending ops → return ctx.Err() (nil); continue
  if callModel: requestModelResponse(); clearToolGrace()
  if stop mode == when_idle and isIdle(): return ctx.Err() (nil)
```

`processEvents` returns `callModel || (pendingInputs > 0 && no request in flight && graceToolCalls empty)`.

`isIdle` = no request in flight, `pendingInputs == 0`, `toolCalls` empty, and no non-terminal operations.

### 6.5 Turn state machine

States, as derived from fields:

| State | Condition |
| --- | --- |
| **Idle** | no request in flight, no pending inputs, no tool calls |
| **ModelInFlight** | `cancelModel != nil` |
| **Grace** | no request in flight, `graceToolCalls` non-empty, grace timer armed |
| **WaitingForTools** | no request in flight, no pending inputs, `toolCalls` non-empty (heartbeat armed) |
| **Stopping(hard)** | `stop.cancellationRequested`; waiting for ops to settle |
| **Stopped** | `Run` returned |

**Starting a turn** (`requestModelResponse`):

1. Cancel any in-flight request. This is what makes a new external input *steer*.
2. `built = ContextBuilder.Build()`. On error → fatal `build model request: …`.
3. `turn = {ID: uuid, PreviousTurnID: currentTurnID, Type: "regular"}`. Apply it locally (commits the staged suffix, sets `currentTurnInputs`), then persist it with `AppendTurn`.
4. Clear `callModel`. Spawn the LLM call with `llm.RequestOptions{CacheKey: sessionID}` on a cancellable child context. The result is sent back tagged with `turn.ID`.

Results for any turn other than the current one are dropped. A superseded turn keeps its `turn` item in history with no `model_response`.

**When a turn starts** (exhaustive):

| Trigger | Interrupts an in-flight request? |
| --- | --- |
| A new **external** input arrives (sets `callModel`) | **Yes**: cancel and restart with the new input appended (steering) |
| The latest model response produced a status that is an **error** or has **empty `WaitingFor`** (validation error, unavailable tool) | n/a, decided right after the response |
| `pendingInputs > 0` (finished tool results, heartbeat, external input delivered late) **and** no request in flight **and** the grace set is empty | No |
| Start of `Run` with pending inputs, or recovered statuses needing a response | n/a |

Heartbeats, tool completions, settings, and stop controls **never** interrupt an in-flight request. They wait for its response, and then a new turn starts if anything is pending.

**On a model response** (`processModelResponse`):

1. Clear `cancelModel`. If the result is an error: return `ctx.Err()` if the context is done, else **fatal** `call model for turn "<id>": <err>`. The adapter has already retried (§10.4).
2. Persist the `model_response`, then apply it locally (context, delivered accounting, tool calls).
3. Unless it was a compaction turn: `scheduleToolCalls()` (§6.6). Set `callModel` = any new status that is an error or has an empty `WaitingFor`.
4. Dispatch the new non-terminal ops to the manager. A dispatch error is fatal.
5. If `!callModel` and some calls were scheduled: put **all** of them in `graceToolCalls` and (re)arm `grace = 1s`, which discards any previous deadline.

A response with `Failure` set (provider `response.failed` after retries ran out) is persisted like any other response. It has no tool calls, so the session goes idle, and with `when_idle` the run ends with exit 0.

### 6.6 Tool calls → translators → operations (`scheduleToolCalls`)

For each tracked call with `status == nil`. **Iteration order is Go map order, i.e. random.**

1. Look up the translator: `Registry.Resolve(call.Name)`. Only enabled static tools resolve (§8.1).
   - Found → `status = translator.Translate(ctx, call)`. The `ctx.Submit(spec)` calls allocate `op.ID = uuid` and record `Operation{MaxOutputLength, ID, Type, Version, Status:"ready", State, Idempotency}`.
   - Not found → `status = ErrorStatus("tool \"<name>\" is not available", default limit)`.
2. Build `ToolCallStatus{TurnID, CallID, Status, Operations: submitted ops}`. Apply it locally, which adds a placeholder or error result (§6.3), then persist it. If persisting fails, the ops are never dispatched. If result translation fails, the status is never persisted and `Run` fails.

**Completion** (`reconcileToolCalls`, run after every batch of events): for each tracked call whose waited ops are all terminal in `operations`, with **random iteration order**:

- If `status == nil` → fatal `reconcile untranslated tool call "<call>" in turn "<turn>"`.
- Otherwise build a new `ToolCallStatus{same TurnID, CallID, Status, Operations: current snapshots in WaitingFor order}`, apply it (the real result replaces the staged placeholder, the call finishes, `availableInputs++`), and persist it.
- A duplicate terminal update for an already-finished call does nothing.

**How completions reach the model:** manager update → `SaveOperation` → reconcile → terminal `tool_call_status` item → `TranslateResult` → `function_call_output` appended to the staged suffix → `availableInputs++` → a turn starts by the trigger rules above.

### 6.7 Slurp (batching)

After every loop event, `processEvents`:

1. Slurps the inbox: collect up to 100 inputs. Each wait has a 1 ms idle timer that resets on every item. Stop when 1 ms passes with nothing, the channel closes, or 100 items are collected. Apply each input (`handleInboxInput`).
2. Slurps operation updates the same way. Each update is applied, then persisted with `SaveOperation`.
3. Reconciles.

The point is to put inputs and completions that arrive together into one request. Leftovers beyond 100 are handled on later iterations. Cancellation during a slurp returns `slurp inbox: <cause>` (or `slurp operation updates: …`).

`handleInboxInput(input)`: apply locally, persist, then:

- `settings` → return without touching grace.
- `hard` / `when_idle` → `acceptStop` (ignored once a hard stop is set).
- Every non-settings input (external, heartbeat, stop, crash) then **clears tool grace**.
- External inputs also set `callModel = true`.

> OTP note: replace channel slurping with a mailbox drain: after handling a message, `receive` matching inbox and op-update messages with `after 1` until idle or 100 of each. Keep the "inbox first, then updates, then reconcile, then decide" order. Use one message type per source so the two caps stay independent.

### 6.8 Grace period ("async-first" semantics)

- Every tool call is asynchronous. A model turn never blocks on a tool.
- When a response's calls are all valid, the coordinator **waits up to 1 s** for *those* calls (the grace set) before it starts another turn:
  - If every call in the grace set finishes before the deadline, the next turn starts **immediately** when the last one finishes, with all real results and no placeholders.
  - At the deadline, if something is pending (any finished result or input), a turn starts. Calls still running appear with the **placeholder** result.
  - At the deadline, if **nothing** finished, **no turn starts**. The model "sleeps" until the first completion, which then triggers a turn right away (the grace is gone).
  - The deadline does not reset on partial completions. A newer response's grace replaces the old one, which only tracked the older calls.
  - Any non-settings inbox input ends grace immediately. Settings do not.
  - Older calls finishing during a newer grace do not end it. Only calls in the newest grace set count.
- **What the model sees while a call runs:** exactly one `function_call_output` for that `call_id` with the single text part

  > `Tool call is still running. Its result arrives in a later turn: continue with independent work, or end your turn to wait for it.`

  It sees this only if a turn begins while the call is still running. There is **no partial output, no handle or op ID, no poll/wait/cancel tool**. The per-tool "still running" strings that translators produce (`Command is still running.`, `Image is still loading.`, `Skill is loading.`) are **always replaced** by this placeholder in context.
- **When it finishes:** a new `function_call_output` with the same `call_id` is appended later in the conversation. If the placeholder was still only *staged* (no turn had been sent), it is deleted and replaced in place. If a turn had already sent the placeholder, the history keeps **both**: the placeholder after the original call, and the real result later, after the intervening assistant output. Providers accept this. The port must reproduce it.

### 6.9 Heartbeat

- Armed when `isWaitingForOnlyToolCalls`: no request in flight, the stop mode is not hard, `pendingInputs == 0`, and `toolCalls` is non-empty.
- The timer starts when that state is entered and is **not** reset by non-terminal operation updates. It is disarmed as soon as the state is left (a turn starts, an input is pending, and so on), and re-armed fresh when the state is entered again. The timer ignores grace.
- When it fires: submit (through the inbox, so it is deduped, persisted, and ordered like any input) a control input with a new UUID ID:

  ```
  {"Mode":"heartbeat","Reason":"Heartbeat: waited <%g seconds> seconds for tool calls.\nRunning: <JSON array of ToolCall sorted by CallID>"}
  ```

  For example, with the default 10 min: `Heartbeat: waited 600 seconds for tool calls.\nRunning: [{"CallID":"call-0","Name":"Bash","Arguments":"{\"command\":\"sleep 900\"}"}]`. `%g` of `0.01` is `0.01`.
- The heartbeat becomes a **user message** with the Reason text and counts as a pending input, so it starts a turn.
- A submission failure or persistence failure is fatal. A heartbeat in history that was never delivered (no response after it) starts a turn on resume. A delivered one does not.

### 6.10 Restore (crash recovery, `restore` + start of `Run`)

1. `loadHistory`: page `Items(after, 256)` and `restoreItem` each one.
   - For a `tool_call_status` that "requires a translator" (no error, **or** non-empty `WaitingFor`, **or** has operations) whose call is tracked and whose tool no longer resolves → **fatal** `tool "<name>" required by recorded call "<call>" is not available`. History is left untouched.
   - Then `addItemToLocalState`. Stop controls are **not** re-applied on resume: `acceptStop` only runs for live inbox inputs. Settings **are** replayed, so the latest recorded effort overrides the runner's configured effort. Pagination that fails to advance → error.
2. Overlay `ResumeState.Operations` (latest saved states) into `operations`.
3. In `Run`: `scheduleToolCalls` translates calls that were recorded without a status. Example: a crash between `model_response` and `tool_call_status`. The translator runs **again** and produces **new op IDs**.
4. `reconcileToolCalls` records terminal statuses for calls whose ops completed but whose completion was never recorded.
5. Dispatch **every non-terminal op** to the manager as last checkpointed. Each actor resumes from its checkpoint (§9). A shell that was mid-process is failed rather than restarted.
6. If anything is pending, or a recovered status needs a response, start a turn **before** reading the inbox. The recovery turn therefore uses replayed settings, not settings submitted by this run.

What delivered/pending means after replay (tested): a `turn` without a `model_response` does not mark inputs delivered, so they are delivered again. A response for turn T marks delivered only the inputs that were available when T's `turn` item was applied. Inputs and completions that arrived while T was in flight stay pending.

### 6.11 Unavailable tools

| Situation | Behavior |
| --- | --- |
| The model calls a tool that is unknown or disabled (for example `disallowed_tools`) | Status `{Error: "tool \"X\" is not available"}`, no ops. Result text = the error verbatim. An immediate corrective turn follows (no grace). Valid sibling calls are still scheduled and dispatched. |
| A static tool is enabled but its translator was not configured | `unavailableTranslator`: `Error: "static tool \"X\" is not configured"`. The result is the same string. |
| On resume, a recorded error-only status refers to a now-unknown tool | Replays fine (error text result) |
| On resume, an untranslated call refers to a now-unknown tool | Gets the "not available" status (corrective turn) |
| On resume, a recorded call with ops or a success status refers to a now-unknown tool | `Run` fails. Nothing is persisted. |

### 6.12 Stop and cancel

- **`hard`**: on the first loop pass after it is accepted:
  - Cancel the in-flight request. Its response, even if it returns later, is **not** persisted and its tool calls are not translated.
  - Call `Operations.Cancel(id, Reason)` for every non-terminal op. Errors are joined and returned.
  - Set `cancellationRequested`. After that, no turn starts for any reason.
  - Inputs that arrive later are still persisted and staged.
  - Terminal updates are still persisted and recorded as `tool_call_status`.
  - `Run` returns `nil` once no op is non-terminal. Return value is `ctx.Err()`, which is nil unless the context was canceled.
  - Once hard, later `when_idle`/`hard` controls change nothing and don't re-cancel.
- **`when_idle`**: nothing is canceled. Turns keep running as needed. When `isIdle()` holds (no request, no pending inputs, no tool calls, no non-terminal ops), `Run` returns nil.
- **Context cancellation** (SIGINT in the runner): `Run` returns `ctx.Err()` at once. Context cancellation takes precedence over a model error. The manager cancels ops on its own context (§9.2).
- The stop `Reason` is passed to `Cancel`, but local operations ignore it. The shell terminal error is always `shell operation canceled`.

### 6.13 Settings changes mid-session

A `settings` control:

- is persisted;
- sets `request.Model.ReasoningEffort` in the builder **immediately**, so it applies to the next `Build`;
- does not wake the model, does not interrupt an in-flight request (that request keeps its effort), and does not clear grace or change a pending stop.

Duplicates by ID are dropped by the inbox, and the latest one wins. `Model.ID` is not a setting; it comes from the runner config on every run.

### 6.14 Compaction (dormant)

`Turn.Type == "compaction"` is honored on replay and live: its model response is persisted but not added to context, does not schedule tool calls, and does not mark inputs delivered. Nothing creates compaction turns. Cancelling one leaves `currentTurnType` as compaction until the next turn.

### 6.15 Fatal errors (Run returns an error and the runner exits 1)

- Any store failure (input, turn, response, status, operation).
- Request build failure.
- LLM error after retries, unless the context was canceled.
- Translator result error.
- Operation dispatch error, including `ErrUnsupported` type/version on resume.
- Cancel error during a hard stop.
- Heartbeat submit failure.
- Inbox or updates channel closed.
- Reconciling an untranslated call.
- Restore with an unavailable tool.
- Non-string external payload.

All of these are resumable: the session file is consistent, and the next run replays it.

> OTP note: a `gen_statem` per session fits well: states Idle / ModelInFlight / Grace / WaitingForTools / Stopping, plus derived counters. Use `Process.send_after` timers carrying a unique ref so a stale grace or heartbeat timeout can be ignored ("discard previous deadline"). Run the LLM call in a `Task.Supervisor.async_nolink` tagged with the turn ID, and cancel it with `Task.shutdown(task, :brutal_kill)` so the HTTP stream is closed. Make scheduling and reconcile **deterministic** (response output order, then `WaitingFor` order). The Go order is random, and nothing depends on it.

---

## 7. Context builder

### 7.1 Structure

- `committedPrefix[0]` = the system message (`Role: system`).
- `committedPrefix[1..]` = committed history.
- `stagedSuffix` = items added since the last turn started.
- `Build()` returns `committedPrefix ++ stagedSuffix`, the model (`ID`, `MaxOutputTokens`, `ReasoningEffort`), and a copy of the tools. Returned slices are copies.

| Method | Effect |
| --- | --- |
| `AddExternalInput(input)` | Payload must decode to a JSON **string**. Stages `{message, user, text}`. |
| `AddControlMessage(msg)` | `settings` → `request.Model.ReasoningEffort = Parameters.ReasoningEffort` (immediate). `heartbeat` → stages `{message, user, Reason}`. Others: no-op. |
| `AddModelResponse(resp)` | Appends `resp.Output` items **directly to the committed prefix**, ahead of anything staged, so inputs that arrived during the request come after the response. |
| `AddToolResult(callID, output, running)` | If `running`, output = `[text: ToolCallRunningPayload]`. Removes any **staged** placeholder for that call ID (only exact placeholder outputs, only from the staged suffix), then stages `{tool_result, CallID, output}`. |
| `AddReasoning(r)` | Stages a reasoning item. The coordinator never calls it. |
| `Commit()` | `committed += staged; staged = []`. Called when a `turn` item is applied. |
| `SetSystemPrompt(p)` | Replaces item 0 text with `TrimSpace(preamble + "\n\n" + p)`. Does not touch the conversation. |
| `SetModel(m)`, `AddTool(t)` | Request model and tools. |

`NewBuilder(skills...)`: `preamble = TrimSpace(preamble.md)`. If there are skills, `preamble += "\n\n" + skillPrompt`. The runner then calls `SetSystemPrompt(system_prompt or defaultSystemPrompt)`.

### 7.2 Preamble (`harness/contextbuilder/prompts/preamble.md`, verbatim)

```text
You run on Unreal Agent Harness built by Unreal Labs.

You work in turns. A turn is one reading of the conversation and one reply: text, tool calls, or both. Each turn re-sends the whole conversation, so prefer to go wider with tool calls — they are cheap — rather than chaining them across a longer sequence of turns. When the next commands do not depend on each other's output (inspecting several files, running the build and the tests, probing two hypotheses), issue them as separate tool calls in the same turn instead of one at a time.

Tool calls are asynchronous: each starts the moment you issue it and runs in the background, so issuing one never blocks you and many run at once. As each finishes, its result is appended and wakes a new turn; results that land together arrive in the same turn, and a call still running shows a placeholder until its own result comes.

You never have to babysit a running call: harness does it for you. As a backup, if calls are active and nothing has happened for ten minutes, a heartbeat wakes you, and this is an opportunity to check that all is well.

Ending a turn with no tool calls while calls are running means you sleep until one finishes; ending a turn with nothing running ends the session, so do that only when the task is complete.

Treat the prompt as a goal and keep working until it is met. I believe in you!
```

(The dashes are U+2014 em dashes. Each paragraph is a single line in the file.)

### 7.3 Skill preamble (`prompts/skill-preamble.md`, verbatim)

```text
The following skills provide specialized instructions for specific tasks.
Use SkillUse to load a skill's file when the task matches its description.
When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool calls.
```

Skill prompt = `skillPreamble + "\n\n" + xml`. The XML comes from Go `encoding/xml` (no indentation, no declaration), in registration order:

```xml
<available_skills><skill><name>go-review</name><description>Review &lt;Go&gt; &amp; &#34;tests&#34;</description><location>/skills/reviewer&#39;s/SKILL.md</location></skill><skill>…</skill></available_skills>
```

Go escapes `"`→`&#34;`, `'`→`&#39;`, `&`→`&amp;`, `<`→`&lt;`, `>`→`&gt;`, `\t`→`&#x9;`, `\n`→`&#xA;`, `\r`→`&#xD;`.

### 7.4 Default system prompt (runner, `run.go`, verbatim; used when the request has no `system_prompt`)

```text
You are an AI agent running inside an isolated sandbox container.

## Guidelines
- Save output files to the workspace root.
- For large datasets, inspect a sample first before processing everything.
```

The final system message is `TrimSpace(preamble [+ "\n\n" + skillPrompt] + "\n\n" + systemPrompt)`. An empty `system_prompt` yields just the preamble.

### 7.5 Truncation and compaction

**None.** Every request contains the complete history: system message, all user messages, all assistant output items including reasoning with encrypted content, every tool call, every placeholder, and every result. The only size limits are per-tool-result caps (§8.5). If the context gets too long, the provider error `context_length_exceeded` is non-retryable (§10.4), so the run fails. `Build` always returns an empty `Report`.

### 7.6 Ordering example

Turn 1 sends `[sys, user"run both", call A, call B, result A=placeholder, result B="done B"]`. While it is in flight, A finishes and the user types "continue". The response is `[reasoning R, msg M, call C]`.

The next request is:

```
[sys, user, A, B, A=placeholder, B="done B", R, M, C, A="done A", user"continue", C=placeholder]
```

The response is inserted before the late inputs, and A's placeholder stays where it was.

---

## 8. Tools

### 8.1 Registry and selection

- Static names: `Bash`, `ViewImage`, `SkillUse`.
- `NewRegistry(StaticTranslators{Bash, ViewImage}, enabled...)`. A nil translator becomes `unavailableTranslator`. `SkillUse` always uses the internal skill translator.
- `Resolve(name)` succeeds only for a static name that is **enabled**. Unknown names never resolve. `StaticDefinitions()` returns the enabled definitions in the order Bash, ViewImage, SkillUse. The runner adds these to the request.
- What the runner enables: `[Bash, ViewImage]`, plus `SkillUse` **only if** at least one skill was discovered, minus the request's `disallowed_tools`. Skills are registered only if `SkillUse` resolves.
- **Skills**: discovered from `<workspace>/.harness/skills/*/SKILL.md` (glob order). Frontmatter: the first line must be `---`. Then lines of the form `key: value`, where only exact keys `name` and `description` count and values are trimmed. A closing `---` is required. Both values and the path must be non-empty. A duplicate name → error. Errors are printed to stderr as `skill error> <err>` and do not stop the run. `RegisterSkill` rejects a duplicate path or name.

### 8.2 Definitions (verbatim; `Type: "function"`)

**Bash**: description:
`Execute a shell command in background. Independent commands may be issued as parallel tool calls in one turn. Command child processes are killed when the shell exits.`

```json
{
  "type": "object",
  "properties": {
    "command": {"type": "string", "description": "The shell command to execute."},
    "max_output_length": {
      "type": "integer",
      "description": "Maximum characters per output text field. Truncated text keeps its head and tail, around a marker stating how much was omitted, and path to the file with the complete stream. Defaults to 40000.",
      "minimum": 1,
      "maximum": 1000000,
      "default": 40000
    }
  },
  "required": ["command"]
}
```

**ViewImage**: description: `View a local JPEG, PNG, BMP, TIFF, or WebP image.`

```json
{"type":"object","properties":{"path":{"type":"string","description":"Image file path, absolute or relative to the workspace."}},"required":["path"]}
```

**SkillUse**: description: `Load the instructions for a registered skill.`

```json
{"type":"object","properties":{"name":{"type":"string","description":"The exact name of the skill to load."}},"required":["name"]}
```

On the wire, `parameters` keys are sorted (§10.1) and `"strict": false`.

### 8.3 Translator validation (`Translate`) and the status it produces

`tool.ErrorStatus(msg, limit)` bounds `msg` to `limit` characters (default 40 000) with head/tail truncation (§8.5) and sets `ErrorTruncated`.

**Bash** (`tool/bash`):

1. `Arguments` is unmarshaled into `map[string]jsontext.Value`. Failure → `decode Bash arguments: <json error>`. Keys are case-sensitive, and duplicate keys are rejected.
2. `max_output_length`: absent → 40 000. It must decode as an int: `bash argument: decode max_output_length: <err>`. It must be `>0`: `bash argument: max_output_length must be a positive integer`. It must be `≤1 000 000`: `bash argument: max_output_length must not exceed 1000000`. Errors at this step use the default limit (40 000) to bound the error text. Errors in later steps are bounded by the limit the model asked for.
3. `command` is required: `bash argument "command" must be set`. A JSON `null` → `bash argument "command" must be a string`. A non-string → `decode Bash argument "command": <err>`. A NUL byte → `bash argument "command" contains a NUL byte at offset <byte offset>`.
4. Build the spec: `NewShellSpec({Command, Shell: $SHELL or /bin/sh, Directory: workspace}, BaseDirectory: <sessions>/operations/<sessionID>, limit)`. Errors become `build Bash operation: <err>`:
   - `shell path must be absolute`
   - `base directory must be absolute`
   - `max output length is out of range`
5. Success → `{WaitingFor: [opID]}` with one `shell` op whose `MaxOutputLength = limit`.

**ViewImage** (`tool/viewimage`):

1. Unmarshal into `{path string}`. Failure → `decode ViewImage arguments: <err>`, bounded to 40 000. Unknown keys are ignored.
2. Empty after trim → `ViewImage argument "path" must be set`. NUL → `ViewImage argument "path" contains a NUL byte at offset N`.
3. A relative path becomes `workspace + "/" + path`, **without cleaning**, so `..` resolves through symlinks.
4. `NewViewImageSpec(path, {MaxSize: 4_999_000, MaxWidth: 2000, MaxHeight: 2000})`. Error → `build ViewImage operation: <err>`.

**SkillUse** (`tool/skill_use.go`):

1. If `call.Name` is non-empty and not `SkillUse` → `skill-use call name "X" does not match static tool "SkillUse"`.
2. Blank arguments are treated as `{}`. Unmarshal into `{name}`. Failure → `decode skill-use arguments: <err>`.
3. Blank name → `skill-use argument "name" must be set`.
4. Unknown name (exact match) → `skill "X" is not registered`.
5. `NewSkillUseSpec(skill.Path)` → `{WaitingFor:[opID]}`.

SkillUse and ViewImage path errors are **not** passed through `ErrorStatus`, so they are not bounded.

### 8.4 Result formatting (`TranslateResult`) — what the model sees once a call is terminal

**Bash** (single text part):

- Validation error → `"Error: " + status.Error`.
- Running states (`ready`/`awaiting`/`canceling`) → `"Command is still running."`. This is always replaced by the placeholder in context.
- Terminal: build `parts` and join them with `"\n"`:
  - if `Result` is present: `Result.Out` if non-empty; `"Stderr:\n" + Result.Err` if non-empty; `"Exit code: N"` if `ExitCode != 0`;
  - else (failed or canceled before reading): `"Stdout capture: " + OutPath` if set; `"Stderr capture: " + ErrPath` if set;
  - then `"Error: " + TerminalError` if set. For failed/canceled with an empty error it is `"shell operation failed"` or `"shell operation canceled"`.
  - No parts → `"(no output)"`.
  - Examples: `"out\n\nStderr:\nerr\n"`, `"Stderr:\ncommand failed\n\nExit code: 7"`, `"hi\n\nStderr:\noops\n\nExit code: 3"`, `"Error: shell operation canceled"`.
- A completed operation with no `Result` → translator error (fatal).

**ViewImage**:

- Validation error → `[text "Error: <msg>"]`.
- Running → `[text "Image is still loading."]` (replaced by the placeholder).
- Completed → `[image "data:<EncodedMIMEType>;base64,<Content>"]` plus an optional text part made of details joined with `"; "`:
  - `original MIME type: <orig>` when the original type differs from the encoded type,
  - `original dimensions: WxH` when `ScaleRatio < 1`,
  - `multiply coordinates by %.2f to approximate original` (that is, `1/ScaleRatio`) when `ScaleRatio < 1`.
  - Example: `original MIME type: image/tiff; original dimensions: 120x80; multiply coordinates by 2.00 to approximate original`.
  - A completed operation with empty content or MIME type, a ratio outside (0, 1], or a non-empty error → translator error (fatal).
- Failed/canceled → `[text "Error: <Result.Error or 'view-image operation failed|canceled'>" + ("; original MIME type: X; original dimensions: WxH" when that metadata exists)]`.

**SkillUse**:

- Error → `[text status.Error]`, raw with no prefix.
- Completed → `[text <file content, invalid UTF-8 → U+FFFD>]`.
- Running → `"Skill is loading."` (replaced).
- Failed/canceled → `[text TerminalError]`. An empty error is a translator error.

**Unavailable or unconfigured**: see §6.11.

### 8.5 Output caps and truncation (`operation/output.go`)

- `DefaultMaxOutputLength = 40 000`, `MaxOutputLength = 1 000 000`. Units are **Unicode code points** (Go runes), not bytes and not graphemes.
- `BoundOutput(text, limit)`: if `runeCount(text) ≤ limit`, return the text sanitized (invalid UTF-8 → U+FFFD). Otherwise keep the first `limit/2` runes as the head and the last `limit - limit/2` runes as the tail:

  ```
  head + "...<skipped> bytes truncated" + ["; complete output in <path>"] + "..." + tail
  ```

  `skipped = fullByteSize - headBytes - tailBytes`, counted in **bytes**. The marker does not count toward the limit.
- Example (limit 3, "hello"): `h...2 bytes truncated; complete output in /…/out...lo`.
- Applies to: shell stdout and stderr, each separately with the capture path; shell `TerminalError` (no path); tool error statuses (no path); remote-job result and error (no path, TODO upstream).
- ViewImage limits: base64 content ≤ 4 999 000 bytes; output ≤ 2000×2000 (scaled to fit both bounds); decode budget 32 000 000 source pixels; source read ≤ 256 MiB.
- SkillUse has **no cap**: it reads the whole file.

> OTP note: `String.length/1` counts graphemes. Count code points instead (`:unicode.characters_to_list/1 |> length`, or walk `<<_::utf8>>`) and slice by code point. Use `String.replace_invalid/2` (or `:unicode.characters_to_binary` with a fallback) for the U+FFFD sanitizing.

---

## 9. Operations

### 9.1 Actor contract

Each operation type is a pure state machine: `handle(event | nil) → Step{Operation *checkpoint (nil = unchanged), Dispatches []PrimitiveDispatch}`.

- `nil` event = start, or resume from the persisted checkpoint.
- Primitive events carry `{Type, Source = op ID, CorrelationID, Result}`.
- Every non-nil `Step.Operation` is emitted as an update. The coordinator persists it with `SaveOperation`.
- A terminal status ends the actor.

Primitive event types:

| Family | Events |
| --- | --- |
| process | `process.started{PID}`, `process.output`, `process.stream_failed`, `process.exited{ExitCode, Signal}`, `process.input_written/input_write_failed/input_closed/signaled` |
| file | `io.create_completed{Kind}`, `io.read_output{Offset, Data}`, `io.read_completed{Size}` |
| remote | `remote.response_started{Attempt, StatusCode, Headers}`, `remote.output{Attempt, Offset, Data}`, `remote.stream_failed`, `remote.retry_scheduled`, `remote.completed{Attempt}` |
| other | `timer.fired`, `compute.completed{Value}`, `primitive.failed{Error}`, `primitive.canceled` |

### 9.2 Local operation manager lifecycle

- `Add(op)` is synchronous through the actor goroutine.
  - An ID already accepted in this manager's lifetime → `nil` (no-op).
  - `remote_job` → routed to a handler (§9.6).
  - Otherwise initialize by type: `shell` and `view_image` are stateful actors; `value` and `skill_use` are stateless advance functions. Any other type → `ErrUnsupported`, returned from `Add`, which is fatal in the coordinator.
  - The first `handle(nil)` must succeed, or `Add` returns its error.
  - The returned step is accepted: a checkpoint becomes an update, and dispatches start primitives. If a dispatch fails to start, `handle(primitive.failed{Error})` is called with an **empty correlation ID**.
- `Cancel(id, reason)`: unknown or finished → `nil`. Remote → `handler.CancelRemoteJob(id, reason)`. Local → cancel the operation's context. **The reason is ignored for local ops.**
- **Cancellation rewrite**: when a *completion* primitive event (`io.create_completed`, `io.read_completed`, `process.exited`, `compute.completed`, `primitive.failed`, `primitive.canceled`) arrives for an operation whose context is canceled, it is rewritten to `primitive.canceled` (with nil result) before the actor sees it. A cancel that races a completion therefore always ends `canceled`.
- An actor error (`handle` returns err) → a type-specific `fail(err)` (status `failed` with `TerminalError`). The update is emitted and the actor removed.
- Updates go into an **unbounded** queue (`pendingUpdates`) consumed through `Updates()`.
- Shutdown (manager context done): cancel every op, **wait for every active primitive to report completion** (processes go through SIGTERM/SIGKILL), then close `Updates()`. **Pending updates still queued are dropped.**
- The local manager never emits `canceling`. On resume, an op persisted as `canceling` is driven straight to `canceled`.

> OTP note: one process per operation (gen_statem) under a DynamicSupervisor, with a Registry keyed by op ID. The manager only routes, dedupes, and forwards checkpoints to the coordinator, which should be monitored. Primitives become Tasks or Ports owned by the op process. Model cancel as an explicit message, and keep the "completion after cancel ⇒ canceled" rule. The runner must **wait for op shutdown** before the VM halts (Go's `os.Exit` races this; see §12).

### 9.3 Shell operation (`shell` v3)

**State JSON**, in this order:

```
ShellState {
  Input { Command, Shell, Directory }, BaseDirectory,
  Phase "" | create_directory | create_out | create_err | process | read_out | read_out_tail | read_err | read_err_tail,
  ProcessGroupID int, PendingExitCode *int, OutSize, ErrSize int64,
  InlineOut, InlineErr, InlineOutTail, InlineErrTail []byte (base64),
  Result *{ Out, Err string, OutSize, ErrSize int64, ExitCode int },
  TerminalError string, ErrorTruncated, OutTruncated, ErrTruncated bool,
  OutPath, ErrPath string
}
```

The initial spec has `OutTruncated: true, ErrTruncated: true`; everything else is zero. `Operation.MaxOutputLength` = the Bash limit (always set for shell).

Validation:

- `Shell` must be an absolute path.
- `BaseDirectory` must be absolute.
- `ProcessGroupID` must be 0 or >1. Sizes must be ≥ 0.
- The op ID must be a single path component.
- Inline buffers may not exceed `L*4` bytes each pair.

**Paths**: `dir = BaseDirectory/<opID>`, `out = dir/out`, `err = dir/err`.

**Phases.** `L = MaxOutputLength`, `readLimit = L*4` bytes, `tailLimit = (L - L/2)*4` bytes.

1. `ready` + nil → phase `create_directory`. Dispatch `io.create{Kind: directory, Path: dir, Mode: 0700}`, status `awaiting`, checkpoint.
2. Created → `create_out`: `io.create{regular file, out, 0600}`. Created → set `OutPath`, go to `create_err`. Created → set `ErrPath`, go to `process`.
   - "Create" means create **or use an existing** entry of the right kind (idempotent, fsync'd). It retries up to 16 times on contention.
   - A path that exists with the wrong kind → error.
3. `process`: `process.start{Path: Shell, Arguments: ["-c", Command], Directory: Input.Directory (the workspace), StdoutPath: out, StderrPath: err}`. Nothing else is set: no environment, so the process **inherits the runner's environment, including vars loaded from `.env`**; no stdin, so stdin is `/dev/null`. See §9.7 for how the process is spawned.
   - `process.started{PID}` → `ProcessGroupID = PID`, checkpoint (no dispatch).
   - `process.exited` → `exit = Signal ? 128+Signal : ExitCode`. Set `ProcessGroupID = 0`, `PendingExitCode = exit`, then go to `read_out`.
   - `process.output` or `process.stream_failed` → fail. These are not expected because there are no pipes.
4. `read_out`: `io.read{Path: out, Offset 0, Count: readLimit}`. Chunks are buffered in memory (not checkpointed). On `io.read_completed{Size}`, validate that the offsets and sizes are consistent. If `Size > readLimit`, keep only the first `readLimit - tailLimit` bytes as `InlineOut` and go to `read_out_tail`: read `tailLimit` bytes at `Size - tailLimit`. If the file size changed in between → fail. Then the same for `read_err` / `read_err_tail`.
5. Finish: require `PendingExitCode`.
   - `Result.Out, OutTruncated = boundOutput(InlineOut, InlineOutTail, OutSize, L, outPath)`, and the same for Err.
   - `Result.OutSize/ErrSize/ExitCode`. Set `OutPath/ErrPath`.
   - Clear `PendingExitCode`, the inline buffers, and `Phase`.
   - Status `completed`.
6. Any failure: phase `""`, `TerminalError = msg` (bounded to L, no path), status `failed`. Cancel: `TerminalError = "shell operation canceled"`, status `canceled`.

**There is no timeout.** A command runs until it exits, a hard stop arrives, or the runner exits.

**Recovery** (`awaiting` + nil event):

- Phase `process` with `ProcessGroupID == 0` → fail `shell execution outcome is unknown because process start was not recorded`.
- Phase `process` with a PGID → fail `shell execution was interrupted before an exit status was recorded`. The recorded PGID is kept in state, and **the old process group is not killed**.
- Any other phase is re-dispatched from scratch for that phase, discarding read chunks. Creates are idempotent. Reads are repeated, and the recorded exit code is kept.

Checkpoints per command: about 8 `operation` records (create ×3, start, started, exited→read, read phases, completed).

### 9.4 View image (`view_image` v1)

**State JSON**:

```
ViewImageState {
  Path,
  Config { MaxSize, MaxHeight, MaxWidth, MaxSourcePixels (omitzero) },
  Result *{ Content, OriginalWidth, OriginalHeight, OriginalMIMEType, EncodedMIMEType, ScaleRatio float, Error }
}
```

`MaxOutputLength` is not set.

Flow:

- `ready`/`awaiting` + nil → checkpoint `awaiting` and dispatch `io.read{Path, Count: 256 MiB, Correlation "view-image-read"}`. A resume always re-reads from scratch.
- Read completed → dispatch `compute` (correlation `view-image-process`), which runs `prepareViewImage`:
  1. Decode the header (`image.DecodeConfig`). Failure → `decode image header; original dimensions unavailable: <err>`. Dimensions must be positive.
  2. Format `gif` → `unsupported image format "gif"` (with original MIME set). Accepted: jpeg, png, bmp, tiff, webp. Any other → `unsupported image format "X"`.
  3. `width > MaxSourcePixels(32M)/height` → `refuse to decode WxH <fmt> image: exceeds MaxSourcePixels N`.
  4. Decode the pixels. Compute `ratio = min(1, MaxWidth/w, MaxHeight/h)` and new dimensions `max(1, round(w*ratio))`. If `ratio < 1`, scale bilinearly into NRGBA.
  5. Encode: a JPEG with `ratio==1` is copied **byte for byte**. A JPEG that was resized is re-encoded at quality 90. Everything else is encoded as PNG. `EncodedMIMEType` is `image/jpeg` for jpeg sources and `image/png` otherwise.
  6. Base64 (standard). If it exceeds `MaxSize` → `<mime> image after resizing WxH to wxh (scale %.6g) needs N base64 bytes; MaxSize is M bytes, exceeded by X bytes (%.1f%%)`.
  - A read failure after some bytes arrived still runs header inspection, so the metadata survives. The error is `read image: <err>`. A source over 256 MiB → `image source is N bytes; source limit is 268435456 bytes (exceeded by X bytes)`.
- Compute result: `Error` set → `failed` (content cleared). Otherwise `completed`. A dispatch rejection or compute failure → `image primitive failed: <err>`. Cancel → `Result{ScaleRatio:1, Error:"view-image operation canceled: context canceled"}`, status `canceled`.

### 9.5 Skill use (`skill_use` v1)

**State**: `{Path, Content []byte (base64 in JSON), TerminalError}`.

- `ready`/`awaiting` + nil → `awaiting` and `io.read{Path, Offset: len(Content), Count: MaxInt64, Correlation "skill-use-read"}`.
- **Each output chunk is appended to `Content` and checkpointed**, so a resume continues from the offset.
- `io.read_completed{Size == len(Content)}` → `completed`.
- Failure: `TerminalError = <error>`, status `failed`. Cancel: `"skill-use operation canceled"`.

### 9.6 Remote jobs and the proxy idea

`remote_job` v2 is an operation whose execution is handed to a **`RemoteJobHandler`** chosen by `(Plan.Type, Plan.Version)`:

```
RemoteJobState { Plan {Type, Version uint32, Data json},
                 Handle json (omitzero), NextInspectionAt time (omitzero), OutstandingInput json (omitzero),
                 Subscription json (omitzero), TerminalResult string (omitzero), TerminalError string (omitzero),
                 ResultBytes int (omitzero), ResultTruncated bool (omitzero), ErrorBytes int (omitzero), ErrorTruncated bool (omitzero) }
NewRemoteJobSpec(plan) → MaxOutputLength 40 000, Type remote_job, Version 2
RemoteJobHandler { RemoteJobPlanType(), RemoteJobPlanVersion(), AddRemoteJob(Operation) error,
                   CancelRemoteJob(ID, reason) error, RemoteJobUpdates() <-chan Operation }
```

- **Routing**: exactly one handler must match the plan. Zero matches → `ErrUnsupported`. More than one → error. A handler that already stopped → error.
- **Updates from a handler** are validated against the current op before they are forwarded:
  - the same `MaxOutputLength`, Type, and Version;
  - the same Plan (type, version, **byte-equal data**);
  - a valid transition: from `ready`/`awaiting` to any of `awaiting|canceling|completed|failed|canceled`; from `canceling` only to `canceling|failed|canceled`; nothing out of a terminal state.
  - On violation, the op is canceled on its handler and failed locally.
- An update from the wrong handler fails the op.
- A handler whose update channel closes → all its jobs fail with `remote job handler <i> stopped`.
- `UpdateRemoteJob` bounds `TerminalResult` and `TerminalError` to `MaxOutputLength` (head/tail, no path) and records the original byte counts.
- No translator in this repo creates remote jobs. The runner's `ToolFactory` can supply handlers (`Tools.RemoteJobs`), and the open-source runner supplies none.

**Proxy concept** (README): because an `Operation` is a self-contained, versioned, serializable value (`ID/Type/Version/Status/State/Idempotency/MaxOutputLength`) and `Manager` is only `Add / Cancel / Updates`, a *proxy manager* can serialize operations to a local manager running inside a remote sandbox and stream its checkpoints back. Tools then run remotely while the coordinator, store, and model stay local. `Idempotency` is reserved for deduping across that boundary.

> OTP note: this maps onto distribution. The operation manager (and the op processes) can live on the Photon node or a sandbox node, while the coordinator calls `GenServer.call({OpManager, node}, {:add, op})` and receives `{:op_update, op}` messages. Keep the "Add is idempotent per ID", "updates are full snapshots", and "coordinator persists before acting" rules. Then a network partition only delays updates and never corrupts history.

### 9.7 Process primitive (what a port must reproduce for Bash)

- `exec.Command(Path, args...)`: `argv[0] = Path` (the shell path), then `-c`, then the command.
- `Dir = Directory`.
- `Env = nil`: inherits the runner process environment at spawn time.
- `SysProcAttr.Setpgid = true`: a **new process group**, `pgid == pid`.
- stdout and stderr go **directly to the capture files**: opened `O_WRONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC`, required to be regular files and distinct, set back to blocking, truncated to 0 before start.
- stdin is the null device.
- When the shell exits (or on cancel): **SIGTERM the whole group** (`kill(-pgid)`), poll for the group to disappear (1 ms backoff doubling to 50 ms) for up to **5 s**, then **SIGKILL the group**. ESRCH is fine. On Linux, EPERM is forgiven only after a confirmed exit. This happens on **normal exit too**, so background children (`cmd &`) are killed once the shell returns. Processes that left the group (`setsid`, `nohup` plus a new session) survive.
- Captures are fsync'd and closed. The exit result is `{ExitCode, Signal}`, and the shell maps a signal to `128+signal`. Spawn errors → `primitive.failed` (`start process "<path>": <err>`).

> OTP note: BEAM ports can't set a pgid, redirect fds to files, or signal a group. Use **erlexec** (`:stdout => {:append, path}`, `:group`, `:kill_group`, `:kill_timeout`) or **MuonTrap**. The alternative is a tiny C/Rust/`setsid`+`sh -c 'exec >out 2>err </dev/null; …'` launcher, but wrapping the command changes `$0` and quoting, so prefer erlexec. Reproduce the "kill the group after a normal exit too" behavior, because the tool description promises it. Erlang's `:os.getpid` is not the child PID; record the real child PID as `ProcessGroupID`.

### 9.8 Other primitives (summary)

| Primitive | Behavior |
| --- | --- |
| `io.read` | Opened `O_RDONLY|O_NONBLOCK`, must be a regular file. Reads `min(Count, size-Offset)` bytes from the size seen at open, in 32 KiB chunks via `ReadAt`. Fails if the size changed by the end. Cancellation is checked between chunks. |
| `io.create` | Create-or-use as described in §9.3. Fsyncs the file and the parent directory. |
| `compute` | Runs a callback in its own goroutine. Panics and early exits become failures. Cancellation → `canceled`. |
| `timer.schedule` | Wall-clock deadline, rechecked at least every 5 s. |
| `remote.request` | HTTP client (§10.3). |

---

## 10. LLM adapter (`responsesapi`)

### 10.1 Request body (`POST <base>/responses`, JSON, byte-stable)

```json
{
  "include": ["reasoning.encrypted_content"],
  "input": [ … ],
  "max_output_tokens": 1234,                       // only if Model.MaxOutputTokens set (runner never sets it)
  "model": "<Model.ID>",
  "prompt_cache_key": "<sha256hex(sessionID)>",    // only if the client uses the body field
  "reasoning": {"effort": "<effort>", "summary": "auto"},   // only if ReasoningEffort != ""
  "store": false,
  "stream": true,
  "tools": [ … ]                                   // omitted if empty
}
```

Keys come out in lexicographic order (generated struct order, with `Deterministic` sorting maps). There is no `instructions`, `tool_choice`, `parallel_tool_calls`, `temperature`, or `previous_response_id`; the system prompt is the first `input` item. Provider **extensions** are merged as extra top-level keys, after which the whole body is re-encoded with sorted keys. An extension that names an existing field → error `request extension "X" overrides a Responses API field`.

**Input item mapping:**

| llm.Item | Wire item |
| --- | --- |
| message **without** ProviderID (system, user; also assistant if it has no ID) | `{"content": "<text>", ["phase": …], "role": "<role>"}` (EasyInputMessage, no `type`) |
| message **with** ProviderID (assistant output) | `{"content":[{"annotations":[],"logprobs":[],"text":"…","type":"output_text"}] (empty array if text ""), "id": "<ProviderID>", ["phase": …], "role":"assistant", "status":"completed", "type":"message"}` |
| tool_call | `{"arguments": "<raw or wrapped>", "call_id": …, ["id": ProviderID], "name": …, "type":"function_call"}`. Arguments that are not a valid JSON **object** are replaced with `{"invalid_arguments":"<raw>"}` so providers accept their own malformed calls when replayed. |
| tool_result | `{"call_id": …, "output": [ {"text": …, "type":"input_text"} \| {"image_url": "<url or data URL>", "type":"input_image"} … ], "type":"function_call_output"}`. The output is **always an array** (`[]` if empty). |
| reasoning | `Raw` emitted **verbatim**, including `encrypted_content`. Empty `Raw` → error. |

**Tools:**

- `function` → `{"description": …(omitted if ""), "name": …, "parameters": {…}, "strict": false, "type": "function"}`. `strict: false` is deliberate, because the harness validates arguments itself.
- `hosted` named `web_search` → `{"type":"web_search"}`. Any other hosted name → error.

### 10.2 Streaming

Headers: the configured headers, with `Accept: text/event-stream` forced and the cache-key header if configured. SSE frames are split on blank lines. The `data:` lines are concatenated with `\n` and a leading space is stripped. Empty payloads and `[DONE]` are ignored.

Consumed events (everything else, including all `*.delta` events, is ignored):

| Event `type` | Action |
| --- | --- |
| `response.completed`, `response.failed`, `response.incomplete` | Terminal: capture `response`. `failed` also records an APIError taken from `response.error`. |
| `response.output_item.done` | Store `item` by `output_index`. Used only if the terminal response's `output` is empty or missing (ChatGPT/Codex endpoint), sorted by index, gaps allowed. |
| `error` | In-band error: code, message, and param from the top level, falling back to a nested `error{…}`. `type` defaults to `"error"`. Becomes `APIError{StatusCode:200, …}`. |

A non-2xx response is not parsed as SSE. Its body is collected (at most **1 MiB**, else `responses API error response exceeds 1 MiB`) and parsed as `{"error":{code,message,param,type}}`. If that fails, the trimmed body or the status text is the message.

**Response decoding:**

- `status`: `completed` → `Stop "complete"`. `incomplete` → `max_output_tokens` → `"max_output_tokens"`, `content_filter` → `"refused"`, any other reason → error. `failed` → `Failure{Code, Message}`, or `{"", "response failed"}` if there is no `error`. Any other status → error.
- **Output:**
  - `message` → `{ProviderID: id, message, assistant, Text: concat(output_text.text | refusal.refusal), Phase}`. Another content type → error.
  - `function_call` → `{ProviderID: id, tool_call, CallID, Name, Arguments}`. Calls with status `in_progress`/`incomplete` are **dropped**.
  - `reasoning` → `{ProviderID: id, reasoning, Summary: [summary[].text], Raw: <item JSON>}`.
  - `web_search_call` is dropped.
  - **Any other output type → error**, which is fatal for the run.
- **Usage**: `input_tokens`, `input_tokens_details.cached_tokens`, `input_tokens_details.cache_write_tokens`, `output_tokens`, `output_tokens_details.reasoning_tokens`. `Raw` = the provider's `usage` object verbatim.

### 10.3 Transport

- HTTP client: dial timeout 30 s, keep-alive 30 s, TLS handshake 10 s, idle connections 90 s, HTTP/2 attempted, `HTTP(S)_PROXY` from the environment.
- **Idle timeout 30 min.** The timer starts with the attempt (covering connect and headers), pauses while an event is handed off, and re-arms between body reads. It exists because reasoning can go quiet for minutes. A timeout is retryable.
- SSE frames are at most 256 MiB.
- The primitive's own retries are disabled (`MaxAttempts = 1`). Retrying happens at the adapter level.

### 10.4 Retry policy (`exchange`)

- `maxAttempts`: default **5** (`DefaultRemoteMaxAttempts`). The runner can override it (§11.2). Attempts are counted across every failure kind.

| Outcome | Retry? |
| --- | --- |
| Transport failure (`primitive.failed`: connection refused or reset, timeouts, EOF, …) | **Yes** |
| Canceled | No |
| Stream ended with no terminal event (`ErrUnexpectedEOF`) | **Yes** |
| Malformed event JSON | No (error) |
| Terminal `response.failed` | Per the classifier, using the response error. If attempts run out, it is returned as a normal `Response` with `Failure`, **not an error**. |
| `response.incomplete` | Never retried. Returned with a `Stop` reason. |
| In-band `error` event | Per the classifier. If attempts run out → error. |
| Non-2xx | Per the classifier. If attempts run out → error `create response: <APIError>`. |

**Classifier** (`retryableResponseError`), which errs toward retrying:

- Never retry these codes: `context_length_exceeded`, `insufficient_quota`, `usage_not_included`, `usage_limit_reached`, `credit_balance_exhausted`, `billing_hard_limit_reached`, `cyber_policy`, `misalignment_policy_violation`, `invalid_prompt`, `bio_policy`, `invalid_api_key`, `invalid_token`.
- Never retry these types: `authentication_error`, `permission_error`, `insufficient_quota`.
- A non-2xx status is retried only if it is in `{408, 425, 429, 500, 502, 503, 504, 520, 521, 522, 523, 524, 529}`.
- A 2xx (in-band) error is **always** retried unless the code or type above rules it out.

**Delay before retrying attempt `n`** (`responseRetryDelay`):

1. Hint = `Retry-After` header (integer seconds or HTTP date; negative or overflowing → 0). If the code is `rate_limit_exceeded`, take `max(hint, message hint)` where the message hint matches `/(?i)\btry again in\s*(\d+(?:\.\d+)?)\s*(ms|milliseconds?|s|seconds?)\b/`. A hint > 0 → use `min(hint, 30 s)` with **no jitter**.
2. Otherwise backoff = `2 s · 2^(n-1)` capped at 30 s. For codes `server_is_overloaded` and `slow_down`, use base 10 s capped at 60 s.
3. Jitter: `delay − (delay/5)·rand[0,1)`, so the result lies in `(0.8·delay, delay]`.

The wait is a timer primitive and can be canceled. Each attempt rebuilds the request with a **new UUID correlation ID** and the **same body**.

**Error strings**: `APIError.Error()` = `responses API error <code>: <message>`, or `responses API request failed with status <n>: <message>`, or `responses API request failed: <message>`.

### 10.5 Cache key

`key = lowercase hex SHA-256(sessionID)`. Where it goes depends on the client (below). Same session → same key, so every turn hits the same warm cache or upstream.

### 10.6 Provider clients

| Provider (`UNREAL_HARNESS_LLM_PROVIDER`) | Default base URL | Default model | Auth | Cache key placement | Differences |
| --- | --- | --- | --- | --- | --- |
| `openai` (default) | `https://api.openai.com/v1` | `gpt-6-astra` | `Authorization: Bearer <key>`; key env `OPENAI_API_KEY` | body `prompt_cache_key` | none |
| `fireworks` | `https://api.fireworks.ai/inference/v1` | none (must set) | Bearer; `FIREWORKS_API_KEY` | header `x-session-affinity` (no body field) | After decoding, **usage is overwritten** from `Raw` when present: `prompt_tokens`→Input, `completion_tokens`→Output, `prompt_tokens_details.cached_tokens`→Cached, `completion_tokens_details.reasoning_tokens`→Reasoning. A Raw decode error is fatal. |
| `openrouter` | `https://openrouter.ai/api/v1` | none | Bearer; `OPENROUTER_API_KEY` | header `x-session-id` | Extension `"cache_control":{"type":"ephemeral","ttl":"1h"}` |
| `ollama` | `http://localhost:11434/v1` | none | none | none | |
| `openai-codex` | `https://chatgpt.com/backend-api/codex` (or a loopback-IP URL only) | none | `Authorization: Bearer <subscription token>`, `ChatGPT-Account-ID`, `originator: unreal-agent`, `User-Agent: unreal-agent`. Credentials come from `OPENAI_CODEX_ACCESS_TOKEN`/`OPENAI_CODEX_ACCOUNT_ID`, or `OPENAI_CODEX_AUTH_FILE`, or `$CODEX_HOME/auth.json` (defaults to `~/.codex/auth.json`, must be mode 0600, `auth_mode` `chatgpt`). JWT `exp` and `chatgpt_account_id` claims are checked. `sk-…` keys are rejected. | body `prompt_cache_key` **and** header `session-id` | Rejects `MaxOutputTokens`. Redirects are not followed. A 401 becomes `codex credentials rejected; renew them externally and recreate the client: …`. The terminal response has empty `output`, so items come from `output_item.done`. |

All clients send `Content-Type: application/json` and use `<base>/responses`, with the base URL trimmed of a trailing `/`.

> OTP note: Req with `into:` streaming (or Finch directly) and an SSE splitter. Set `receive_timeout` to 30 min per chunk. Disable Req's built-in retry and implement §10.4 yourself. Run the call in a Task the coordinator can kill. Encode the body with ordered keys (§2) and keep reasoning `Raw` as an opaque binary (`Jason.Fragment`) so it round-trips byte for byte.

---

## 11. Runner CLI (`unreal-agent-runner`)

### 11.1 Invocation

```
unreal-agent-runner [options] < request.json
unreal-agent-runner [options] '<JSON request>'
unreal-agent-runner [options] -p '<prompt>'
```

Options must come **before** the positional request. At most one positional argument is allowed, and `-p` excludes it. Flags use Go `flag` syntax (`-x value` or `-x=value`):

| Flag | Default | Meaning |
| --- | --- | --- |
| `-p <prompt>` | — | Equivalent to the request `{"prompt": "<prompt>"}`; stdin is not read |
| `-workspace <dir>` | `.` | Agent workspace, Bash cwd, base for ViewImage relative paths, `.env` source, skills root. It must exist and be a directory; it is made absolute. |
| `-session-directory <dir>` | `$XDG_STATE_HOME/unreal-agent/sessions` (if absolute), else `$HOME/.local/state/unreal-agent/sessions` | Session store |
| `-log-directory <dir>` | unset | Also append the stdout JSONL **session items** to `<dir>/<UTC YYYYMMDD-HHMMSS>.jsonl` (dir `0700`, file `0600`). The final error event is **not** written there. |
| `-tool-heartbeat-interval <dur>` | `10m` | Go duration (`10ms`, `90s`, `1h`). `0` disables it. Negative or invalid → error. |
| `-h` | — | Usage plus the request schema on stderr, exit 0 |

### 11.2 Request JSON (unknown fields rejected)

| Field | Type | Notes |
| --- | --- | --- |
| `messages` | `[{role?: "user", content: string, message_id?: UUID}]` | Non-empty. Delivered in order. `role` must be `""` or `"user"`. `message_id` must be a trimmed non-empty UUID; if absent, a UUIDv4 is generated. **The ID is the inbox dedupe key**: a resent ID is ignored on later runs. |
| `prompt` | string | Used only when `messages` is absent; becomes one message with a generated ID. Neither present → `messages must be set`. `messages: []` → `messages must not be empty`. |
| `model` | string | Otherwise `UNREAL_HARNESS_LLM_MODEL`, otherwise the provider default. None → error. |
| `max_attempts` | positive int | Otherwise `UNREAL_HARNESS_LLM_MAX_ATTEMPTS`, otherwise 5. `1` disables retries. |
| `system_prompt` | string | Replaces the default system prompt (§7.4). The preamble always stays. |
| `thinking_level` | `low`/`medium`/`high`/`xhigh`/`max` | Default `high` (an empty value maps to high) |
| `session_id` | non-empty string, `[A-Za-z0-9-]+` | Resume if the file exists, else create. Absent → new UUID session. |
| `disallowed_tools` | `[string]` | Static tools to remove from both context and execution |
| `extra_allowed_tools` | `[string]` | Accepted, ignored. Entries must be non-empty. |
| `include_partial_messages` | bool | Accepted, ignored |

### 11.3 Environment

| Variable | Use |
| --- | --- |
| `UNREAL_HARNESS_LLM_PROVIDER` | Provider name (default `openai`) |
| `UNREAL_HARNESS_LLM_BASE_URL` | Overrides the provider's base URL |
| `UNREAL_HARNESS_LLM_MODEL` | Model fallback |
| `UNREAL_HARNESS_LLM_API_KEY` | API key; falls back to the provider's own variable. Required for providers that have one. Error: `UNREAL_HARNESS_LLM_API_KEY or <VAR> must be set` |
| `UNREAL_HARNESS_LLM_MAX_ATTEMPTS` | Retry budget |
| `SHELL` | Bash shell path (trimmed, default `/bin/sh`; must be absolute) |
| `XDG_STATE_HOME`, `HOME` | Session directory |
| `OPENAI_CODEX_*`, `CODEX_HOME` | Codex credentials |

**Workspace `.env`**: if `<workspace>/.env` exists, it is parsed as `KEY=VALUE` lines (trimmed; blank lines and `#` comments skipped; no quote handling). Variables are set in the **runner process** and therefore inherited by every Bash command. They do not override variables that already exist, except `SANDBOX_EGRESS_PROXY`. If `SANDBOX_EGRESS_PROXY` is set after loading, `HTTPS_PROXY` is set to it. All of this is restored on exit.

### 11.4 Startup sequence

1. Parse flags and the request, validate.
2. Resolve the workspace and load `.env`.
3. Resolve max attempts, the provider, the base URL, the model, and the key. Create the client.
4. Open the store. `Resume(session_id)`, or on `ErrNotExist`, `Create`. Any other resume error, such as a legacy format or an unsupported control, is fatal.
5. Open the log file if one is configured.
6. `mkdir -p <sessions>/operations/<sessionID>`.
7. Discover skills. Build the registry with the enabled names.
8. Start the operation manager. Create the inbox seeded with `ExternalInputIDs`.
9. Submit, in order:
   1. a `settings` control (`ReasoningEffort` from `thinking_level`) with a new UUID;
   2. each message as an `external` input (`Payload` = JSON string of the content);
   3. a `when_idle` stop with a new UUID.
10. Builder: skills, `SetModel{ID, ReasoningEffort}`, the system prompt, and the tools.
11. Register the stdout observer. `coordinator.Run`.

A runner invocation therefore always ends when the agent is idle. Every message to an existing session is a new runner process that resumes the session.

### 11.5 Stdout format (JSONL)

Each line on stdout is one of two things:

**(a) A persisted session item**, exactly `json.Marshal(sessionstore.Item)`, written synchronously in persistence order:

```
{"Sequence":<n>,"RecordedAt":"<RFC3339Nano UTC>","Kind":"<kind>","Data":{…}}
```

`Sequence` continues the session's numbering across runs. Operation checkpoints are **not** emitted.

| Kind | `Data` | Example |
| --- | --- | --- |
| `input` (external) | `{ID, Kind:"external", Payload:"<user text>"}` | `{"ID":"7cea…","Kind":"external","Payload":"sleep 2"}` |
| `input` (settings) | `{ID, Kind:"control", Payload:{Mode:"settings", Reason:"", Parameters:{ReasoningEffort}}}` | `{"Mode":"settings","Reason":"","Parameters":{"ReasoningEffort":"high"}}` |
| `input` (stop) | `Payload: {Mode:"when_idle"\|"hard", Reason}` | `{"Mode":"when_idle","Reason":""}` |
| `input` (heartbeat) | `Payload: {Mode:"heartbeat", Reason:"Heartbeat: waited 600 seconds for tool calls.\nRunning: […]"}` | |
| `turn` | `{ID, PreviousTurnID, Type:"regular"}` | |
| `model_response` | `{TurnID, Response:{ID, Stop, Output:[{ProviderID, Type, Data}], Usage:{InputTokens, CachedInputTokens, CacheWriteInputTokens, OutputTokens, ReasoningTokens, Raw}, Failure:null\|{Code,Message}}}` | Message `Data {Role, Text, Phase}`; tool_call `{CallID, Name, Arguments}`; reasoning `{Summary, Raw}` |
| `tool_call_status` | `{TurnID, CallID, Status:{Error, [ErrorTruncated], [WaitingFor]}, [Operations:[…]]}` | First line: ops `ready` (the call was accepted). Later line: terminal snapshots (the result is available). An error status has no `Operations`. |
| `fork` | `{ParentID, PreviousTurnID}` | |

Real sample from Photon's `test/fixtures/mock_session.jsonl`, a Bash call:

```jsonl
{"Sequence":6,"RecordedAt":"2026-09-22T19:37:47.335111475Z","Kind":"tool_call_status","Data":{"TurnID":"2c1f…","CallID":"call_0dbb…","Status":{"Error":"","WaitingFor":["4c7f…"]},"Operations":[{"MaxOutputLength":40000,"ID":"4c7f…","Type":"shell","Version":3,"Status":"ready","State":{"Input":{"Command":"for i in $(seq 2); do echo tick $i; sleep 1; done; echo done","Shell":"/usr/bin/bash","Directory":"/home/agent/demo/ws"},"BaseDirectory":"/home/agent/demo/rs/operations/1111…","Phase":"","ProcessGroupID":0,"PendingExitCode":null,"OutSize":0,"ErrSize":0,"InlineOut":"","InlineErr":"","InlineOutTail":"","InlineErrTail":"","Result":null,"TerminalError":"","ErrorTruncated":false,"OutTruncated":true,"ErrTruncated":true,"OutPath":"","ErrPath":""}}]}}
{"Sequence":7,…,"Kind":"tool_call_status","Data":{…,"Operations":[{…,"Status":"completed","State":{…,"OutSize":19,…,"Result":{"Out":"tick 1\ntick 2\ndone\n","Err":"","OutSize":19,"ErrSize":0,"ExitCode":0},…,"OutTruncated":false,"ErrTruncated":false,"OutPath":"…/4c7f…/out","ErrPath":"…/4c7f…/err"}}]}}
```

A ViewImage terminal snapshot carries the whole base64 image in `State.Result.Content`, so lines can be several MB long. Photon reads with 1 MiB line chunks and reassembles them.

Order is not fully deterministic. For example, the trailing `when_idle` input may appear before or after the first `turn`/`model_response`, because the first turn can start before the inbox drains.

**(b) A terminal error event**, only when the run fails and was not interrupted by a signal: `{"type":"error","message":"<error text>"}`. It is written to stdout only (not the log file). The same message is printed to stderr as `unreal-agent-runner: <error text>`.

**Stderr** also carries `skill error> <err>` lines and the usage text.

**Exit codes**: `0` = success (idle stop reached) or `-h`. `130` = the context was canceled by **SIGINT** (no error event is emitted). `1` = any other error. Only `os.Interrupt` is trapped. SIGTERM kills the runner the default way, with no cleanup.

A failure writing an item to stdout cancels the run and returns that error.

### 11.6 What Photon depends on today (compatibility checklist)

From `node/lib/photon_node/{runner,run}.ex` and `lib/photon/transcript.ex`:

- **Args**: `-workspace W -session-directory S -log-directory L '<json>'`. The JSON contains `session_id`, `prompt`, `thinking_level` (default `"high"`), and optionally `model`, `system_prompt`, `disallowed_tools`, `max_attempts`.
- **Env**: `UNREAL_HARNESS_LLM_PROVIDER`, `UNREAL_HARNESS_LLM_BASE_URL`, `UNREAL_HARNESS_LLM_API_KEY`. The mock provider is `provider=openai` with a mock base URL and model `mock-model`.
- **Stop**: SIGINT to the runner PID, which expects exit 130.
- **Delete**: removes `<S>/<id>.session.jsonl` and `<S>/operations/<id>/`.
- **Transcript fields read**:
  - `Kind`, `Data`, `RecordedAt`.
  - Input `Kind`/`Payload`; control `Mode`/`Reason`/`Parameters.ReasoningEffort`; fork `ParentID`.
  - Response `Output[].Type/Data.{Text,Summary,CallID,Name,Arguments}`, `Usage.{InputTokens,CachedInputTokens,OutputTokens,ReasoningTokens}`, `Stop`, `Failure.{Code,Message}`.
  - `tool_call_status` `CallID`, `Status.{Error,WaitingFor}`, `Operations[0].{Type,Status,State}`.
  - Shell `State.{Result.{Out,Err,ExitCode},TerminalError,OutPath,ErrPath}`.
  - ViewImage `State.Result.{Content,EncodedMIMEType,Error,OriginalMIMEType,OriginalWidth,OriginalHeight,ScaleRatio}`.
  - `{"type":"error","message"}`.
- Photon marks tool entries `ready|awaiting|canceling` as interrupted when the process exits. A later run updates them through the next terminal `tool_call_status` for the same `CallID`.

---

## 12. Go-specific choices an OTP port should redesign

1. **Goroutine plus `select` coordinator → `gen_statem`.** Channels become messages. `context.Context` becomes links, monitors, and explicit cancel messages. `time.After` becomes `Process.send_after` with refs, which handles stale-timer discard for grace and heartbeat.
2. **Channel slurp (1 ms idle, cap 100 per source) → mailbox drain** with `receive … after 1`, in the same inbox → updates → reconcile → decide order.
3. **Random map iteration** in `scheduleToolCalls`, `reconcileToolCalls`, `dispatchOperationsToManager`, and `cancelOperations` makes status order, dispatch order, and the order of results in context nondeterministic. Pick a deterministic order: tool calls by response output order, then op order. Nothing upstream relies on randomness.
4. **LLM goroutine with a canceled context → supervised Task** tagged with the turn ID. Kill it on steering, hard stop, or shutdown. Discard results for any turn other than the current one.
5. **Inbox goroutine with an unbounded slice → coordinator-local queue** (or a GenServer), with `MapSet` dedupe seeded from history.
6. **Operation manager goroutine plus one goroutine per primitive → DynamicSupervisor plus one gen_statem per operation.** Keep "Add is idempotent per ID", "checkpoint = full snapshot", "completion after cancel ⇒ canceled", and "unsupported type/version ⇒ error from Add".
7. **`os/exec` with Setpgid and file fds → erlexec or MuonTrap.** Ports can't do process groups or fd redirection. Reproduce SIGTERM → 5 s → SIGKILL on the **group**, after a normal exit too, and `128+signal` exit codes.
8. **Process exit races cleanup**: Go `os.Exit(130)` on SIGINT returns without waiting for the manager to finish killing process groups, which can leave orphans. SIGTERM is not handled at all. Shell recovery also never kills a recorded-but-orphaned PGID. In OTP, trap exits, wait for operation shutdown, and consider killing a recorded `ProcessGroupID` during recovery.
9. **Synchronous observer on the coordinator goroutine → explicit writer.** Decide on backpressure and failure semantics; upstream treats a stdout failure as fatal.
10. **JSON**: PascalCase keys, struct order, base64 `[]byte`, `""` for nil bytes, `null` pointers, omitzero rules, nanosecond timestamps, deterministic and byte-stable request bodies. Jason needs ordered encoding to match.
11. **Rune vs grapheme**: limits count Unicode code points, and the truncation marker counts **bytes**. Don't use `String.length`/`String.slice`.
12. **Number formatting**: Go `%g` (heartbeat: `600`, `0.01`; Erlang's `float_to_binary(…, [:short])` gives `600.0`), `%.2f` (coordinate multiplier), `%.6g` and `%.1f` (image size error).
13. **Go error text leaks to the model**: json v2 decode errors (`jsontext: unexpected EOF`, `duplicate object member name "command"`), `os` errors, `%q` quoting. A port can't match these byte for byte. Keep the harness's own prefixes and messages (listed in §8.3–§9) verbatim and accept that library-originated suffixes differ.
14. **Image pipeline**: Go `image/*` plus `x/image` (bilinear, PNG, JPEG q90, byte-exact JPEG passthrough at ratio 1). In Elixir use Vix/`Image` (libvips). Expect pixel-level differences; keep the metadata semantics, limits, and messages.
15. **Directory fsync and atomic rename**: Go fsyncs the directory after rename. OTP needs a NIF/port, or accepts slightly weaker durability for create and fork.
16. **Per-store write cache with a single-writer assumption → one store GenServer per session**, which also makes concurrent `Submit` from Photon safe.
17. **Remote jobs and the proxy manager map naturally onto distributed Erlang**: the coordinator and store on the hub or node, operation processes on the machine that runs tools.

## 13. Upstream quirks to replicate or consciously fix

- Duplicate `function_call_output` entries for one `call_id` (placeholder, then the real result) are intentional (§6.8).
- Forks drop operation-backed results of inherited calls (§4.7). Fix this, or reject forks while calls are unfinished.
- Initial shell state has `OutTruncated/ErrTruncated = true`. Harmless, but it's on the wire.
- A `model_response` with `Failure` ends the run with exit 0 (no turn follows). In-band `error` events, after retries, fail the run with exit 1.
- After a `model_response` is persisted, translation on resume produces **new operation IDs** if the original status write never landed.
- Unknown response output item types are fatal (anything other than message, function_call, reasoning, web_search_call).
- No command timeout. No context-window management.
- `crash` inputs and `compaction` turns are accepted but nothing produces them.
- The heartbeat timer is measured from when the coordinator started waiting, not from the last operation update ("nothing has happened for ten minutes" in the preamble is only approximately true).
- The settings control the runner submits on every invocation (`thinking_level` default `high`) **does** change the effort for later turns. A recovery turn at startup runs before that control is read, so it uses the replayed effort.

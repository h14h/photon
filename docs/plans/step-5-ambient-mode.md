# Step 5: Ambient mode

Plan for build step 5 of `docs/projects-and-blip.md`, the last step of
the build order. Ambient mode is a setting, off by default. Off, what
reaches Blip is exactly what step 4's quiet mode lets through, Blip's
tools and prompt are step 4's, and no timer runs. On, Blip also gets:

- a digest every few hours of what changed across the owner's projects
  and threads, posted into Blip's conversation as one message. It is sent
  only when something in it is new to the owner (a finished run they
  haven't opened, or a schedule that stopped); the rest of what changed
  rides along in compact form
- a daily review, around 09:00 where the owner is, of threads left
  stopped, failed or waiting on the owner for days

Blip reads each one and decides what is worth telling the owner, and in
what words, in its own conversation. What it does in those runs is
logged as its own follow-up. It can't start or change work in them; the
owner says what to pick up, and Blip does it then. Closing a thread stays
the owner's Resolve button.

The work ships as one pull request, built as the ordered tasks in
section 14. Each section is meant to be read on its own: an agent handed
one task reads section 1, the sections its task points to, and the
task. Rule numbers refer to `docs/otp-design-guide.md`; the short
version is `docs/plans/otp-brief.md`. Paths are relative to the repo
root. Module names are the plan's; the placement is the point.

This plan was first written against `impl/step-4-polish` at `1c92955`
and revised against `b5ec377` ("Step 4 polish: A context file says which
thread changed it, plainly"). Three of the commits since then matter
here: `fe397cd`, `bb62291` and `a1e9ab1` make Blip's panel and the
activity log name each thread by its current title, reading the thread
IDs `Photon.Transcript.thread_ids/1` finds in a message's source. The
checkout also has uncommitted polish work in progress (machine tools,
`conversation_components.ex`, `blip_live.ex`, `conversation_view.ex`,
`thread_live.ex`). Each task re-reads the files it names before changing
them. Thread IDs are conversation IDs (`c_...`); the examples use them.

The data is new and additive: one migration adds the `digest_items`
table and a `reviewed_at` column on `threads`. Nothing is migrated or
kept compatible; deleting the hub database is fine, as it was for step 4.
No new dependency is added.

## 1. Goal and scope

After this step:

- Settings has an Ambient mode section (section 2): the switch, and how
  often the digest comes (every hour, 3 hours or 6 hours; 3 by default).
  Saving it arms or retires two durable timers in the same commit that
  stores the setting. A Save that doesn't carry the switch (the section
  isn't on the page) leaves the setting as it was.
- While it is on, the hub collects what changes as pending digest items
  (section 3.2): the owner's finished runs, schedules that stopped,
  context files written by threads or the owner, projects and threads the
  owner made, Purpose edits, and the owner's Resolves. Nothing is
  collected while it is off.
- Every interval, the digest timer reads the pending items. If at least
  one is new to the owner, it posts one `[Digest]` signal into Blip's
  conversation carrying all of them and deletes them, in one commit
  (section 3). If none is, no message and no model run; the smaller items
  wait for the next digest that has something new.
- Once a day, around 09:00 at the owner's UTC offset, the review timer
  lists threads that are quiet, failed or waiting on the owner and have
  sat untouched for `quiet_after_hours` (72), and posts one `[Daily
  review]` signal (section 4). Each thread is raised once per quiet spell,
  and again after a week if still untouched. Like schedules, the review
  is a fixed 24-hour repeat and drifts an hour at daylight saving
  changes until the owner saves Settings again.
- Both obey the existing consent: a timer's firing skips while Settings
  doesn't let schedules use the owner's plan.
- Blip's runs started by a digest or a review report only: its tools that
  start, message or stop threads, or change projects and schedules,
  refuse in them (section 5.2). When there is nothing worth saying Blip
  answers `[nothing to tell]`, which makes no bubble and no activity row,
  and draws nothing in its panel (section 5.4).
- Earlier digests and reviews shrink in Blip's later requests: the
  message becomes a one-line stub, its tool results are cut short, and a
  run that answered `[nothing to tell]` is left out (section 5.3). So
  ambient mode doesn't grow every later request without limit.
- The home page warns when digests are skipping for consent or a timer
  stopped, and marks the threads Blip raised in a review (section 7.3).
  The activity log credits digest and review runs to "Blip's follow-up on
  the digest" or "... on the daily review" (section 7.5). Blip's panel
  draws a digest or a review as one collapsed line (section 7.4).
- `PHOTON_MOCK_MODEL=1` covers every flow: the scripted Blip summarises a
  digest, answers `[nothing to tell]` when its memory says to ignore
  what's in it, and lists a review's threads (section 8). With the
  scripted model, Settings shows "Send a digest now" and "Run the review
  now" for trying it. `PHOTON_QUIET_AFTER_HOURS=0` makes a stopped thread
  quiet at once, so the review can be tried without waiting three days.
- `docs/projects-and-blip.md` and `docs/architecture.md` say all five
  steps are built and what was left for later (task M12).

Out of scope, for later:

- Digests of machine changes (a node going offline).
- Blip resolving, archiving or deleting threads. Step 4 left these for
  later and nothing in step 5 needs them: the review tells the owner
  where the Resolve button is.
- Quiet hours for digests, and a digest interval other than the three
  offered. A review time other than 09:00.
- Schedules and the review following the owner's time zone across
  daylight saving changes. That needs a time zone database, which
  AGENTS.md says not to add unasked.
- Discord, watchers, collaborators, approvals for shell commands, a model
  per thread, deleting or archiving projects and threads, pruning the
  activity log and the digest's history.

## 2. The setting

### 2.1 Where it is stored

Settings today is a JSON file (`Photon.Settings`, `settings.json` in the
data directory), written outside the database. Ambient mode can't live
there: turning it on has to create two durable timer tasks, and turning
it off has to retire them, and a file write and a database commit can't
be one step. A crash between them would leave a digest timer firing with
the setting off, or the setting on with no timer.

So ambient mode's settings are a durable doc, `global/ambient`, written
by `Photon.Ambient.configure/1` in the same commit that arms or retires
the timers. The Settings page shows and saves them with the rest of its
form (section 2.2); only the storage differs. The doc:

```elixir
%{
  "on" => false,
  "every_minutes" => 180,          # 60, 180 or 360
  "offset_minutes" => 0,           # the owner's UTC offset when the review timer was armed
  "version" => 0,                  # bumped by every configure that arms
  "digest_task_id" => nil,         # the live digest timer, or nil
  "review_task_id" => nil,         # the live review timer, or nil
  "on_since" => nil,               # iso8601, when it was last turned on
  "last_sent_at" => nil,           # iso8601, the last digest posted ("sent" or "queued") since then
  "last_digest" => nil,            # %{"at" => iso8601, "outcome" => String.t(), "count" => n}
  "last_review" => nil,            # the same, for the review
  "stopped" => nil                 # %{"job" => "digest" | "review", "reason" => text} after a timer failed
}
```

`"last_digest"` records every firing, skips included, for the Settings
page. `"last_sent_at"` is written only when a digest was posted, so the
next digest can say which window it covers (section 3.4).

`Photon.Signals` owns reading and writing the doc (`ambient_doc/0`,
`ambient_doc_tx/1`, `put_ambient_doc_tx/2`), because the settle hook in
`Photon.Threads` reads `"on"` inside its commit and can't depend on
`Photon.Ambient`, which depends on `Photon.Threads`. `Signals.mode/0`
and `mode_tx/1` return `:ambient` when `"on"` is true, else `:quiet`;
`mode/0` is the place step 4 left for this (section 3.6 of the step 4
plan). Everything else about the doc's contents is `Photon.Ambient`'s.

The next digest and review times are read from the timer tasks (their
checkpoint's `"next_at"`), never stored on the doc, as `Photon.Schedules`
reads a schedule's next time from its routine task (rule 15).

### 2.2 The Settings page

A new section in `PhotonWeb.SettingsLive`'s form, `#ambient`, after the
Model section and before the Blip section. It shows whenever Blip can
think (`ChatGPT.ready?/1`: signed in with plan use, or the scripted
model), unlike the Model section, which needs a ChatGPT sign-in; so it
shows with `PHOTON_MOCK_MODEL=1`. When it doesn't show, its fields
aren't in the form, and a Save leaves ambient mode as it was (section
2.3).

- Heading: "Ambient mode".
- Checkbox `settings[ambient]` (`#settings_ambient`), label: "Let Blip
  follow along and speak up". The `<.input type="checkbox">` component
  sends a hidden `"false"` when it is unticked, so an unticked box always
  arrives as `"false"`.
- Hint `#ambient-hint`: "Off, Blip hears about work it started, failures,
  and questions for you, as it does now. On, it also reads a digest of
  what changed in your projects every few hours, and around 9 each
  morning looks over threads left stopped, failed or waiting on you. It
  tells you what's worth knowing in its chat. Each digest and review is a
  run on your ChatGPT plan: digests are skipped when nothing new
  happened, and both are skipped while schedules can't use your plan."
- Select `settings[ambient_every]` (`#settings_ambient_every`), label
  "Digest", options "Every hour" (60), "Every 3 hours" (180, the
  default), "Every 6 hours" (360).
- Hidden input `settings[utc_offset]` (`#settings_utc_offset`,
  `phx-update="ignore"`) with a colocated hook, `.UtcOffset`, that sets
  its value to the browser's offset in minutes
  (`-new Date().getTimezoneOffset()`) on mount. The page already shows
  every time in the browser's zone (`PhotonWeb.TimeComponents`), so the
  review's 09:00 is the browser's 09:00 too. No value (the hook didn't
  run) keeps what the doc has.
- `#ambient-needs-consent`, shown when the saved setting is on, consent is
  off and the hub isn't on the scripted model: "Schedules can't use your
  plan while you're away, so digests and reviews will skip. Turn on "Let
  schedules use my plan while I'm away" above." (The Model section is the
  one above it; with no sign-in there is no consent to give, and the
  scripted model needs none.)
- While the saved setting is on, a short status block `#ambient-state`:
  - `#ambient-next`: "Next digest around <local_time>; next review
    <local_time>."
  - `#ambient-pending`: "2 changes waiting, and 3 smaller ones.", "2
    changes waiting.", "3 smaller changes wait for the next digest with
    something new." or "Nothing new yet." The counts are worked out with
    the digest's own rule (section 3.3 step 5), so they match what a
    digest would send.
  - `#ambient-last-digest` and `#ambient-last-review`, when there was
    one: "Last digest <local_time>: sent 3 changes." / "...: nothing new,
    skipped." / "...: skipped, schedules can't use your plan." / "...:
    Blip still had the last one waiting, skipped." A queued one reads
    "sent 3 changes, after what Blip was doing."; a review "sent 2
    threads." or "no threads to review, skipped."
  - `#ambient-stopped` when a timer failed: "Digests stopped after an
    error: <reason>. Save settings to start them again." (for the review:
    "The daily review stopped after an error: <reason>. Save settings to
    start it again.")
- Only on the scripted model (`status.scripted?`), two buttons,
  `#ambient-digest-now` ("Send a digest now") and `#ambient-review-now`
  ("Run the review now"), `type="button"`, `phx-click`, size `sm`,
  variant ghost. They exist for trying the feature with
  `PHOTON_MOCK_MODEL=1`; with a real sign-in nothing on the page spends
  the plan outside the timers and their consent.

The words come from `PhotonWeb.AmbientText` (pure). Times are
`local_time/1`, as everywhere.

What it consents to: turning ambient mode on lets the hub start Blip
runs nobody asked for, on a timer. It does not replace the scheduled-work
consent; it needs it. The checkbox's hint says both, and
`#ambient-needs-consent` says when the second is missing.

### 2.3 Saving, changing and turning off

`SettingsLive`'s `"save"` handler calls `Settings.save(params)` as today,
then `Ambient.configure(params)`. Two writes, each consistent on
its own: the settings file, then one commit for the doc and the timers.
`Settings.normalize/2` drops the ambient keys, so the file never holds
them. The handler then rebuilds the form from
`Map.merge(settings, AmbientText.form_values(Ambient.status()))`, as
`mount/3` does. Rebuilding it from `Settings.save/1`'s result alone, as
today's handler does, would draw the box unticked after a Save, and the
next Save would send `"false"`.

`Photon.Ambient.configure(params)` is one `Durable.commit` (the first
draft also passed the settings `Settings.save/1` returned; nothing in the
commit reads them, so it takes only the params):

1. Read the doc (`Signals.ambient_doc_tx/1`) and the live state of its
   two timer tasks (`Tx.get_task/2`; a missing or terminal task counts as
   not live).
2. `Ambient.Rules.config(params, doc)` reads the form. A key missing from
   `params` keeps the doc's value, as `Settings.normalize/2` keeps saved
   values for missing keys:
   - `"ambient"`: `"true"` turns it on, `"false"` turns it off, missing
     or anything else keeps `doc["on"]`.
   - `"ambient_every"`: one of 60, 180, 360, else the doc's value, else
     180.
   - `"utc_offset"`: a whole number of minutes from -720 to 840, else the
     doc's value, else 0.

   Never an error: the page can't send anything else, and anything else
   keeps what was there.
3. `Ambient.Rules.changes(doc, config, live)` returns what to do, from
   this table (first match per timer):

| Before | After | Digest timer | Review timer | Pending items, queued messages |
|---|---|---|---|---|
| off | off | nothing | nothing | nothing |
| off | on | arm | arm | nothing (the table is empty while off) |
| on | off | retire | retire | delete every item; withdraw queued digest and review messages; clear `reviewed_at` on the threads a withdrawn review named |
| on | on, `every_minutes` changed or its timer not live | retire (if live), arm | | keep |
| on | on, `offset_minutes` changed or its timer not live | | retire (if live), arm | keep |
| on | on, nothing changed and both live | nothing | nothing | keep |

4. Apply it, write the doc (new values, `version` + 1 when anything was
   armed, the new task IDs (both nil when it is off), `stopped: nil` when
   anything was armed or it was turned off, and `on_since`, with
   `last_sent_at` back to nil, when it went from off to on, so the first
   digest's window starts there and not at a digest from an earlier
   spell) and announce `{:ambient_changed}` on `"ambient"`. It returns
   `:ok`.

Arming creates a task of kind `"ambient"` (section 6) with request ID
`"ambient:<job>:v<version>"`. The digest's first firing is
`now + every_minutes`, so turning it on doesn't post at once; the
review's is the next 09:00 at `offset_minutes` after now
(`Ambient.Rules.next_review/2`). Retiring is `Tx.request_abort(tx, task,
background: true)`, as `Photon.Schedules` retires a routine: a firing
step of the old task commits nothing afterwards (the step fence,
`Photon.Durable.Runtime.commit/2`).

Turning it off cancels everything pending, in that one commit:

- both timers are retired, so no digest or review fires afterwards, even
  one whose step had already started
- every pending digest item is deleted (`Signals.drop_items_tx(tx,
  :all)`)
- a digest or review message still queued in Blip's inbox (Blip was busy)
  is withdrawn (`Signals.withdraw_ambient_tx/1`, which returns the
  withdrawn refs), since Blip hasn't seen it. One already placed is
  Blip's run in progress; the owner can Stop Blip as usual.
- the threads a withdrawn review named (its ref's `"items"`) get
  `reviewed_at` set back to nil (`Threads.unmark_reviewed_tx/2`), since
  Blip never read that review. Otherwise Home would keep saying "In
  Blip's review" and the next review would skip them for a week.

From then on the mode is `:quiet` and nothing is collected, so behaviour
is step 4's. Turning it on later starts from an empty table: nothing that
happened while it was off reaches a digest.

Saving Settings from a browser at a different UTC offset (after a
daylight saving change, or travelling) re-arms the review timer on the
same Save (row 5 of the table). Saving while ambient mode is off changes
no timer.

## 3. The digest

### 3.1 What counts as a change

The owner's decision is a digest of everything that changed across
projects and threads, with Blip deciding what is worth telling. So the
digest collects every change Blip doesn't already hear about at once,
and splits them by whether the owner has seen them yet. Only the first
kind can make a digest happen; the second rides along, so Blip can follow
along without waking its model for things the owner already knows.

New to the owner (a digest is sent when at least one stands):

| Item kind | Collected when | New to the owner at digest time when |
|---|---|---|
| `"finished"` | a run of the owner's thread (the owner's message, or a firing of a schedule the owner made) ends `"done"` without asking anything (`Signals.Rules.thread_update/2` in `:ambient` mode returns `:digest`) | the thread still reads `:unread` (finished and not opened since) |
| `"schedule_stopped"` | a schedule's routine task fails (`Photon.Schedules.Routine.on_fail/3`), any schedule, Blip's or a project's | the schedule still exists |

Smaller changes (they ride along, never trigger a digest on their own):

| Item kind | Collected when | At digest time |
|---|---|---|
| `"finished"` | as above | the thread no longer reads `:unread`: the owner opened it, resolved it or wrote to it again. Shown as "finished; the user has seen it" |
| `"file_written"` | a context file is created, replaced or edited by a thread (`Projects.write_file_tx/5`, `edit_file_tx/6` with a thread's ID as writer) or by the owner (`create_file/2`, `save_file/4`, `delete_file/2`) | one line per project and file, the newest writer; dropped when the project is gone |
| `"project_created"` | the owner makes a project (`Projects.create/1`) | dropped when the project is gone |
| `"purpose_changed"` | the owner edits a project's name or Purpose (`Projects.update/2`) | one per project, the newest |
| `"thread_started"` | the owner starts a thread from a project page (`Threads.start/2`) | dropped when the thread is gone |
| `"resolved"` | the owner presses Resolve (`Threads.resolve/1`) | dropped when the thread is no longer resolved (Reopen, or a new message) |

What is still left out, and why:

- Runs Blip started or messaged, failures, runs that end asking, and
  `ask_blip` questions: Blip already got each as a signal.
- What Blip did itself (its file writes through `"blip"` as writer, the
  projects and threads its tools made): it did them.
- Stops: the owner or Blip pressed Stop, and the daily review covers a
  stopped thread left alone.
- Threads going quiet: that is the daily review's.
- Machine changes: for later.

### 3.2 Collecting

A new table, `digest_items` (migration
`apps/hub/priv/repo/migrations/20261010010000_ambient.exs`; the
`20261010000000` timestamp the first draft named was already taken by
`machine_op_output`), schema
`Photon.Signals.DigestItem`, behind `Photon.Signals`:

| Column | Type | Notes |
|---|---|---|
| `id` | string, primary key | `di_<suffix>` |
| `key` | string, not null, unique index | what makes it once: the settle's signal key (`"settle:<submission id>"`, `Signals.Rules.key/1`), `"schedule:<task id>:failed"`, or `"<kind>:<random id>"` for the smaller kinds |
| `kind` | string, not null | one of the kinds in section 3.1 |
| `thread_id` | string, null | |
| `project_id` | string, null | nil for Blip's own schedule |
| `schedule_id` | string, null | |
| `name` | string, null | a context file's name |
| `writer` | string, null | a file's writer: a thread's ID or `"user"` |
| `note` | string, null | at most 600 characters: the run's note (`State.note/2`), the routine's failure reason, or `"deleted"` for a deleted file |
| `inserted_at` | `utc_datetime_usec`, not null | indexed |

No foreign keys: an item whose thread, project or schedule is gone is
dropped at digest time. Titles and names are read then, not stored, so a
renamed thread reads with its new title.

The same migration adds `reviewed_at` (`utc_datetime_usec`, null) to
`threads` (section 4.2).

`Signals.collect_tx(tx, item)` with `item = %{key:, kind:, thread_id:,
project_id:, schedule_id:, name:, writer:, note:}` (missing fields nil)
inserts the row when `mode_tx(tx) == :ambient`, and does nothing
otherwise or when the key exists (`on_conflict: :nothing` on `key`). When
it inserts, it announces `{:ambient_changed}` on `"ambient"`
(`Signals.ambient_topic/0`), so the Settings page's counts follow every
kind of item, a failed schedule's included. It returns `:ok`. It runs on
the harness's hook paths (the settle hook runs in the Scheduler's abort
and fail commits; `on_fail/3` in the Scheduler's fail commit), so it is
total in the sense of section 3.1 of the step 4 plan: missing fields are
nil, a non-binary note is nil, a too-long note is cut, and it never
raises.

The call sites:

- `Threads.settled_tx/3`: today it asks
  `SignalRules.thread_update(facts, Signals.mode())`. It now passes
  `Signals.mode_tx(tx)`, so the mode is read in the settle's own commit.
  A result of `:digest` calls `Signals.collect_tx/2` with the settle's
  key, `"finished"`, the thread and project, and `State.note("done",
  text)`. Any other kind posts as today.
- `Schedules.Routine.on_fail/3`: after recording the failure on the row
  it still carries, `"schedule_stopped"` with the schedule and its
  project, and the reason.
- `Projects.write_file_tx/5` and `edit_file_tx/6`, after a write that
  succeeded, when the writer isn't `"blip"`: `"file_written"`.
  `create_file/2`, `save_file/4` and `delete_file/2`, inside their
  commits: `"file_written"` with writer `"user"`.
- `Projects.create/1` (not `create_tx/2`, which Blip's `start_project`
  calls): `"project_created"`. `Projects.update/2`: `"purpose_changed"`,
  only when the save changes the name or the Purpose (a Save of the
  same values is no change).
- `Threads.start/2` (not `start_tx/4` from Blip's tools or a schedule):
  `"thread_started"`. `Threads.resolve/1` (not `reopen/1`): `"resolved"`.

`Photon.Projects` gains `Photon.Signals` as a Boundary dep; `Signals`
depends only on `Photon.Durable`, `PhotonCore`, `Photon.Repo` and
`Ecto`, so there is no cycle.

`Signals.Rules.thread_update(facts, :ambient)` is `thread_update(facts,
:quiet)` with one more cell: a `"done"` run, not asking, `ended?: true`,
with no Blip source, is `:digest` instead of nil. Every other cell is the
same in both modes. A settle that doesn't end the run (`ended?: false`)
is nil in both, so a thread answering one queued input after another
makes one item, at its end.

### 3.3 The timer and the firing

The digest timer is a durable task of kind `"ambient"` with input
`%{"job" => "digest", "first_at" => ms, "every_ms" => ms}`; its steps are
the routine's shape (section 6). Each firing, `Ambient.fire_tx(tx,
"digest", firing)` runs in the step's fenced commit, with `firing =
%{allowed?: Schedules.consent?(), key: "digest:<task id>:<runs>", now:
ms}` read before the commit, as `Routine` reads consent and the clock:

1. Read the doc. Not on (only reachable through `digest_now/0`, since a
   retired timer's commit is fenced out): outcome `"off"`, and nothing
   is written (step 8 is skipped too).
2. Not `allowed?`: outcome `"skipped_consent"`. Items stay.
3. A digest message is still queued in Blip's inbox
   (`Signals.queued_ambient?(tx, "digest")`): outcome `"skipped_queued"`.
   Items stay, and go in the next one.
4. Read every pending item (`Signals.pending_tx/1`, oldest first), the
   board (`Threads.board(:all)`, three queries), and the places the
   items name: the prompts of the schedules that still exist
   (`Schedules.prompts/1`) and every project's slug and name
   (`Projects.list/0`).
5. `Ambient.Rules.digest(items, board, places)` sorts each item into new,
   smaller or gone, by the tables of section 3.1. It keeps one item per
   subject, the newest: one `"finished"`, `"thread_started"` or
   `"resolved"` per thread, one `"schedule_stopped"` per schedule, one
   `"file_written"` per project and file, one `"project_created"` or
   `"purpose_changed"` per project (folded items aren't gone; they go
   with the digest that carries their subject). It orders each
   group by project name, then time. It returns `%{new: rows, smaller:
   rows, more_new: n, more_smaller: n, gone: item_ids, snapshot: counts}`:
   at most 20 new rows and 15 smaller rows, how many more of each, the
   IDs of items whose subject is gone, and the board's counts for the
   closing line (running, waiting on the owner, failed).
   `Ambient.status/0` runs the same function for the Settings page's
   counts.
6. No new rows: delete the gone items (`Signals.drop_items_tx/2`), keep
   the rest, outcome `"skipped_nothing"`. No message, no model run.
7. New rows: post one signal (`Signals.post_tx/2`) with key
   `firing.key`, the text, ref and older stub of section 3.4; delete
   every item it read; outcome `"sent"` when Blip was idle
   (`Tx.active_run/2` is nil), else `"queued"`. Write `"last_sent_at"`.
8. Write `"last_digest"` (`at`, `outcome`, `count`: new plus smaller, with
   the more counts) on the doc and announce `{:ambient_changed}`.

The step then waits for the next time: `Ambient.Rules.next_firing(next_at,
every_ms, now)`, which is `Schedules.Rules.next_after/3`'s rule (slots
missed while the hub was down are skipped, not fired in a burst),
repeated in the ambient core because `Photon.Schedules` doesn't export
its rules. A hub that was down at the digest's time fires it once when it
comes back, then keeps to the interval.

Every read and write of a firing is inside the step's commit, so a
firing that the fence ignores (the timer was retired, or the step is a
leftover from before a Scheduler restart) leaves the items for the next
one and posts nothing. A posted digest and the deletion of the items it
carries are one commit: no item is reported twice or lost.

`Ambient.digest_now/0` runs the same `fire_tx/3` in a commit of its own,
with `allowed?: true` and key `"digest:now:<random id>"`, and returns
what `fire_tx/3` returns: `%{at: DateTime.t(), outcome: String.t(),
count: n}`, the firing as step 8 records it. It doesn't move the timer. Only the scripted model's buttons
and the tests call it.

### 3.4 What Blip reads, and what the panel draws

`Photon.Ambient.Text.digest/3` writes one text part:

```
[Digest] Since the last digest (2026-10-07 12:00 UTC), in your user's projects.
New to the user:
- Garden / "Fix the pump" (c_123) finished. It said: Replaced the fuse and the pump runs again.
- Garden / schedule sc_9 "check the gutters" stopped after an error: the thread's project no longer exists.
- House / "Paint the fence" (c_456) finished. It said: Bought two cans of white.
...and 4 more; list_threads with state unread shows them.
Already seen by the user, or done by them:
- Garden / "Order seeds" (c_321) finished; the user has opened it.
- Garden / context file notes.md written by "Fix the pump" (c_123).
- House / context file colours.md written by the user.
- The user started project Shed.
- The user edited project Garden's name or Purpose.
- The user started "Gutters" (c_789) in House.
- The user resolved Garden / "Old pump" (c_222).
...and 3 more smaller changes.
Now: 2 running, 1 waiting on the user, 1 failed.
```

"Since the last digest" names `"last_sent_at"`, so a skipped firing in
between doesn't shorten the window it claims. Before the first: "Since
ambient mode was turned on (<on_since>)". Notes are cut to 280
characters (they are stored at 600); smaller rows carry no notes. The
whole text is at most 6,000 characters. The "Already seen" block is left
out when it is empty. The "Now" line leaves out zero counts, and is
"Now: nothing running or waiting." when all are zero. A deleted file
reads "deleted by" instead of "written by", and Blip's own schedule reads
"Your schedule sc_9 ...". Rows that don't fit in the 6,000 characters
are counted in the "...and N more" lines. `Text.digest/2` takes the
doc for the window, so the text test can check a skip between two
sends.

The ref, in the message's `source["signals"]`, is

```elixir
%{
  "kind" => "digest",
  "key" => "digest:...",
  "items" => [
    %{"kind" => "finished", "new" => true, "thread_id", "title", "project_id", "slug", "project", "note"}
    | %{"kind" => "schedule_stopped", "new" => true, "schedule_id", "project_id", "slug", "project", "prompt", "reason"}
    | %{"kind" => "finished" | "file_written" | ..., "new" => false, ...}
  ],
  "more" => 4,
  "more_smaller" => 3
}
```

`"title"` is the title when the digest was written; pages show the
thread's current title instead (section 7.4).

The message's source also carries `"older"`, the stub Blip's later
requests see in place of the text (section 5.3):

```elixir
"older" => %{
  "text" => ~s([Digest delivered 2026-10-07 15:00 UTC: 3 new, 6 smaller. New: Garden / "Fix the pump", Garden / schedule "check the gutters", House / "Paint the fence".]),
  "drop_if_answer" => "[nothing to tell]"
}
```

The stub names at most five subjects and is at most 300 characters,
ending ", and N more" when it names fewer than it carries.
`Signals.post_tx/2` takes it as an optional `older:` field and puts it
in the source next to `"signals"`.

`Signals.Rules.merges?/2` already keeps a digest from merging into a
message of another kind, and step 3 above keeps a second digest from
merging into a queued one.

### 3.5 How Blip's reply reaches the owner

The digest is a message in Blip's conversation, so it starts a Blip run
when Blip is idle and waits as a follow-up when it is busy (and Blip's
Stop keeps it: source kind `"signal"` is background input). Blip's answer
is an ordinary answer in its conversation:

- In Blip's panel it reads like any reply, under the digest's collapsed
  line (section 7.4).
- With the panel closed it makes a speech bubble (`Assistant.Notice`'s
  `:reply`), as an answer to a thread update does today. This is Blip
  speaking up on its own.
- The activity log records it as a `kind: "message"` row ("Told you:
  ..."), with origin `"follow_up"` and `origin_id` `"digest"` (section
  5.1), from `Assistant.settled_tx/3` as for any run the owner didn't type
  into.
- An answer of `[nothing to tell]` makes no bubble, no row, and draws
  nothing in the panel (section 5.4).

### 3.6 Cost and bounds

- At most one digest per interval (60 minutes at the least), plus, on the
  scripted model only, presses of "Send a digest now". No new item means
  no message and no model run, however many smaller changes wait.
- A digest run can't start, message or stop threads (section 5.2), so it
  can't cause work whose end becomes another digest item. Items come from
  the owner's own actions, runs of the owner's threads, threads' file
  writes and failing schedules; none of these is caused by a digest run,
  so digests can't feed themselves.
- While a digest waits in Blip's inbox, the next firing skips rather than
  stacking a second.
- The text is bounded (20 new rows, 15 smaller rows, 6,000 characters),
  and so is the run (the harness's 60-round limit, as for any run).
- Later requests carry little of it. Once the digest's run is over, each
  later request in Blip's conversation sees the digest as its stub (at
  most 300 characters), its tool results cut to 500 characters each, and
  Blip's answer. A digest Blip answered with `[nothing to tell]` costs
  later requests nothing (section 5.3). So at hourly digests the growth
  per day is a few kilobytes of stubs plus what Blip actually told the
  owner, not the 100k characters the full texts would add.

## 4. The daily review

### 4.1 When

The review fires once a day, around 09:00 at the owner's UTC offset.
The hub has no time zone database, and AGENTS.md says not to add one
unasked, so it doesn't know when 09:00 in America/Chicago is. It doesn't
need to: the Settings page sends the browser's current UTC offset with
every Save (section 2.2), and the review is armed as a 24-hour repeat
whose first firing is the next 09:00 at that offset. This is how
schedules already work (the browser turns local times into UTC), and it
drifts by an hour at daylight saving changes, as schedules do. Saving
Settings afterwards sends the new offset and re-arms the review (section
2.3, row 5).

`Ambient.Rules.next_review(now_ms, offset_minutes)` is the first instant
after `now_ms` whose UTC time plus the offset is 09:00. The review
timer's task input is `%{"job" => "review", "first_at" => ms, "every_ms"
=> 86_400_000}`, the digest timer's shape, and it waits with the same
`next_firing/3`, so a review missed while the hub was down fires once
when it comes back and then keeps to the grid.

### 4.2 Which threads

`Ambient.Rules.review(board, now, opts)` with `opts = %{quiet_after:
seconds, again_after: seconds}` picks the board entries that:

- are in state `:quiet`, `:failed` or `:waiting` (not running, not asking
  Blip, not unread, not idle or resolved), and
- were last touched more than `quiet_after` ago, where the last touch is
  the latest of `State.last_activity/1` and the `passed_at` of the
  thread's open questions, and
- haven't been in a review since then: `reviewed_at` is nil, or before
  the last touch, or more than `again_after` ago.

`quiet_after` is the same `quiet_after_hours` (72) that makes a thread
quiet, so the review covers the home page's Gone quiet list, and the
failed and waiting threads that have sat as long. Unread threads are left
out: finished work isn't unresolved, and the digest covers it.
`again_after` is `config :photon, Photon.Ambient, review_again_days: 7`.

They are ordered by last touch, oldest first, and cut at 10, with how
many more. None: the review is skipped (outcome `"skipped_nothing"`), no
message, no model run.

`Ambient.fire_tx(tx, "review", firing)` follows the digest's steps 1 to
3 (off, consent, a review still queued), then reads the board, applies
`review/3`, and for each stopped (`:quiet`) row it shows reads the
thread's latest answer (`Threads.latest_answer/1`, at most 10 reads) for
the text; failed and waiting lines use the board's detail. Its
`quiet_after` is `Threads.quiet_after/0`, the seconds the threads' state
uses. It posts one
signal with its older stub, sets `reviewed_at` to now on the threads it
showed (`Threads.mark_reviewed_tx(tx, ids, now)`, which announces
`{:projects_changed, project_id}` once per project), and writes
`"last_review"` on the doc. Threads past the cut keep their
`reviewed_at` and come in the next review. If ambient mode is turned off
while the review still waits in Blip's inbox, the off commit clears
those marks again (section 2.3).

`reviewed_at` is a fact (when a review listed the thread), not a state:
`State.of/3` doesn't read it, and a thread raised in a review stays in
Gone quiet until the owner does something about it.

### 4.3 What Blip can do

Every thread in a review is in a state that wants the owner's decision: a
run the owner or Blip stopped, a failure, a question or an answer that
asked them something. So in a review run Blip:

- may read anything (`read_thread`, `read_project`, the files) and run
  read-only checks on machines, to say where each thread stands
- may update its memory
- tells the owner, in a few lines, which threads look worth picking up
  and which look finished with. It offers to pick up the first kind, and
  for the second tells the owner they can press Resolve on the thread's
  row on Home or on the thread's page
- may not message, start or stop threads, or change projects or
  schedules: the tools refuse (section 5.2). Waking a stopped thread on
  its own would undo the owner's Stop.

When the owner answers ("pick up the pump one"), that is a run they
typed into, and Blip's `message_thread` works as usual. Blip has no tool
to resolve a thread; closing one stays the owner's button.

### 4.4 What Blip reads

`Photon.Ambient.Text.review/3`:

```
[Daily review] 3 threads have sat untouched for 3 days or more:
- Garden / "Fix the pump" (c_123): stopped 4 days ago. It last said: Draining the tank first.
- House / "Gutters" (c_456): failed 5 days ago: the ladder machine is offline.
- House / "Paint" (c_789): waiting on the user for 3 days: Which white, Chalk or Linen?
...and 2 more; list_threads with state quiet shows them.
```

A waiting thread shows its open question (Blip's wording when it asked
in its own words), or its run's note when its answer asked. Lines are
cut to 400 characters. "4 days ago" is whole days, or hours under a day,
or minutes under an hour (with `PHOTON_QUIET_AFTER_HOURS=0`). The count
in the header is every thread due, shown or not; with `quiet_after`
under an hour the header leaves out "for ... or more". `Text.review/3`
takes the review, the latest answers by thread ID (a stopped thread's
line quotes it) and the time.

The ref:

```elixir
%{
  "kind" => "review",
  "key" => "review:...",
  "items" => [%{"thread_id", "title", "project_id", "slug", "project", "state", "since"}],
  "more" => 2
}
```

with `"state"` one of `"quiet"`, `"failed"`, `"waiting"` and `"since"`
the last touch as ISO 8601. The older stub: `[Daily review delivered
<time>: Garden / "Fix the pump", House / "Gutters", House / "Paint".]`,
with the same `"drop_if_answer"`.

## 5. Blip's side

### 5.1 Who asked

`Photon.Assistant.Origin.of/1` reads two new ref kinds in `"signal"`
sources. After the existing rows of its table:

| Sources include | `by` | `id` |
|---|---|---|
| `"signal"` with a `"digest"` ref | `"follow_up"` | `"digest"` |
| `"signal"` with a `"review"` ref | `"follow_up"` | `"review"` |

A run has one signal message (follow-ups are placed one at a time, and a
digest or review ref never merges with another kind), so these never
compete with the question and update rows except through an owner steer,
which wins as today (`"owner"`).

`Origin.t` gains `report_only?`: true when the run carries a digest or
review ref and the owner hasn't typed into it (`owner_wrote?` false). An
`"answer"` source doesn't lift it, as it doesn't lift `restricted?`.

`Activity.Rules.origin_label/2` reads `"follow_up"` with `origin_id`
`"digest"` as "Blip's follow-up on the digest", and `"review"` as
"Blip's follow-up on the daily review". The activity page's "Blip's
follow-ups" filter already includes them.

### 5.2 What a digest or review run may not do

`Assistant.may_act_tx/3` gains one clause after the question check: in a
`report_only?` run, every kind (`:change`, `:start`, `:schedule_work`) is
refused with `Origin.report_only_message/0`:

> A digest or review run only reports. Tell the user what you'd do, and
> do it when they say so.

So `start_project`, `start_thread`, `message_thread`, `stop_thread`,
`write_context_file`, `edit_context_file`, `schedule`, `cancel_schedule`
and `set_project_skill` refuse in it. The read tools, the machine tools,
`update_memory`, `load_skill`, `list_schedules`, `list_skills`,
`answer_question` and `ask_owner` stay available (the last two can't do
anything here: such a run carries no question).

Machine tools stay because a review is better for a look at the machine
("is the backup still running on kepler?"), as Blip's morning schedules
do today; a command can change anything, as it can in any of Blip's
unattended runs, and that is no different from step 4.

This replaces any need for a count here: a report-only run starts
nothing, so it doesn't touch the unattended limit, and nothing it does
can produce a digest item.

In quiet mode no run carries a digest or review ref, so this clause
never fires and Blip's tool list is step 4's.

### 5.3 What Blip's later requests carry

`Photon.Durable.Context` sends every entry since the last reset, and
shortens only older tool results (to 4,000 code points). Blip's
conversation is cleared only when the owner presses Fresh context. Left
alone, hourly digests would add tens of thousands of characters a day to
every later request, and within days Blip's requests would hit the
model's context limit or eat the plan.

So `Durable.Context` gains one rule, pure and generic (it knows nothing
about digests): for each earlier run (before the current run's cut, as
today) whose first user entry's source has an `"older"` map,

- when no other user entry joined the run (no owner steer) and the run's
  final answer, trimmed, lowercased and with a trailing `.` removed,
  equals `"drop_if_answer"` treated the same way, the whole run is left
  out: the user entry, its tool calls and results, and the answer
- otherwise the user entry is sent as `"older"["text"]`, and the run's
  tool results are cut to 500 code points (the same head-and-tail cut,
  with its marker) instead of 4,000

The current run is untouched, so Blip reads the full digest while it
answers it. The cut moves only when a new run starts, so requests within
a run still share a stable prefix for prompt caching. An entry without
`"older"` is treated as today. The moduledoc gains a paragraph for the
rule.

### 5.4 Nothing to tell

Not every digest or review deserves the owner's attention, and a bubble
saying "nothing to report" every three hours would be worse than
silence. Blip's prompt tells it to answer exactly `[nothing to tell]`
then. `Photon.Transcript.nothing_to_tell?(text)` is true when the trimmed
text, lowercased, with a trailing `.` removed, is `[nothing to tell]`.

- `Assistant.Notice`: an answer for which it is true makes no notice.
- `Assistant.settled_tx/3`: no `kind: "message"` activity row for it.
- Blip's panel draws nothing for it: the stream item is an empty
  `<div id="message-<entry id>" class="hidden">`, so the stream keeps one
  element per entry. A quiet digest leaves only its own collapsed line
  (section 7.4).

The check doesn't look at who asked: the owner never gets that answer
from a run they typed into, and if they do, an empty reply is fine.

### 5.5 Blip's prompt

`Photon.Assistant.Prompt.system_prompt/5` takes a fifth argument,
`ambient?` (`Assistant.system_prompt/1` passes `Signals.mode() ==
:ambient`). With it false the prompt is exactly step 4's; with it true it
adds an `## Ambient mode` section after `## Projects and threads`. The
setting changes rarely, so the provider's prompt cache stays warm between
requests.

The section, when on:

```
## Ambient mode

- The user turned on ambient mode: you follow along with their projects and speak up on your own.
- A message starting with "[Digest]" lists what changed since the last digest. "New to the user" is work that finished while they weren't looking and schedules that stopped. "Already seen by the user, or done by them" is for you to keep track of; mention it only when it matters to something new. Tell them what's worth their attention in a few lines, by project and thread, and leave out what isn't. If nothing is, answer with just [nothing to tell] and they won't be disturbed.
- A message starting with "[Daily review]" lists threads left stopped, failed or waiting on the user for days. Say in a few lines which look worth picking up and which look finished with. Offer to pick up the first kind; for the second, tell them they can press Resolve on the thread on Home or on its page. If none needs anything, answer with just [nothing to tell].
- In a run started by a digest or a review you can read anything and check machines, but you can't start, message or stop threads, or change projects or schedules; the tools refuse. Do what the user asks once they answer.
- Earlier digests and reviews show as one-line notes, and ones you had nothing to tell about are left out.
```

## 6. Timers and restarts

`Photon.Ambient.Timer` implements `Photon.Durable.TaskKind` for the
`"ambient"` kind (registered in `config/config.exs` and `config/test.exs`
under `Photon.Durable`'s `kinds`). It is the routine's shape, reused
rather than reinvented, and the same for both jobs:

- `step("start", task, runtime)`: wait until `first_at`, phase
  `"fire"`, checkpoint `%{"next_at" => first_at, "runs" => 0}`.
- `step("fire", task, runtime)`: read consent and the clock, then
  `Runtime.commit(runtime, fn tx -> ... end)` runs `Ambient.fire_tx/3`
  and returns the next wait, `{:wait, %{"until" => next}, "fire",
  %{"next_at" => next, "runs" => runs + 1}}`, with `next` from
  `next_firing/3` over the input's `every_ms`.
- `on_fail/3`: writes `"stopped"` on the doc when the task is still the
  doc's (`digest_task_id` or `review_task_id`), and announces. No retry:
  a firing that crashed would crash the same way, and saving the
  settings arms a new timer. It is total (a missing doc writes nothing).
- No `on_abort/2`: a retired timer leaves nothing to undo.

What survives what:

- Hub restart: the doc, the timers and the items are rows. A timer whose
  time passed while the hub was down fires once when the Scheduler
  starts, then keeps to its interval.
- A step crash or a Scheduler restart mid-firing: the step runs again;
  its first try's commit either landed (and the rerun is a stale step the
  fence ignores) or didn't (and the rerun does it). The signal's key is
  the task and run count, so a rerun can't post a second message.
- A commit that collected an item rolled back: its item went with it.
- Settings saved but the hub died before `configure/1`'s commit: the file
  has the other settings and the doc has the old ambient ones; the page
  shows what the doc says, and the next Save fixes it. No timer runs
  against a setting that says off, since both live in the doc's commit.

No process is added (rules 3, 31, 89): the timers are durable tasks the
Scheduler already runs, the items are rows, the doc is a row.

## 7. UI

### 7.1 Routes

None new. The home page links to `/settings`, which exists. Nothing in
this step links to a route that doesn't exist yet.

### 7.2 The Settings page

Section 2.2 has the section's elements and words. Behaviour:

- `mount/3` reads `Ambient.status/0` and subscribes with
  `Ambient.subscribe/0` and `Projects.subscribe/0`; the form's starting
  values merge `AmbientText.form_values(status)` (`"ambient"`,
  `"ambient_every"`) into the settings map.
- `"save"`: `Settings.save(params)`, then `Ambient.configure(params)`,
  then the form is rebuilt from
  `Map.merge(settings, AmbientText.form_values(Ambient.status()))`, then
  the flash as today ("Saved. The next message uses these settings.").
- `"digest_now"` and `"review_now"` (scripted model only) call
  `Ambient.digest_now/0` and `review_now/0` and flash
  `AmbientText.ran(job, result)` (the `%{at:, outcome:, count:}` they
  return): "Sent Blip a digest of 3 changes.",
  "Nothing new since the last digest.", "Blip still has the last digest
  waiting.", "Sent Blip a review of 2 threads.", "No threads need a
  review.", "Turn on ambient mode first."
- `{:ambient_changed}` (every collected item, firing and configure) and
  `{:projects_changed, _}` (a thread opened or resolved changes what is
  new) re-read the status, so the counts and the last outcomes follow
  along. Every callback stays under 15 lines (rule 30).

`Ambient.status/0` returns `%{on?:, every_minutes:, next_digest_at:,
next_review_at:, pending: %{new: n, smaller: n}, last_digest:,
last_review:, stopped:, consent?:, scripted?:}`, with `last_digest` and
`last_review` as `%{at: DateTime.t(), outcome:, count:}` (nil before
the first) and `stopped` as `%{job:, reason:}` or nil. `consent?` is the
Settings consent alone, without the scripted model. `pending` comes from
`Ambient.Rules.digest/3` over the pending items and the board (section
3.3 step 5), so opening a finished thread moves it from "changes
waiting" to "smaller", and the page never claims a change that "Send a
digest now" then calls nothing new.

### 7.3 The home page

`PhotonWeb.HomeLive` adds only warnings and marks, no status line:

- When ambient mode is on, the last digest or review was skipped for
  consent and Settings still doesn't give it, a line `#ambient-consent`
  in the warn colour under the header: "Digests and reviews are
  skipping: schedules can't use your plan while you're away." with a
  link `#ambient-settings` ("Settings", to `/settings`). Without the
  consent check, a review skipped for consent would keep the warning up
  for a day after the owner gave it (`AmbientText.skipping?/1`).
- When a timer failed, `#ambient-stopped`: "Ambient mode stopped after
  an error. Save settings to start it again." with the same link
  (`AmbientText.home_stopped?/1`). At most one of the two lines shows, the
  stopped one first, so the link's ID stays unique; the Save it asks for
  then shows the consent line if that still applies.
- The Failed, Waiting on you (thread rows) and Gone quiet rows of a thread
  raised in a review since its last touch get a line `#<row id>-reviewed`
  with a `hero-eye-micro` icon: "In Blip's review <local_time>"
  (`#<row id>-reviewed-at`). `AmbientText.reviewed?(entry)` decides it
  from `reviewed_at` and the last touch.
- It reads `Ambient.status/0` on mount and on `{:ambient_changed}`
  (`Ambient.subscribe/0`). The board's `{:projects_changed, _}` re-read
  already covers `reviewed_at`.

### 7.4 Blip's panel

`PhotonWeb.ConversationComponents`:

- A signal message whose ref is a digest or a review renders as
  `ambient_message/1` instead of the thread lines, `#message-<entry id>`:
  one muted line with an icon (`hero-newspaper-micro` for a digest,
  `hero-sun-micro` for a review) and the heading
  `#message-<entry id>-heading`: "Digest: 3 new, 6 smaller" or "Daily
  review: 2 threads". It is a `<details>`; opened, it lists one line per
  item, `#message-<entry id>-item-<n>`: the project and thread (linked,
  as the signal lines are), then "finished", "stopped after an error",
  "context file notes.md", "started", "resolved" for a digest, or
  "stopped 4 days ago", "failed 5 days ago", "waiting on you for 3 days"
  for a review. The owner reads Blip's reply, not the raw digest, unless
  they open it.
- `Photon.Transcript.ambient_lines(ref, titles)` (pure) reads the ref
  and names each thread with `Transcript.title(titles, id, item["title"])`,
  so a digest written before the thread got its title shows the current
  one. `Transcript.thread_ids/1` (through `source_threads/1`) also
  collects the `"thread_id"`s under a `"digest"` or `"review"` ref's
  `"items"`, so `ConversationView` reads their titles with the others.
- Blip's `[nothing to tell]` answer renders as section 5.4's empty
  element.
- A queued digest or review in Blip's inbox shows a chip: "Digest: 3 new
  changes" or "Daily review: 2 threads" (`queued_text/1`). It names no
  thread, so it needs no titles.

`Transcript.typed/2` already shows a signal message as nothing typed.

### 7.5 The activity page

No change to `ActivityLive` itself: rows from digest and review runs read
"Blip's follow-up on the digest" or "... on the daily review" through
`Activity.Rules.origin_label/2` (section 5.1). A test covers it on the
page.

## 8. The scripted models

### 8.1 Blip (`Photon.Assistant.MockAmbient`)

A new pure module, as `MockCoordinator` was for step 4.
`MockCoordinator.unasked/2` tries `MockAmbient.unasked/2` first, and
`MockScript`'s help text adds `MockAmbient.help/0`.

Messages the owner didn't type (the last user message's text parts):

- A `[Digest]` part: the memory lines `- ignore: <word>` (from the
  request's system text, as the question script reads memory) name words
  to ignore. Each line under "New to the user:" that contains none of
  them, ignoring case, becomes a reply line: `Fix the pump in Garden
  finished: Replaced the fuse...` or `The schedule "check the gutters" in
  Garden stopped after an error.` Lines under "Already seen" are left
  out. No lines left: `[nothing to tell]`.
- A `[Daily review]` part: the lines left after the same filter become
  `These have sat for a while:`, then one line each, `- Fix the pump in
  Garden (c_123), stopped 4 days ago.`, then `Say "tell <id>: ..." to
  pick one up, or press Resolve on it on Home to close it.` The scripted
  reply shows IDs so the demo can name them; the real prompt tells Blip
  not to. No lines left: `[nothing to tell]`.

### 8.2 Threads

No change. The demo's threads use the step 2 to 4 phrasings (`on local:
$ <command>`, `fail: <reason>`).

### 8.3 `PHOTON_QUIET_AFTER_HOURS`

`config/runtime.exs`, in the dev block next to `PHOTON_MOCK_MODEL`:
`PHOTON_QUIET_AFTER_HOURS=<n>` sets `config :photon, Photon.Threads,
quiet_after_hours: n` (a whole number, 0 or more; anything else is
ignored). With 0, a stopped or failed thread counts as untouched long
enough once a second has passed, so the review has something to show in
a demo.

### 8.4 Trying it

Start the hub with `PHOTON_MOCK_MODEL=1 PHOTON_QUIET_AFTER_HOURS=0` and
its local node.

1. Open Settings. Under Ambient mode, tick "Let Blip follow along and
   speak up" and press Save settings. The section shows "Next digest
   around ...; next review ..." and "Nothing new yet."
2. Press "+" next to Projects in the sidebar, type "Look after the
   garden" under Purpose and "Garden" under Name, and press Start
   project. On Garden's page press New thread, type `on local: $ sleep
   30; echo pump fixed` and send it. Go Home straight away, without
   opening the thread again. After about 30 seconds the thread is listed
   under Finished.
3. Open Settings: it says "1 change waiting, and 2 smaller ones." (the
   new project and the thread's start ride along). Press "Send a digest
   now". The flash says "Sent Blip a digest of 3 changes." (the count is
   new plus smaller, as `"last_digest"` records it). Blip's bubble says
   the thread in Garden finished. Open Blip's panel: above the reply is
   a faint "Digest: 1 new" line; tap it to see the thread.
4. Press "Send a digest now" again: "Nothing new since the last digest."
   No new message in Blip's panel.
5. In Blip's panel, send `remember ignore: pump`. On Garden's page press
   New thread and send `on local: $ sleep 30; echo pump checked`, then go
   Home and wait for it under Finished. In Settings press "Send a digest
   now": Blip's panel shows only a new "Digest: 1 new" line, with no
   reply under it, and no bubble appears.
6. On Garden's page press New thread and send `on local: $ sleep 600`;
   on the thread's page press Stop. Press New thread again and send
   `fail: the ladder is missing`. Go Home: the first is under Gone quiet,
   the second under Failed.
7. In Settings, press "Run the review now". Blip lists both threads with
   their IDs. Home now shows "In Blip's review" on both rows.
8. On Home, press Resolve on the stopped thread's row under Gone quiet.
   It leaves the list.
9. Open Activity: "Told you: ..." rows from "Blip's follow-up on the
   digest" and "Blip's follow-up on the daily review".
10. In Settings, untick Ambient mode and save. The status block goes,
    and a thread that finishes now never reaches a digest.

The end-to-end test (section 11.4) walks steps 1 to 4, 6, 7 and 10.

## 9. Events

Every announcement is a hint to re-read committed state, sent after the
commit with `Tx.announce/3`, through `Photon.Events`.

| Topic | Message | Sent when | Who listens |
|---|---|---|---|
| `"ambient"` (new, `Signals.ambient_topic/0`, `Ambient.subscribe/0`) | `{:ambient_changed}` | `configure/1`, every firing (timer or now), a timer's `on_fail/3`, `Signals.collect_tx/2` when it inserts | `SettingsLive`, `HomeLive` |
| `"projects"` (existing) | `{:projects_changed, project_id}` | also `Threads.mark_reviewed_tx/3` and `unmark_reviewed_tx/2`, once per project | as today, and `SettingsLive` |
| `"durable:" <> blip` (existing) | `{:durable, ...}` | a digest or review posted or withdrawn | `BlipLive` |
| `"activity"` (existing) | `{:activity_added, id}` | as today, for digest and review runs' calls and messages | `ActivityLive` |

## 10. Module plan

Layers per the brief. "Boundary" is the `use Boundary` declaration. Every
public function gets a `@spec`, every struct a `@type t`. No new
processes and no new registered names.

### 10.1 apps/core and apps/node

No changes.

### 10.2 apps/hub: the harness

| Module | Layer | Boundary | Notes |
|---|---|---|---|
| `Photon.Durable.Context` | core | unchanged | The `"older"` rule of section 5.3. Moduledoc paragraph. |

### 10.3 apps/hub: signals and the mode

| Module | Layer | Boundary | Notes |
|---|---|---|---|
| `Photon.Signals` | boundary (API, no process) | deps add `Photon.Repo`, `Ecto`; exports add `DigestItem` | `mode/0` and `mode_tx/1` read the doc; `ambient_doc/0`, `ambient_doc_tx/1`, `put_ambient_doc_tx/2`; `ambient_topic/0`; `collect_tx/2` (total, announces on insert), `pending_tx/1`, `pending/0`, `drop_items_tx/2` (IDs or `:all`); `queued_ambient?/2`; `withdraw_ambient_tx/1` (returns the withdrawn refs); `post_tx/2` takes an optional `older:`. Moduledoc: the mode, the items, who writes the doc. |
| `Photon.Signals.DigestItem` | data (Ecto schema) | `use Boundary, type: :strict, deps: [Ecto]` | Section 3.2. |
| `Photon.Signals.Rules` | core | unchanged | `mode` type adds `:ambient`; `thread_update/2`'s `:ambient` clause returns `:digest` for an owner's finished run (section 3.2); `ambient_kind/1` (a source's `"digest"` or `"review"` ref kind, or nil), for `queued_ambient?/2` and `withdraw_ambient_tx/1`. |
| `Photon.Projects` | boundary | deps add `Photon.Signals` | Collects `"file_written"`, `"project_created"`, `"purpose_changed"` (section 3.2). |
| `Photon.Threads` | boundary | unchanged | `settled_tx/3` reads `Signals.mode_tx/1` and collects `"finished"`; `start/2` collects `"thread_started"`, `resolve/1` collects `"resolved"`. |
| `Photon.Schedules` | boundary | deps add `Photon.Signals` | `Routine.on_fail/3` collects `"schedule_stopped"`. |

### 10.4 apps/hub: the ambient context

| Module | Layer | Boundary | Notes |
|---|---|---|---|
| `Photon.Ambient` | boundary (API, no process) | `use Boundary, deps: [Photon.Durable, Photon.Events, Photon.Projects, Photon.Schedules, Photon.Settings, Photon.Signals, Photon.Threads, PhotonCore], exports: []` | `status/0`, `subscribe/0`, `configure/1`, `digest_now/0`, `review_now/0`, `fire_tx/3` (`@doc false`, for the timer and tests, as `Routine.fire_tx/3` is), `every_options/0` (the three intervals). Moduledoc: the doc, the timers, collection, the fence, what turning off cancels, the cost bounds. |
| `Photon.Ambient.Rules` | core | `use Boundary, type: :strict, deps: [Photon.Threads]` (it reaches `Threads.State` through the parent's export, as `Assistant.Readout` does) | `config/2` (`%{on?:, every_minutes:, offset_minutes:}`), `changes/3` (`%{digest: action, review: action, clear?:, turned_on?:}`, each action `:keep`, `:arm`, `:rearm` (retire the live one, then arm) or `:retire`), `next_firing/3`, `next_review/2`, `digest/3` (places: `%{prompts: %{id => prompt}, projects: [project]}`), `review/3` (`%{rows:, more:, quiet_after:}`), `last_touch/1`, `firing/1` (the skip decisions of section 3.3 steps 1 to 3 from `%{on?:, allowed?:, queued?:}`: `:go` or `{:skip, outcome}`), `every_options/0`. Takes the time as an argument. |
| `Photon.Ambient.Text` | core | `use Boundary, type: :strict, deps: []` | `digest/2` (the digest and the doc), `digest_ref/2` (the digest and the key), `digest_older/2`, `review/3` (the review, the latest answers by thread ID, now), `review_ref/2`, `review_older/2`, `ago/2` (sections 3.4, 4.4). |
| `Photon.Ambient.Timer` | worker logic (task kind) | inside `Photon.Ambient` | Section 6; `task/2` (a timer's task attributes for a job and `%{first_at:, every_ms:, version:}`, which `configure/1` and the tests use). Its `on_fail/3` writes through `Ambient.stopped_tx/4` (`@doc false`). |
| `Photon.Threads` | boundary | unchanged | `mark_reviewed_tx/3`, `unmark_reviewed_tx/2`, `quiet_after/0` (the quiet threshold in seconds, which the state and the review share). |
| `Photon.Threads.Thread` | data | unchanged | `reviewed_at`. |

### 10.5 apps/hub: Blip and the activity log

| Module | Layer | Boundary | Notes |
|---|---|---|---|
| `Photon.Assistant` | boundary | unchanged (already depends on `Photon.Signals` and `Photon.Threads`) | `may_act_tx/3` with `report_only?`; `system_prompt/1` passes the mode; `settled_tx/3` skips `[nothing to tell]`. |
| `Photon.Assistant.Origin` | core | unchanged | Digest and review refs (section 5.1), `report_only?`, `report_only_message/0`. |
| `Photon.Assistant.Prompt` | core | unchanged | `system_prompt/5` (section 5.5). |
| `Photon.Assistant.Notice` | core | unchanged | No notice for `[nothing to tell]`. |
| `Photon.Assistant.MockAmbient` | core | `use Boundary, type: :strict, deps: [PhotonCore]` | Section 8.1: `unasked/2`, `help/0`. |
| `Photon.Assistant.MockCoordinator` | core | deps add `Photon.Assistant.MockAmbient` | `unasked/2` tries `MockAmbient` first. |
| `Photon.Assistant.MockScript` | core | deps add `Photon.Assistant.MockAmbient` | Help text. |
| `Photon.Activity.Rules` | core | unchanged | `origin_label/2` for `"digest"` and `"review"`. |
| `Photon.Transcript` | core | unchanged | `nothing_to_tell?/1`, `ambient_lines/2`, `source_threads/1` reads digest and review items. |
| `Photon` | root | exports add `Ambient` | Moduledoc names `Photon.Ambient` and its pure modules. |

### 10.6 apps/hub: web

| Module | Layer | Notes |
|---|---|---|
| `PhotonWeb.SettingsLive` | server (LiveView) | Section 7.2, and the `.UtcOffset` colocated hook. |
| `PhotonWeb.HomeLive` | server | Section 7.3. |
| `PhotonWeb.AmbientText` | functional core (web formatting) | The hint words, `form_values/1`, the interval labels, `next/1`, `last/2` (a last outcome as words), `pending/1`, `ran/2` (the flashes), `needs_consent?/1`, `reviewed?/1`, and Home's `skipping?/1`, `skipping/0`, `home_stopped?/1`, `home_stopped/0`. |
| `PhotonWeb.ConversationComponents` | boundary (UI components) | `ambient_message/1`, the empty nothing-to-tell element, the queued chip. |

### 10.7 Credo, Boundary and deps

`apps/hub/.credo.exs`:

- `FunctionalCore` `core_modules`: add `Photon.Ambient.Rules`,
  `Photon.Ambient.Text`, `Photon.Signals.DigestItem`,
  `Photon.Assistant.MockAmbient`, `PhotonWeb.AmbientText`.
- `ProcessNameOwnership` `api_modules`: add `"Photon.Ambient"`. No new
  `names`.
- No `PreferCall`, `NoSleep` or `DiscardNeedsReason` entries.

No new Hex dependency; `mix.exs` and `mix.lock` don't change.

`test/support/data_case.ex`: `digest_items` first in `@tables`.

## 11. Test plan

As in the earlier steps: core logic in `test/core` with plain inputs
(rule 52); boundary tests through the public API with `assert_receive`,
`start_supervised!/1` and no sleeping (rule 55), without retesting core
tables (rule 53); LiveView tests through element IDs, never raw HTML.
Tests turn ambient mode on through `Ambient.configure/1` (or, before M5
exists, `Signals.put_ambient_doc_tx/2` in a commit). A test that needs
a thread to count as untouched backdates `last_run_ended_at` and
`active_at` with `Repo.update_all` rather than relying on
`quiet_after_hours: 0`, because `State.quiet?/3` compares whole seconds
with `>`, and a thread that ended in the same second isn't quiet yet.

### 11.1 Core (`test/core`)

- `durable/context_test.exs`: an earlier run started by an entry with
  `"older"` is sent as its stub, with its tool results cut to 500 code
  points; one whose answer is `[nothing to tell]` (also `[Nothing to
  tell].`) is left out whole, tool calls and results included; one an
  owner steer joined is kept as a stub, not dropped; the current run is
  never touched; entries without `"older"` are as before.
- `signals/rules_test.exs`: every cell of `thread_update/2` in
  `:ambient` (the owner's finished run is `:digest`; with `ended?:
  false` it is nil; failed, asking and Blip's cells as in `:quiet`; a
  stop nil); `ambient_kind/1`.
- `ambient/rules_test.exs`:
  - `config/2`: each field's coercion; junk keeping the old value; a
    missing `"ambient"` keeping `"on"` true and keeping it false; an
    explicit `"false"` turning it off; a missing `"utc_offset"` keeping
    the doc's; the defaults.
  - `changes/3`: every row of section 2.3's table, and params with no
    `"ambient"` key over an on doc (nothing changes).
  - `next_review/2`: before and after today's 09:00 at offset 0, -300
    and +330; an offset that puts 09:00 local on the previous UTC day.
  - `next_firing/3`: on time and after a long gap (one firing, then the
    grid).
  - `digest/3`: an unread thread's `"finished"` item is new; a seen,
    resolved or written-to-again one is smaller; a gone thread's item is
    in `gone`; one `"finished"` item per thread (the newest); a schedule
    item new while the schedule exists, gone after; `"file_written"`
    folded per project and file; `"resolved"` gone after a reopen; only
    smaller items gives no new rows; the 20 and 15 cuts and both more
    counts; the snapshot counts.
  - `review/3`: each state in and out (quiet, failed, waiting in;
    running, asking, unread, idle out); the 72-hour edge; a question's
    `passed_at` as the last touch; `reviewed_at` nil, before the touch,
    after it, and older than `again_after`; order and the 10-row cut.
  - `firing/1`: off, no consent, queued, in that order.
- `ambient/text_test.exs`: both texts, refs and older stubs from built
  rows; the cuts (280, 400, 6,000, 300 for the stub); the "Already seen"
  block left out when empty; "Since ambient mode was turned on"; the
  window when a skipped firing fell between two sent digests (it names
  `last_sent_at`, not the skip); the "Now" line with zeros left out and
  all zero; "4 days" and "5 hours".
- `assistant/origin_test.exs`: a digest ref is `"follow_up"`/`"digest"`
  with `report_only?`; a review ref likewise; with a `"user"` steer
  `"owner"` and not report-only; with an `"answer"` source still
  report-only.
- `assistant/mock_ambient_test.exs`: a digest with two new lines, with
  one ignored, with all ignored (`[nothing to tell]`), with only smaller
  lines (`[nothing to tell]`); a review the same way, with the IDs and
  the Resolve hint.
- `assistant/prompt_test.exs`: the ambient section only with `ambient?`
  true; with it false the prompt equals step 4's.
- `assistant/notice_test.exs`: `[nothing to tell]` (also with a period
  and in capitals) makes no notice; other answers still do.
- `activity/rules_test.exs`: `origin_label/2` for `"digest"` and
  `"review"`.
- `transcript_test.exs`: `nothing_to_tell?/1`; `ambient_lines/2` for a
  digest and a review ref, with a title from `titles` winning over the
  stored one, and garbage refs; `thread_ids/1` of a digest and a review
  signal entry lists the items' threads.
- `test/web/ambient_text_test.exs`: each outcome's words, the flashes,
  the pending words for each mix of new and smaller, `needs_consent?/1`
  (on with consent off and not on the scripted model; off; consent on),
  `reviewed?/1`.

### 11.2 Boundary (`test/boundary`)

- `signals_test.exs` (`@tag :durable`, scripted thread): with ambient
  on, an owner thread that finishes makes one `digest_items` row and no
  signal; a run that answers two queued inputs makes one; a Blip-started
  thread posts its update and makes no item; a failure posts at once and
  makes no item; with ambient off nothing is collected; the same key
  twice makes one row; an insert announces `{:ambient_changed}`;
  `withdraw_ambient_tx/1` withdraws a queued digest, returns its ref and
  leaves a queued update; `post_tx/2` with `older:` stores it in the
  source.
- `projects_test.exs`: with ambient on, `create/1`, `update/2`,
  `create_file/2`, `save_file/4`, `delete_file/2` and a thread's
  `write_file_tx/5` each collect their item; Blip's `write_file_tx/5`
  (writer `"blip"`) and `create_tx/2` collect none; with it off, none.
- `threads_test.exs`: `start/2` and `resolve/1` collect with ambient on;
  `mark_reviewed_tx/3` and `unmark_reviewed_tx/2` set and clear the
  column and announce once per project.
- `schedules_test.exs`: a routine that fails with ambient on collects a
  `"schedule_stopped"` item; with it off, none.
- `ambient_test.exs` (`@tag :durable`):
  - `configure/1` on arms two `"ambient"` tasks and stores their IDs; the
    status has both next times; a second identical save changes nothing;
    a save with no `"ambient"` key keeps it on and changes no timer; a new
    interval replaces only the digest timer and a new offset only the
    review timer; off retires both (their tasks end `"aborted"`), deletes
    pending items and withdraws a queued digest (Blip parked on a command
    that never finishes, as `signals_test.exs` does);
    `{:ambient_changed}` is announced.
  - A queued review, then off: the review is withdrawn and its threads'
    `reviewed_at` is nil again.
  - `digest_now/0`: with nothing pending, `"skipped_nothing"` and no
    submission; with an unread owner thread's item, one `[Digest]`
    submission in Blip's conversation with the ref and the older stub,
    the item deleted, `"sent"`, `"last_sent_at"` written; a seen thread's
    item alone is `"skipped_nothing"` and stays as a smaller item; with a
    new item and a smaller one, both go in the digest and both are
    deleted; a second digest while the first is queued is
    `"skipped_queued"` and the items stay; off, `"off"`.
  - `status/0`'s pending counts: an unread thread's item counts as new;
    after `Threads.mark_seen/1` it counts as smaller.
  - `fire_tx/3` with `allowed?: false`: `"skipped_consent"`, items stay,
    `"last_digest"` says so, `"last_sent_at"` doesn't move.
  - The timer: a digest timer created directly with
    `Ambient.Timer.task/2` and a `first_at` already past (and its ID
    written on the doc) is fired by the Scheduler, and a digest is
    posted; after a durable restart (stop and start the durable
    children, as `durable_lifecycle_test.exs` does) a timer waiting for
    a later time is still waiting; after `configure/1` turns ambient
    mode off, calling the old task's `step("fire", task, runtime)` with
    the task as it was read before returns `:ignored` and posts nothing
    (the fence).
  - `review_now/0`: a thread stopped and backdated past 72 hours, a
    failed one and a waiting one (both backdated) appear, `reviewed_at`
    is set, a second review the same day is `"skipped_nothing"`, and one
    with `reviewed_at` older than seven days includes it again; a recent
    stopped thread and an unread one are left out.
  - A timer whose `fire_tx/3` raises fails the task and writes
    `"stopped"` on the doc; the next `configure/1` re-arms.
- `assistant_coordinator_tools_test.exs` (`@tag :durable`): in a run
  started by a posted digest signal, `start_thread`, `message_thread`,
  `stop_thread`, `write_context_file` and `schedule` refuse with the
  report-only message and change nothing, while `read_thread` and
  `update_memory` work; with an owner steer placed after a tool round,
  `message_thread` works.
- `activity_test.exs` (`@tag :durable`): a digest run's reply records a
  `"message"` row with origin `"follow_up"` and `origin_id` `"digest"`;
  a `read_thread` call in a review run records origin
  `"follow_up"`/`"review"`. (M7 adds: a `[nothing to tell]` reply records
  none.)
- `assistant_test.exs`: the prompt carries the ambient section when the
  mode is on and not when it is off; the tool list is unchanged.

### 11.3 LiveView (`test/web/live`)

- `settings_live_test.exs`: `#ambient` shows with the scripted model;
  ticking `#settings_ambient` and saving turns it on (`Ambient.status/0`)
  and shows `#ambient-state` with `#ambient-next`; after that save the
  box is still ticked, and a second save that changes only the user's
  name keeps ambient mode on; a save with no `ambient` key in the params
  (as when the section is hidden) keeps it on; changing
  `#settings_ambient_every` and saving keeps it on with the new interval;
  a submitted `utc_offset` reaches the doc; `#ambient-digest-now` with
  nothing pending flashes "Nothing new since the last digest."; with a
  pending item it flashes the sent words and `#ambient-last-digest`
  updates; `#ambient-review-now`; `#ambient-pending` updates when an
  owner thread finishes in another process, and drops to "smaller" when
  the thread is then marked seen; a schedule that fails moves the count;
  unticking and saving hides `#ambient-state`.
  `#ambient-needs-consent` and the hidden-section case without the
  scripted model can't show in these tests: they run on the scripted
  model. Their conditions are `AmbientText.needs_consent?/1` and
  `Ambient.Rules.config/2`, tested in core.
- `home_live_test.exs`: no ambient line when on and healthy;
  `#ambient-stopped` after a failed timer; `#ambient-consent` after a
  skipped-for-consent firing (`fire_tx/3` with `allowed?: false`); a
  quiet row and a failed row with `-reviewed` after `review_now/0`, and
  without it before.
- `blip_live_test.exs`: a digest message renders
  `#message-<id>-heading` and, inside the `<details>`,
  `#message-<id>-item-0` linking the thread under its current title
  after a rename; a `[nothing to tell]` answer (appended directly with
  `Tx.append` in a commit, so this test doesn't need M7's script)
  renders `#message-<id>` with class `hidden` and no bubble; a queued
  digest's chip.
- `activity_live_test.exs`: a row from a digest run shows "Blip's
  follow-up on the digest" in `#activity-<id>-origin`.

### 11.4 End to end

`apps/hub/test/integration/machine_tools_e2e_test.exs` gains one test
against the real local node, with the scripted models:

1. A project `garden`; `Ambient.configure/1` turns ambient mode on.
2. The owner starts a thread with `on local: $ echo pump fixed`; it
   finishes on the node and nobody marks it seen. `digest_now/0` is
   `"sent"`; Blip's conversation gets the `[Digest]` message and a reply
   naming the thread; `Activity.list/1` has the `"message"` row from
   `"follow_up"`/`"digest"`.
3. `digest_now/0` again is `"skipped_nothing"`.
4. The owner starts a thread with `on local: $ sleep 600`, stops it, and
   starts one with `fail: the ladder is missing`. Once both runs have
   ended, the test backdates both threads' `last_run_ended_at` and
   `active_at` past 72 hours with `Repo.update_all`. `review_now/0` is
   `"sent"`; the reply lists both; both have `reviewed_at`.
5. `Ambient.configure/1` turns it off; a third thread that finishes makes
   no item, and the timers' tasks are `"aborted"`.

### 11.5 Checks

In `apps/hub` (the only app this step changes):

- `mix precommit`
- `mix dialyzer`; any new ignore entry has a reason comment
- `mix test --cover` at the hub's threshold (85)
- No TLC runs: the specs don't change (section 13)

## 12. OTP rules that apply

| Rule | Where it bites |
|---|---|
| 2, 3, 31, 89 | No new process. The timers are durable tasks of a new kind, run by the Scheduler that runs routines; the items and the setting are rows. |
| 15 | The next times are read from the timer tasks; a review's mark is a stored fact (`reviewed_at`), and a thread's state still doesn't read it; digest items are facts deleted when delivered; what is new to the owner is worked out at digest time from the board, not stored. |
| 28, 29 | `Ambient.Rules`, `Ambient.Text`, `MockAmbient`, `AmbientText` and the changes to `Durable.Context`, `Origin`, `Signals.Rules`, `Transcript` and `Notice` are pure, with the time passed in. |
| 30, 11 | `SettingsLive` and `HomeLive` call `Photon.Ambient` and re-read on announcements; each callback is short. |
| 61 | The timers are the routine's shape on the existing harness; collection rides the step 4 settle hook and the commits that already make each change; digests and reviews are signals through `Signals.post_tx/2`. |
| 64 | The form's values are read once, in `Ambient.Rules.config/2`, which keeps the old value for anything missing or unexpected. |
| 67 | Refusals say what to do: report-only runs say to tell the user and wait. |
| 73 | One digest per interval at most and only when a new item stands; one review a day and only when threads qualify; texts cut at 20, 15 and 10 rows; the review reads at most 10 latest answers; earlier digests and reviews shrink to stubs in later requests, and quiet ones drop out; report-only runs can't cause items, so digests can't feed themselves. |
| 86 | A crash loses nothing: the doc, the items, the timers and `reviewed_at` are rows written in commits. Collection and the timer's `on_fail/3` are total, so a bad row can't turn the Scheduler's abort or fail commit into a crash loop. |
| 96 | No sleeping: timers are durable waits. |

## 13. TLA+: is a spec change needed?

No. `Durable.tla`, `HubOps.tla` and `Executor.tla` stay as they are, and
no config is rerun. M12 records why in `specs/tla/Durable.md` and adds a
step 5 entry to `docs/verification.md`.

The reasons, against what made the earlier steps need one:

- Step 3 needed the spec because a routine's firing had to happen once
  and never after its schedule was edited or deleted, with the step fence
  as the only guard. An ambient timer is the same thing: a background
  task that waits, fires in one fenced commit, waits again, and is
  retired by `Tx.request_abort/3` in the commit that changes the setting.
  `Durable.tla`'s `RoutineFire`, `OwnerEdit` and `OwnerDelete` with
  `NoFireAfterRetire`, `FireOncePerSlot` and `RetiredEnds` already check
  that shape (`Durable-routine`, `-schedule`, `-schedcrash`,
  `-schedule-retire-live`). Turning ambient mode off is `OwnerDelete`;
  changing its interval or offset is `OwnerEdit`. What the firing writes
  (a signal and item deletions instead of a submission or a thread)
  doesn't change the fence's argument.
- Step 4 needed it because `Questions.ask/1` committed outside the step's
  fence, between a step's start and its park, and three writers raced on
  one row. Nothing in step 5 commits outside a fence on a task's behalf:
  every read and write of a firing is inside the step's one commit;
  `configure/1`, `digest_now/0` and `review_now/0` are single commits of
  their own that read and write only rows the Store serializes; an item
  from a settle is written in the settle hook's commit, which `HookOnce`
  already checks runs once per settle; and the other items are written
  inside the owner's or the file tool's existing commit.
- The new claims are each one commit's: a digest posts and deletes the
  items it carries together, so no item is reported twice or lost; the
  off commit retires the timers, deletes the items, withdraws the queued
  messages and clears the withdrawn review's marks together, and every
  collector reads the mode in its own commit, so nothing is collected or
  posted after it. A serial commit line makes these true by
  construction; boundary tests check them (section 11.2).
- The `Durable.Context` change is in the pure function that builds model
  input. It changes what a request contains, not which commits happen
  or in what order.

What would change this: a firing split over two commits, a write a
firing makes outside its step's commit, or a timer that posts and then
waits on Blip's answer. Any of those should go into `Durable.tla` first,
as the routine did in step 3.

## 14. Ordered tasks

Each task is small enough for one agent, names its files, and ends with
`mix precommit` passing in `apps/hub`. "After" lists what must be merged
first. M1, M3 and M4's Context part can start at once; M4 waits for M1
only for `Signals.post_tx/2`.

The ordering rules of the earlier steps hold. There are no new routes. A
pure module reaches another context's pure module only through that
context, so a context comes before the modules that use it. Each task
that adds behaviour adds its scripted phrasing or a way to trigger it,
so it can be tried with `PHOTON_MOCK_MODEL=1` when it lands. A task's
tests use only what it or an earlier task adds.

M1. The mode and the digest items. No dependencies.
- Migration `apps/hub/priv/repo/migrations/20261010010000_ambient.exs`
  (`digest_items` with every column of section 3.2, `threads.reviewed_at`);
  `@tables` in `test/support/data_case.ex`.
- New `apps/hub/lib/photon/signals/digest_item.ex`; `signals.ex` (the
  doc functions, `mode/0`, `mode_tx/1`, `ambient_topic/0`,
  `collect_tx/2`, `pending_tx/1`, `pending/0`, `drop_items_tx/2`,
  `queued_ambient?/2`, `withdraw_ambient_tx/1`, Boundary deps);
  `signals/rules.ex` (the `:ambient` clause, `ambient_kind/1`).
- `threads.ex` (`settled_tx/3` reads `mode_tx/1` and collects
  `"finished"`); `threads/thread.ex` (`reviewed_at`);
  `schedules/routine.ex` (`on_fail/3` collects) and the
  `Photon.Schedules` Boundary dep.
- `.credo.exs`: `Photon.Signals.DigestItem` in `FunctionalCore`.
- Tests: `test/core/signals/rules_test.exs`, the M1 cases of
  `test/boundary/signals_test.exs` and `schedules_test.exs` (ambient
  turned on with `Signals.put_ambient_doc_tx/2`).

M2. The smaller items at their call sites. After M1.
- `projects.ex` (`create/1`, `update/2`, `create_file/2`, `save_file/4`,
  `delete_file/2`, `write_file_tx/5`, `edit_file_tx/6` collect; the
  `Photon.Signals` Boundary dep); `threads.ex` (`start/2` and
  `resolve/1` collect).
- Tests: the collection cases of `test/boundary/projects_test.exs` and
  `threads_test.exs` (section 11.2).

M3. The ambient core. No dependencies.
- New `apps/hub/lib/photon/ambient/rules.ex` and `ambient/text.ex`
  (sections 2.3, 3.3, 3.4, 4.1, 4.2, 4.4), taking items and board
  entries as plain maps with the fields section 3.2 and
  `Threads.board/1` give.
- `.credo.exs`: both in `FunctionalCore`.
- Tests: `test/core/ambient/rules_test.exs`, `ambient/text_test.exs`.
- The two modules carry the strict Boundary declarations of section
  10.4 from the start. Their parent, `Photon.Ambient`, arrives in M5;
  until then each is a top-level boundary, which Boundary allows, and
  nothing else calls them.

M4. Earlier digests shrink in Blip's context. After M1.
- `apps/hub/lib/photon/durable/context.ex` (section 5.3, moduledoc).
- `signals.ex`: `post_tx/2` takes `older:` and puts it in the source.
- Tests: `test/core/durable/context_test.exs` (section 11.1); the
  `older:` case of `test/boundary/signals_test.exs`.

M5. The ambient context and its timers. After M1, M3 and M4.
- New `apps/hub/lib/photon/ambient.ex` (`status/0` with the pending
  counts from `Rules.digest/3`, `subscribe/0`, `configure/1`,
  `digest_now/0`, `review_now/0`, `fire_tx/3`, `every_options/0`) and
  `ambient/timer.ex`.
- `threads.ex` (`mark_reviewed_tx/3`, `unmark_reviewed_tx/2`).
- `config/config.exs` and `config/test.exs`: the `"ambient"` kind;
  `config :photon, Photon.Ambient, review_again_days: 7`.
- `apps/hub/lib/photon.ex`: export `Ambient`, moduledoc.
- `.credo.exs`: `"Photon.Ambient"` in `api_modules`.
- Tests: `test/boundary/ambient_test.exs`, the rest of
  `signals_test.exs`, the review-mark cases of `threads_test.exs`.
  Until M7 the scripted Blip answers a digest with its help text; these
  tests assert on the posted submission, the items and the doc, not on
  Blip's reply.

M6. Blip's limits and nothing to tell. After M1 (the ref kinds and
`Signals.mode/0`).
- `assistant/origin.ex` (section 5.1, `report_only?`,
  `report_only_message/0`); `assistant.ex` (`may_act_tx/3`,
  `system_prompt/1` with the mode, `settled_tx/3` skipping nothing to
  tell); `assistant/prompt.ex` (`system_prompt/5`, section 5.5);
  `assistant/notice.ex`; `transcript.ex` (`nothing_to_tell?/1`);
  `activity/rules.ex` (origin labels).
- Tests: `test/core/assistant/origin_test.exs`, `prompt_test.exs`,
  `notice_test.exs`, `activity/rules_test.exs`, `transcript_test.exs`
  (`nothing_to_tell?/1`); `test/boundary/assistant_coordinator_tools_test.exs`,
  `activity_test.exs` (without the nothing-to-tell case, which M7 adds)
  and `assistant_test.exs` cases of section 11.2. The runs a digest or
  review starts are made by posting a signal (`Signals.post_tx/2`) whose
  ref is `"digest"` or `"review"` and whose text is one of the scripted
  phrasings, as step 4's C8 did for questions.

M7. The scripted Blip for digests and reviews. After M5 and M6.
- New `apps/hub/lib/photon/assistant/mock_ambient.ex` (section 8.1);
  `mock_coordinator.ex` (`unasked/2` tries it first) and
  `mock_script.ex` (help).
- `config/runtime.exs`: `PHOTON_QUIET_AFTER_HOURS` (section 8.3).
- `.credo.exs`: `MockAmbient` in `FunctionalCore`.
- Tests: `test/core/assistant/mock_ambient_test.exs`,
  `mock_coordinator_test.exs` still passing; the reply cases in
  `ambient_test.exs` and `activity_test.exs` (a digest's reply names the
  thread; an ignored digest answers `[nothing to tell]` and records no
  row).

M8. The Settings page. After M5.
- `apps/hub/lib/photon_web/live/settings_live.ex` (sections 2.2, 2.3's
  form rebuild, 7.2; the `.UtcOffset` colocated hook); new
  `apps/hub/lib/photon_web/ambient_text.ex`.
- `.credo.exs`: `PhotonWeb.AmbientText` in `FunctionalCore`.
- Tests: `test/web/live/settings_live_test.exs`,
  `test/web/ambient_text_test.exs`.

M9. The home page. After M8 (`AmbientText`).
- `apps/hub/lib/photon_web/live/home_live.ex` (section 7.3), and
  `ambient_text.ex` (`reviewed?/1` if M8 left it out).
- Tests: `test/web/live/home_live_test.exs`.

M10. Blip's panel and the activity page's rows. After M5 and M6.
- `apps/hub/lib/photon_web/components/conversation_components.ex`
  (`ambient_message/1`, the empty nothing-to-tell element, the queued
  chip); `apps/hub/lib/photon/transcript.ex` (`ambient_lines/2`,
  `source_threads/1` reading digest and review items).
- Tests: `test/web/live/blip_live_test.exs` (the nothing-to-tell answer
  appended with `Tx.append`), `test/web/live/activity_live_test.exs`,
  `test/core/transcript_test.exs`, `conversation_components_test.exs`
  (the chip).

M11. End to end. After M7, M8, M9 and M10.
- `apps/hub/test/integration/machine_tools_e2e_test.exs` (section 11.4).
- Walk section 8.4 by hand with `PHOTON_MOCK_MODEL=1
  PHOTON_QUIET_AFTER_HOURS=0`, and fix what it shows.

M12. Docs and the final checks. After M11.
- `docs/projects-and-blip.md`: the status line at the top says all five
  steps are built; a status note under "Keeping track" for ambient mode
  (the setting and where it is, what a digest holds and which items can
  send one, the review's threads and time, what Blip may do in those
  runs, nothing to tell, how earlier digests shrink in Blip's context,
  consent); the "Blip" concept's status note gains the follow-up
  origins; "Build order" gets a step 5 status paragraph and a "Left for
  later" list: Discord, watchers, skills scoped to machines and skills
  with scripts, tagging @Blip in a thread, collaborators, approvals for
  shell commands, a model per thread, Blip resolving, archiving or
  deleting threads, deleting or archiving projects, moving threads,
  pruning the activity log, schedules and the review following the time
  zone across daylight saving, calendar rules like "weekdays at 9",
  pausing a schedule, digests of machine changes, quiet hours for
  digests, a review time other than 09:00, threads sharing a directory.
  The "Open questions" section stays.
- `docs/architecture.md`: the module map (`Photon.Ambient`,
  `Ambient.Rules`, `Ambient.Text`, `Ambient.Timer`,
  `Signals.DigestItem`, `MockAmbient`, `AmbientText`, and the
  `Durable.Context` rule); the supervision note (no new processes; the
  `"ambient"` task kind); a "Step 5: ambient mode (hub)" entry in the
  refactor log in the shape of step 4's (what was added, what moved,
  layers, compatibility, results), saying the five steps of
  `docs/projects-and-blip.md` are built.
- `specs/tla/Durable.md` ("What changed in build step 5": nothing in the
  spec, and section 13's reasons) and `docs/verification.md` (a step 5
  entry: no spec change, no TLC run, the boundary tests that check the
  one-commit claims).
- `apps/hub/lib/photon.ex` and `Photon.Application` moduledocs, final
  pass.
- Section 11.5's checks, with the results recorded in the architecture
  entry.

## 15. Decisions made in this plan

None need the owner before the build. The owner's decisions in
`docs/projects-and-blip.md` settle the model; these are the choices made
inside them, all reversible:

- Ambient mode's settings live in a durable doc, not the settings file,
  so turning it on or off and arming or retiring its timers are one
  commit. The Settings page shows them with the rest, and a Save that
  doesn't carry the switch leaves it alone.
- The digest collects everything that changed that Blip doesn't already
  hear about: the owner's finished runs, schedules that stopped, context
  files written by threads or the owner, projects and threads the owner
  made, Purpose edits and Resolves. Only items new to the owner (a
  finished run they haven't opened, a stopped schedule) can make a
  digest happen; the rest ride along in compact form. Nothing new means
  no digest and no model run.
- The digest comes every 3 hours by default; the owner can pick every
  hour or every 6 hours. Its first firing is one interval after turning
  it on.
- The review comes around 09:00 at the browser's UTC offset, as a fixed
  24-hour repeat, and covers quiet threads plus failed and waiting ones
  untouched as long (72 hours). Each is raised once per quiet spell, and
  again after a week. Unread finished threads are left out. No time zone
  database is added; the review drifts an hour at daylight saving
  changes, as schedules do, until the next Save.
- Both timers obey the scheduled-work consent. "Send a digest now" and
  "Run the review now" exist only on the scripted model.
- Runs started by a digest or a review report only: no starting,
  messaging or stopping threads, and no changes to projects or
  schedules, until the owner answers. They keep the read tools, the
  machine tools and memory.
- Blip gets no new tool. Closing a thread stays the owner's Resolve
  button, which the review points to.
- Blip answers `[nothing to tell]` when nothing is worth saying, which
  makes no bubble, no activity row and nothing in the panel.
- Earlier digests and reviews shrink to stubs in Blip's later requests,
  and quiet ones drop out, through one generic rule in
  `Durable.Context`.
- Digest and review runs are logged as Blip's follow-up, naming the
  digest or the daily review.
- Turning ambient mode off retires both timers, deletes pending items,
  withdraws a digest or review still queued for Blip and clears the
  marks of a withdrawn review, in one commit.
- No TLA+ change: the timers are routines as the spec models them, and
  every new commit is a single serialized one (section 13).

## 16. Review

A review of the first draft raised eighteen findings, two of them
duplicates. Each was checked against this plan, the design doc and the
code at `b5ec377`. All were real; one was applied in part, and one of
the suggested fixes was rejected.

1. Saving Settings while the Ambient section is hidden turned ambient
   mode off (raised twice). Real: `config/2` read a missing `"ambient"`
   as off, while `Settings.normalize/2` keeps saved values for missing
   keys. Applied: a missing key keeps the doc's value, only `"false"`
   turns it off (section 2.3), with core, boundary and LiveView tests.
2. `resolve_thread` changed quiet mode and pulled forward what step 4
   deferred. Real: the draft added a tool and a prompt line in quiet
   mode, and the design doc lists Blip resolving threads as left for
   later. Applied: the tool is dropped; the review tells the owner to
   press Resolve on Home or the thread page (sections 4.3, 5.5).
3. Digests grew Blip's single conversation without limit. Real:
   `Durable.Context` sends every entry since the last reset and only
   shortens older tool results. Applied: a generic `"older"` rule in
   `Durable.Context` turns earlier digest and review messages into
   stubs, cuts their tool results to 500 characters, and drops runs
   that answered `[nothing to tell]` (sections 3.6, 5.3, task M4).
4. The digest covered much less than "everything that changed". Real:
   the draft argued the digest was a notice for the owner, but the
   owner's decision makes it how Blip follows along. Applied: file
   writes, owner-seen finishes, new projects and threads, Purpose edits
   and Resolves are collected as smaller items that ride along but never
   trigger a digest (section 3.1, task M2).
5. The `tz` dependency. Real: AGENTS.md allows new dependencies only for
   date and time parsing, and step 3 accepted the daylight saving drift
   for schedules. Applied: no new dependency; the review is a 24-hour
   repeat armed at the browser's UTC offset, which Settings sends on
   every Save (sections 2.2, 4.1). `next_review/4`'s gap and overlap
   rules and their tests are gone.
6. The Settings pending count disagreed with "Send a digest now" and
   missed schedule failures (raised twice). Real: `pending_count/0`
   counted raw rows, and `SettingsLive` didn't hear
   `{:schedules_changed, _}`. Applied: `Ambient.status/0` counts with
   `Rules.digest/3`, and `collect_tx/2` announces `{:ambient_changed}`
   when it inserts, which covers schedule failures and every other kind
   (sections 3.2, 7.2).
7. The draft predated the polish commits that name threads by their
   current titles. Real: `Transcript.source_threads/1` reads only
   top-level `"thread_id"`s. Applied: it also reads digest and review
   items, and `ambient_lines/2` takes the titles map (section 7.4). The
   queued chip names no thread, so it doesn't need titles.
8. Blip's panel showed the raw digest and a "Nothing worth telling you"
   line every interval. Real. Applied: a digest or review is one
   collapsed line, and a `[nothing to tell]` answer draws nothing
   (sections 5.4, 7.4).
9. Settings got controls the owner didn't ask for. Real, applied in
   part. Kept: the interval (the finding allows it) and a short status
   block on Settings, which spends nothing and is where the owner checks
   the setting works. Dropped: the review time (09:00 is fixed), the
   run-now buttons outside the scripted model, and the home page's
   "Ambient mode is on, next digest" line; Home shows only the consent
   and stopped warnings and the review marks (sections 2.2, 7.3).
10. Demo step 2 relied on beating a 5-second run. Real. Applied: the
    demo uses `sleep 30` and names each button (section 8.4). Rejected
    the other suggestion, starting the thread through Blip: a thread
    Blip starts is Blip's, so its end reaches Blip as an update and never
    becomes a digest item.
11. M4 called `Threads.resolve_tx/2`, which only M3 made public. Real
    for the draft; moot now that `resolve_thread` is dropped.
12. After Save the form lost the ambient fields, so the next Save turned
    ambient mode off. Real: today's handler rebuilds the form from
    `Settings.save/1`'s result, which holds only `@keys`. Applied: the
    handler rebuilds it from the settings merged with
    `AmbientText.form_values/1`, with a save-twice LiveView test
    (sections 2.3, 7.2).
13. The end-to-end review step failed when its threads ended less than a
    second earlier. Real: `State.quiet?/3` uses `>` on whole seconds.
    Applied: the test backdates both threads before `review_now/0`
    (sections 11 intro, 11.4).
14. "Since the last digest" couldn't be computed from the doc. Real:
    `"last_digest"` is overwritten by skips too. Applied: a separate
    `"last_sent_at"`, written only when a digest is posted, with a text
    test for a skip between two sends (sections 2.1, 3.3, 3.4).
15. A review withdrawn by turning ambient mode off left `reviewed_at`
    set. Real. Applied: the off commit clears `reviewed_at` on the
    threads the withdrawn review named, with a boundary test (section
    2.3).
16. Tests for `[nothing to tell]` were listed before the scripted Blip
    could say it. Real. Applied: M6 leaves the nothing-to-tell activity
    case to M7, and M10's panel test appends the answer with
    `Tx.append` (sections 11.2, 11.3, 14).

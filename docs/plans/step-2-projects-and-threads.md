# Step 2: projects and threads

Plan for build step 2 of `docs/projects-and-blip.md`. Photon gets projects
(a purpose and freeform context files, for any body of work) and threads
(durable agent conversations inside a project, run on the hub under a new
`"thread"` profile). A thread uses step 1's machine tools on any machine,
working in the project's own folder there, and reads and writes the
project's context files. The sidebar groups threads under their projects,
and Blip's floating panel knows which project or thread is on screen.

The work ships as one pull request, built as the ordered tasks in section
10. Every section is meant to be read on its own: an agent handed one task
should read section 1, the sections its task points to, and the task.
Rule numbers refer to `docs/otp-design-guide.md`; the short version is
`docs/plans/otp-brief.md`. Paths are relative to the repo root. Module
names are the plan's; the placement is the point.

Nothing here keeps old data. The new tables come in new migrations, the
node protocol's capability moves from `ops:1` to `ops:2` (section 3.4),
and every installed node needs reinstalling. Photon has one user.

## 1. Goal and scope

After this step:

- The user starts a project from the sidebar with a purpose (required) and
  an optional name. The project gets a slug, fixed for its life, which
  names its folder on every machine: `<node workspace>/<slug>`.
- A project has context files: Markdown notes on the hub that the user
  edits on the project's pages and the project's threads read and write
  with tools.
- The user starts a thread in a project by writing its first message. The
  thread is a durable conversation under the `"thread"` profile. Its
  tools are `shell`, `view_image` and `list_machines` (step 1), running in
  the project's folder on whichever machine a call names, and four
  context-file tools. A thread can't start threads, schedule anything or
  touch Blip's memory, and its prompt says nothing about the user.
- The thread page shows the conversation the way Blip's panel does, with
  the machine named on each call, a running command's output streaming
  under it, a composer and Stop.
- The sidebar has Home (today's overview), Projects (a "+" to start one;
  each project with its most recently active threads, any running thread,
  and a "+" to start a thread), Machines (online count, linking to the
  Nodes page) and Settings.
- Blip's panel stays on every page. On any page inside a project (the
  project, a context file, a new thread, a thread), the message box offers
  that page as context, and the message Blip's model sees starts with a
  short note about it.
- `PHOTON_MOCK_MODEL=1` runs threads on a scripted model too.

Out of scope, for later steps:

- Skills and schedules in projects (step 3). The project page leaves a
  column for them (section 5.4) but shows no placeholders.
- Blip's tools over projects and threads, `ask_blip`, thread states beyond
  running and idle, signals to Blip, the home page and the activity log
  (step 4). Blip sees projects and threads only through the page note.
- Deleting or archiving a project or a thread, renaming a thread, and
  moving a thread between projects. Context files can be deleted.
- A model per thread or per project. Every conversation uses the model in
  Settings.
- Per-thread folders. Threads in a project share its folder on each
  machine (the design doc's open question).

## 2. Data

Three tables, each behind a context (section 6). Every write goes through
`Photon.Durable.commit/1`, as `Photon.Machines` does: SQLite has one
writer, and a thread's file write has to land in the same commit as the
tool result that reports it (section 3.3).

### 2.1 Projects

Table `projects`, schema `Photon.Projects.Project`:

| Column | Type | Notes |
|---|---|---|
| `id` | string, primary key | `p_<suffix>`, minted by `Photon.Projects` with `PhotonCore.ID.new("p_")` and passed into `Projects.Rules` (rule 29) |
| `slug` | string, not null, unique index | section 2.2; never changes |
| `name` | string, not null | what the sidebar and pages show |
| `purpose` | text, not null | what the project is for |
| `inserted_at`, `updated_at` | `utc_datetime_usec` | |

Nothing else. No status, goals, owner or kind column: the owner's
decision is that a purpose is the only required field and nothing
prescribes how a project is run. The single user owns everything; a
collaborator step adds an owner column then.

Rules (`Photon.Projects.Rules.project/2`, pure, given the params and the
current project or nil):

- `purpose`: trimmed; required ("Say what the project is for."); at most
  4,000 characters ("Keep the purpose under 4,000 characters, and put
  the rest in a context file.").
- `name`: trimmed, inner whitespace collapsed; optional; at most 60
  characters. A blank name is derived from the purpose
  (`Rules.name_from/1`): its first line, up to the end of its first
  sentence (`. `, `? `, `! `), cut to at most 40 characters at a word
  boundary, with trailing punctuation dropped. "Keep the garden's
  irrigation running through winter. It has three zones..." becomes
  "Keep the garden's irrigation running".
- Editing changes `name` and `purpose` only. A name cleared on edit is
  derived again from the purpose. The slug stays.

Errors come back as a map of field to message, `%{purpose: "..."}`,
which the LiveView turns into form errors. No changeset leaves the
context (rule 69), and the `LiveViewLogic` check forbids Ecto in
LiveViews anyway.

### 2.2 The slug

The slug names the project's folder on every machine and appears in its
URLs. `Rules.slug/1` (pure) makes it from the name:

1. Unicode-normalize to NFD and drop combining marks, then downcase.
2. Replace every run of characters outside `a-z0-9` with one `-`, and
   trim `-` from both ends.
3. Cut to 40 characters. If that cut a word and there is a `-` after
   character 20, cut back to it. Trim a trailing `-`.
4. An empty result becomes `project`.
5. A reserved slug (only `new`, which the routes use) gets `-project`
   appended: `new-project`.

`Rules.unique_slug(base, taken)` appends `-2`, `-3`, and so on until the
slug isn't in `taken`. `Photon.Projects.create/1` reads the taken slugs
with the same prefix inside the commit that inserts the project, so two
creates can't pick the same one; the unique index backs that up.

The slug never changes, even when the project is renamed: commands in the
project's threads, and anything the user set up by hand, depend on the
folder's path. A slug is one path segment of `[a-z0-9-]`, so it can't
climb out of the workspace. It can still match a folder Blip or the user
already made in a workspace (a repo cloned there as `photon`, say); the
project then works in that folder. The project page shows the folder's
path, so this is visible.

### 2.3 Context files

Table `project_files`, schema `Photon.Projects.ContextFile`:

| Column | Type | Notes |
|---|---|---|
| `id` | string, primary key | `f_<suffix>`, minted by `Photon.Projects` |
| `project_id` | string, not null, references `projects` (`on_delete: :delete_all`) | |
| `name` | string, not null | as the user or thread wrote it, e.g. `README.md` |
| `key` | string, not null | `name` downcased; unique index on `[project_id, key]`, so `Notes.md` and `notes.md` can't both exist |
| `content` | text, not null | Markdown, may be empty |
| `version` | integer, not null | 1 when created, plus 1 on every write |
| `updated_by` | string, not null | `"owner"`, or the ID of the thread that last wrote it |
| `inserted_at`, `updated_at` | `utc_datetime_usec` | |

Rules (`Photon.Projects.Rules`):

- `file_name/1`: trims; appends `.md` if the name doesn't end in `.md`
  (any case); then the name must be 1 to 64 characters of letters,
  digits, `.`, `_` and `-`, start with a letter or digit, and contain no
  `..`. Otherwise: `A file name uses letters, digits, ".", "_" and "-",
  like "notes.md".` Files are flat: no folders.
- `content(name, content)`: at most 100,000 characters (code points),
  with the file's name for the message: "notes.md would
  be 123,456 characters; the limit is 100,000. Split it into more than
  one file."
- `save_check(current, expected_version)`: the user's editor sends the
  version it loaded. `:ok` when it matches (or both are nil for a new
  file, or the file was deleted since it was loaded, so saving creates it
  again, section 5.5), `:stale` when the file changed since, `:exists`
  when a new file's name is taken. Threads write without a version
  (section 3.3).
- `edit(name, content, old_text, new_text)`: `{:ok, content}` when `old_text`
  occurs exactly once; otherwise an error saying it wasn't found, or was
  found N times and needs more context.

### 2.4 Threads

Table `threads`, schema `Photon.Threads.Thread`:

| Column | Type | Notes |
|---|---|---|
| `id` | string, primary key | the thread's durable conversation ID (`c_<suffix>`) |
| `project_id` | string, not null, references `projects` (`on_delete: :delete_all`) | index on `[project_id, active_at]` |
| `title` | string, not null | from the first message |
| `active_at` | `utc_datetime_usec`, not null | when the thread last got a message; set by `start/2` and by every `send/3`, in the same commit as the submission |
| `inserted_at`, `updated_at` | `utc_datetime_usec` | |

- The title is `Photon.Threads.Rules.title/1` of the first message: its
  first non-blank line, whitespace collapsed, cut to at most 60 characters
  at a word boundary with `...` added when cut. The conversation's own
  `title` gets the same text.
- A thread's conversation has profile `"thread"`. The thread row, the
  conversation and the first message are created in one commit
  (`Threads.start/2`), so there is never a thread without a first
  message, or a conversation without its row.
- Threads are listed by last activity, `active_at` descending, on the
  sidebar and the project page, so a thread the user goes back to moves
  to the top. Whatever submits to a thread does it through
  `Threads.start/2` or `Threads.send/3`, which set `active_at`; step 4's
  Blip tools and step 3's schedules will submit through them too. There
  is no status column: whether a thread is running is derived from its
  durable run (`Durable.busy/1`, section 6.3), never stored (rule 15).
  Step 4's states will be derived the same way.

### 2.5 Migrations

- `apps/hub/priv/repo/migrations/20261007000000_create_projects.exs`:
  `projects` and `project_files` (task S5).
- `apps/hub/priv/repo/migrations/20261007010000_create_threads.exs`:
  `threads` (task S6).
- Add `projects project_files threads` to `@tables` in
  `apps/hub/test/support/data_case.ex`, children first
  (`threads project_files projects`), so the foreign keys never block a
  delete.

## 3. Threads on the durable harness

### 3.1 The `"thread"` profile

`Photon.Threads` is the threads context's API and the profile's module,
as `Photon.Assistant` is both for Blip. Register it in
`apps/hub/config/config.exs` and `config/test.exs`:

```elixir
config :photon, Photon.Durable,
  profiles: %{"assistant" => Photon.Assistant, "thread" => Photon.Threads},
  kinds: %{"routine" => Photon.Assistant.Routine}
```

(`test.exs` keeps its `"test"` profile too.)

Callbacks:

- `llm/1`: the model in Settings, as Blip's: `config:
  ChatGPT.llm_config(Photon.Threads.MockScript)` with the hosted
  `web_search` tool, `stream: &Photon.ChatGPT.stream/3`, `model:
  Settings.model(settings)`, `reasoning: Settings.reasoning(settings)`,
  `cache_key: conversation.id`. `reasoning/1` moves from
  `Photon.Assistant.Prompt` to `Photon.Settings`, where both profiles can
  read it.
- `system_prompt/1`: `Photon.Threads.Prompt.system_prompt(project, now)`
  (section 3.2), with the project read through `Photon.Projects` and the
  time from `DateTime.utc_now/0`. Settings aren't read: nothing about the
  user goes in.
- `tools/1`: `MachineTools.tools() ++ [Tools.ListContextFiles,
  Tools.ReadContextFile, Tools.WriteContextFile, Tools.EditContextFile]`.
  Nothing that starts a thread, schedules a prompt or touches memory.
- `workdir/1` (new optional callback, section 3.4): the project's slug.

A thread whose row or project is missing (it can't happen without a
deletion, which this step doesn't have) raises in `system_prompt/1` and
`workdir/1`, and the generation or tool call fails with that message.

### 3.2 The thread's prompt

`Photon.Threads.Prompt` (pure; the project and the time are arguments).
It changes only when the project's name or purpose changes, or on the
hour, so provider prompt caches stay warm. It has no context file list in
it, for the same reason: the model lists them with a tool.

What it says, in this order:

1. Who it is: an agent working on one project in Photon, a hub that runs
   work on a set of machines. It works in this thread; other threads in
   the project may be working at the same time.
2. The project: its name and its purpose, verbatim.
3. How it works:
   - It has `shell` and `view_image` on every machine and `list_machines`
     to see which there are and which are online. It names the machine
     when it reports what ran there. If the user doesn't say which
     machine, it picks a sensible one and says which.
   - Its working directory on every machine is the project's folder,
     `<workspace>/<slug>` (with the slug filled in), made the first time
     a command runs there. The project's other threads share it, so it
     looks before it deletes or overwrites, and keeps what matters in
     files.
   - The shell lines shared with Blip's prompt
     (`Photon.MachineTools.Guide.shell/1`, section 3.6): a fresh shell
     per call, background children killed with the command's process
     group, the `set -m; nohup` pattern for things that keep running, and
     that a call holds the thread until its command exits.
   - Context files: Markdown notes on the hub, shared with the user and
     the project's other threads (background, decisions, findings,
     plans). Check them before starting on something that may have
     history; record what the next thread would need to know. Use
     `write_context_file` for a new or rewritten file and
     `edit_context_file` to change one passage. Keep them short and
     current.
   - It can search the web.
   - Never invent results. If a machine is offline or a command failed,
     say so plainly. Use Markdown when it helps; say the result first,
     then the detail.
4. Now: the time to the hour in UTC, as Blip's prompt does.

Left out on purpose: Blip's voice, the user's name, time zone and
instructions from Settings, and Blip's memory. A test checks that none of
them appear when Settings has all of them filled in (section 7.1).

### 3.3 The context-file tools

Four `Photon.Durable.Tool` modules in `Photon.Threads.Tools`. Each finds
its project from its conversation (`Threads.project_id!/1`). All four are
`replay: :safe`: the reads change nothing, and the writes happen only
inside the commit that records the result (`{:commit, fun}`), so a rerun
after a hub restart either finds nothing done or never runs.

`list_context_files`
- No parameters.
- Result: one line per file, newest change first: `- notes.md (1,234
  characters, changed 2026-10-07 14:03 UTC by you)`, where "you" is this
  thread, "the user", or `thread "Fix the pump"`. With none: "This
  project has no context files yet."
- `Threads.Rules.listing/3` formats it (pure: the files, this thread's ID,
  and the titles of the other threads that wrote them).

`read_context_file`
- Parameters: `name` (string, required).
- Result: the file's content, after a first line `notes.md, 1,234
  characters, changed ...:`. A missing file: an error result that lists
  the names there are.

`write_context_file`
- Parameters: `name` (string, required), `content` (string, required, at
  most 100,000 characters).
- Creates the file or replaces all of it. No version check: last write
  wins. The description says to read a file before rewriting it, and to
  use `edit_context_file` for a change to one part.
- `execute/2` returns `{:commit, fn tx -> ... end}` and checks nothing
  itself. Inside the commit,
  `Projects.write_file_tx(tx, project_id, name, content, thread_id)` is
  the one place that checks the name and content (with `Projects.Rules`,
  which `Photon.Projects` doesn't export), writes the row (`updated_by`
  is the thread's ID) and announces it (section 4). It returns
  `{:ok, %{file: file, created?: boolean}}` or `{:error, message}`, and
  the tool turns that into its result: "Wrote notes.md (1,234
  characters)." or "Created notes.md (...)", with details `%{"file" =>
  name, "version" => n}`, or the error result. A refused write changes
  nothing.

`edit_context_file`
- Parameters: `name`, `old_text`, `new_text` (strings, required).
- Inside the commit, `Projects.edit_file_tx/6` checks the name, reads the
  current content, applies `Rules.edit/4`, checks the new content's
  length and writes it, returning `{:ok, file}` or `{:error, message}`
  like `write_file_tx/5`. The error results ("old_text
  wasn't found in notes.md", "old_text appears 3 times in notes.md; give
  more of the passage") change nothing.

If the call is stopped before its commit, the commit records "Stopped by
the user" and none of the write is kept (`Photon.Durable.Tool`'s
`{:commit, fun}` contract).

### 3.4 How a thread's working directory reaches the machine

The folder is a fact of the conversation, decided by its profile, and it
can't change while a call runs (the slug is fixed). So it rides along
with the tool call rather than being looked up by the machine tools:

1. `Photon.Durable.Profile` gets an optional callback
   `workdir(Conversation.t()) :: String.t() | nil`: a directory relative
   to each machine's workspace, or nil for the workspace itself.
   `Photon.Threads` returns the project's slug. `Photon.Assistant`
   doesn't implement it, so Blip keeps working in the workspace.
2. `Photon.Durable.ToolAPI` gets a `workdir` field (default nil) and
   `new/2`. `Photon.Durable.ToolTask` already loads the conversation and
   its profile to find the tool; it now builds the API with
   `ToolAPI.new(task, workdir)`, where `workdir` is the profile's answer
   when it implements the callback (checked with
   `Durable.implements?/3`). `new/1` stays, with nil.
3. `Photon.MachineTools.Call.execute/3` passes `api.workdir` to
   `Translate.shell_args/2` and `Translate.view_image_args/2`, which put it
   in the op's `args` as `directory` (they put nil there today).
4. The node already resolves a relative `directory` against its workspace
   (`PhotonNode.Executor.Request.operation/2`), and a relative
   `view_image` path against that directory.
5. New on the node: `Ops.Shell` creates the command's directory
   (`File.mkdir_p/1`) in `prepare_files/1`, before the `process`
   checkpoint. It is idempotent, so a resumed or rerun op just finds it.
   If it can't (a file is in the way, no permission), the op fails before
   anything runs: "couldn't create the working directory
   /home/me/photon/workspace/garden: not a directory. The command didn't
   run." `view_image` creates nothing: a missing folder means a missing
   file.
6. The node's join lists the capability `ops:2` instead of `ops:1`
   (meaning: it creates a missing working directory), and
   `Photon.Machines.Roster` treats a connected node without `ops:2` as
   outdated. Every node needs reinstalling once; the hub's own `local`
   node is built with the hub and is always current. Without this, a step
   1 node would fail a thread's first command with "start process ...:
   enoent", which says nothing useful.
7. The outdated check at call start isn't enough on its own. A call to a
   known machine that is offline passes it and parks with its op row
   stored. If that machine comes back with an `ops:1` build, today's
   `Machines.joined/1` pushes every open row to it regardless of
   capabilities, and the old node runs the command in a folder that
   doesn't exist. So:
   - `Machines.joined/1` and `Machines.push_for/2` push nothing, and write
     nothing, for a machine whose status is `:outdated`. Its rows stay
     open, so a node reinstalled with `ops:2` gets them on its next join.
   - `Photon.MachineTools.Call`, on each check of a parked call, ends the
     call with `Translate.outdated_machine/1`'s message when the machine
     is `:outdated` (through `fail/2`, which cancels the row), instead of
     counting it as offline and later reporting "offline for 10 minutes"
     about a machine that is connected.

A hub restart that reruns a thread's `shell` call computes the same
`directory` from the same slug, and `Machines.start/1` finds the existing
row anyway (step 1, hub rule 1).

The descriptions of `shell` and `view_image` say "in your working
directory on that machine" and "absolute, or relative to your working
directory" instead of naming the workspace; each prompt says what the
working directory is. `list_machines` adds a line when `api.workdir` is
set: "Your working directory on each machine is <workspace>/garden,
made on first use." and names each online machine's full path from its
`workspace` (offline machines have no workspace to show).

### 3.5 The scripted model

`Photon.Threads.MockScript` (pure, implements `PhotonCore.LLM.Mock`),
behind `PHOTON_MOCK_MODEL=1` and the tests. It understands:

- `machines`, `on <machine>: $ <command>`, `on <machine>: look at <path>`:
  the same phrasings as Blip's, from `Photon.MachineTools.MockPhrases`
  (section 3.6)
- `files` or `list files`: `list_context_files`
- `read <name>`: `read_context_file`
- `write <name>: <text>`: `write_context_file` with `<text>` as the
  content (multi-line allowed)
- `edit <name>: <old> => <new>`: `edit_context_file`
- after a tool result, it relays the result as Blip's does (`That didn't
  work: ...` for an error; "Here it is." for an image)
- anything else: a help text that lists these and says to sign in with
  ChatGPT for the rest

It matches on the last text part of the last user message, the same as
Blip's script does after section 5.9.

### 3.6 What Blip and threads share

- `Photon.MachineTools.Guide` (pure): `shell(where)` returns the sentences
  about a fresh shell per call, process groups and `nohup`, and that a
  call holds the conversation until its command exits, with `where`
  ("the machine's workspace" for Blip, "the project's folder" for
  threads). `Photon.Assistant.Prompt` uses it, and its text must come out
  byte for byte as today (the prompt test pins "How you work" word for
  word). To fit Blip's list, the text is two Markdown list items: the
  caller writes the first item's `- ` and any lead-in, and the second
  item ("A shell call holds the conversation ...") starts with its own
  `- ` on a new line and may be continued by the caller. Blip's own
  lines about `schedule` and checking back stay in its prompt; threads
  have no `schedule`.
- `Photon.MachineTools.MockPhrases` (pure): the three machine phrasings
  as `{regex, reply_fun}` pairs and `relay_result/1`, moved out of
  `Photon.Assistant.MockScript`, which uses them, as does
  `Photon.Threads.MockScript`.
- `Photon.Transcript` (pure): today's `Photon.Assistant.Transcript`,
  moved and renamed, since both pages fold their conversation with it
  (section 5.8).

`Guide` and `MockPhrases` are exported by `Photon.MachineTools`. Pure
modules in other contexts (`Threads.Prompt`, `Assistant.MockScript` and
so on) list `Photon.MachineTools` in their Boundary deps, not `Guide` or
`MockPhrases`: Boundary lets a boundary depend only on its parent, a
sibling, or one of its parent's deps, and `Photon.Threads` and
`Photon.Assistant` depend on `Photon.MachineTools`, not on its children.
`MockPhrases` uses `PhotonCore.LLM`, so `Photon.MachineTools` adds
`PhotonCore.LLM` to its own deps.

## 4. Events

Every announcement is a hint to re-read committed state, made after the
commit that stored it, through `Photon.Events`.

To announce from inside a commit, `Photon.Durable.Tx` gets
`announce(tx, topic, message)`. It adds an `{:announce, topic, message}`
change; `Photon.Durable.Changes.summarize/1` collects them in a new
`announcements` list (in commit order); `Photon.Durable.Store` broadcasts
each with `Events.broadcast/2` after the transaction commits, next to the
`durable:*` broadcasts. A commit that rolls back announces nothing. This
is what lets a thread's file write, made inside the tool call's commit,
reach the project page only once it is stored. `Photon.Projects` and
`Photon.Threads` use it for every write, from the user or a thread alike.

| Topic | Message | Sent when | Who listens |
|---|---|---|---|
| `"projects"` (`Projects.subscribe/0`) | `{:projects_changed, project_id}` | a project is created, renamed or its purpose changes; a thread is started in it or sent a message (its `active_at` moved) | `PhotonWeb.Shell` (rebuilds the sidebar, then lets the message on to the page), `ProjectLive`, `ThreadLive` (project name) |
| `"project:" <> id` (`Projects.subscribe_files/1`) | `{:project_files_changed, project_id, key}` | a context file is created, written, edited or deleted, by the user or a thread | `ProjectLive` (file list), `ContextFileLive` (the open file) |
| `"durable:global"` (existing) | `{:durable_tasks, tasks}` | any task changes | `PhotonWeb.Shell` rebuilds the sidebar, only when one of `tasks` belongs to a thread in the sidebar; `ProjectLive` likewise for its threads |
| `"durable:" <> thread_id` (existing, `Threads.subscribe/1`) | `{:durable, id, changes}`, `{:live, id, event}` | the thread's commits and streaming output, including `tool_output` | `ThreadLive` |
| `"nodes"` (existing) | `:nodes_changed` | a machine connects or leaves | `PhotonWeb.Shell` (the Machines count) |

The `{:durable_tasks, _}` check keeps the sidebar's cost in proportion
(rule 73): a busy hub changes tasks often, and the shell rebuilds the
sidebar (three small queries, section 5.2) only when a changed task's
`conversation_id` is a listed thread. A thread that
isn't listed can only start running through a submission, which moves its
`active_at` and announces `{:projects_changed, _}`, so the shell rebuilds
and lists it before its tasks matter.

## 5. UI

### 5.1 Routes

In `PhotonWeb.Router`, inside the existing `live_session :gui`:

```elixir
live "/", OverviewLive
live "/projects/new", ProjectNewLive
live "/projects/:slug", ProjectLive
live "/projects/:slug/files/new", ContextFileLive, :new
live "/projects/:slug/files/:name", ContextFileLive, :edit
live "/projects/:slug/threads/new", ThreadLive, :new
live "/projects/:slug/threads/:id", ThreadLive, :show
live "/nodes", NodesLive
live "/settings", SettingsLive
```

`/projects/new` comes before `/projects/:slug`, and `new` is a reserved
slug (section 2.2). File names end in `.md`, so `files/new` can't be a
file. A project, file or thread that doesn't exist, or a thread under the
wrong project's slug, redirects to `/` with a flash ("There's no project
called garden.", "There's no file called plan.md in Garden.", "There's no
such thread in Garden.").

Images in a thread's conversation get their own route, next to Blip's, in
the `:gui_files` pipeline:

```elixir
scope "/blip", PhotonWeb do
  pipe_through :gui_files
  get "/images/:entry_id/:index", ConversationImageController, :blip
end

scope "/threads", PhotonWeb do
  pipe_through :gui_files
  get "/:thread_id/images/:entry_id/:index", ConversationImageController, :thread
end
```

`PhotonWeb.BlipImageController` becomes `PhotonWeb.ConversationImageController`
with the two actions; `thread/2` reads through `Threads.image/3`, which
only finds entries in that thread's conversation.

### 5.2 The sidebar

`PhotonWeb.Layouts.sidebar/1`, top to bottom:

- The brand, as today.
- `Home` (`#nav-home`, links to `/`, today's overview). It replaces
  `#nav-overview`; step 4 replaces the page behind it.
- `Projects` heading with a "+" (`#new-project`, to `/projects/new`,
  title "Start a project").
- Each project (`#side-project-<slug>`, to `/projects/<slug>`), with a "+"
  on its row (`#new-thread-<slug>`, to `/projects/<slug>/threads/new`,
  title "Start a thread"). The "+" is always visible, faint until the row
  is hovered, so it works on touch screens.
- Under each project, its five most recently active threads (by
  `active_at`, section 2.4) plus any other thread of the project that is
  running, most recent first (`#side-thread-<id>`, to the thread), each
  with a small pulsing dot while it runs (`data-running="true"`), and, if
  there are more, "N more" (`#side-more-<slug>`, to the project page).
  The `side-more-` prefix can't collide with a project row's ID: a
  project called "Garden more" has slug `garden-more` and row ID
  `#side-project-garden-more`, which a `-more` suffix on `garden`'s row
  would also produce.
- With no projects (`#no-projects`): "No projects yet. A project is a
  purpose and some notes, for any body of work: a repo, a trip, a house."
  and a "Start one" link (`#start-first-project`).
- `Machines` (`#nav-machines`, to `/nodes`) with "N online". This replaces
  both today's `Nodes` item and the per-machine list under the
  `Machines` heading, and the "+" next to that heading goes away (owner's
  decision). The Nodes page itself is unchanged. It sits at the bottom,
  above `Settings`.
- At the bottom, as today: the ChatGPT sign-in banner (above `Machines`),
  `Settings` (`#nav-settings`) with the model, the theme toggle.

The projects list takes the space the machine list had and scrolls. The
current page is highlighted and carries `aria-current="page"`:
`Layouts.app`'s `active` attr takes `:home`, `:nodes`, `:settings`,
`{:project, slug}` or `{:thread, slug, id}`. A thread also marks its
project's row, which is why the slug is in the tuple: the thread may not
be among the listed ones, and the layout shouldn't have to look it up.
The project page, a context file and the new-thread page pass
`{:project, slug}`; `/projects/new` passes nothing.

The data comes from `PhotonWeb.Shell`: `@shell.projects`, from
`Threads.sidebar(5)`, a list of `%{project: %{id, slug, name}, threads:
[%{id, title, running?}], more: n}` with the projects by name, and
`@shell.running`, a `MapSet` of the listed threads that are running,
built from their `running?`. `sidebar/1` first reads which threads are
running (`Durable.busy_in_profile("thread")`, one query over the live
runs, so bounded by what is running), then each project's five most
recently active threads plus the running ones, with each project's
thread count for "N more" (one query with `row_number()` and `count()`
windows over `[project_id, active_at]`), and the projects
(`Projects.list/0`, so a project with no threads is listed too). Shell subscribes to `Projects.subscribe/0` and rebuilds both on
`{:projects_changed, _}`, and on `{:durable_tasks, tasks}` when one of
`tasks` belongs to a listed thread (section 4), so a thread listed only
because it ran drops back under "N more" once it stops. `BlipLive` mounts
Shell too and gets the same data, which costs a query per mount and
nothing more.

### 5.3 New project

`PhotonWeb.ProjectNewLive` at `/projects/new`: a form `#project-form`
(`phx-submit="create"`) with `Purpose` (textarea, `#project-purpose-input`,
required, "What is this project for? A few sentences.") first and `Name`
(`#project-name-input`, "Optional. Made from the purpose if you leave it
blank.") second, and `Start project` (`#project-create`). The form is a
plain map through `to_form(params, as: :project, errors: ...)`. On
success it navigates to `/projects/<slug>`; on error it shows the
messages under their fields.

### 5.4 The project page

`PhotonWeb.ProjectLive` at `/projects/:slug`:

- Header: the name (`#project-name`), and under it "Folder `garden` in
  each machine's workspace" (`#project-folder`).
- Purpose (`#project-purpose`), rendered as Markdown, with an `Edit`
  button (`#edit-project`) that swaps in a form `#project-edit-form`
  (name and purpose, `Save` `#project-save`, `Cancel`).
- Two columns on wide screens, one on narrow:
  - Threads (`#project-threads`), most recently active first (section
    2.4): title, "running" or the time of its last message, each row
    `#project-thread-<id>` linking to the thread. `New thread` (`#project-new-thread`). Empty: "No threads yet.
    Start one to put an agent to work on this project."
  - Context files (`#context-files`): name, size, "changed 5 minutes ago
    by you" or `by "Fix the pump"`, each row `#context-file-<file id>`
    linking to the editor. `New file` (`#new-file`). Empty: "No context
    files yet. Threads write notes here as they work, and so can you."
- Step 3 adds Skills and Schedules to the second column. Nothing stands
  in for them now.

Both lists are LiveView streams, as the project's AGENTS.md requires for
collections: a project's threads are never deleted in this step, so the
list only grows. `#project-threads` and `#context-files` are
`phx-update="stream"` containers; `stream_configure/3` gives the rows
their IDs (`project-thread-<id>`, `context-file-<id>`); each empty state
is the `hidden only:block` first child, so no `empty?` assign is needed.
The empty states carry IDs (`#no-threads`, `#no-files`), since
`Phoenix.LiveViewTest` refuses a stream child without one. A file's
"by" names the thread from `Threads.titles/1`.
A row's running state is part of the streamed item (`%{thread: t,
running?: boolean}`), so it changes only by re-streaming the rows.

What the socket keeps besides the streams: the project, a `MapSet` of
the project's thread IDs (to tell whether a `{:durable_tasks, tasks}`
concerns it), and the edit form.

- `{:projects_changed, id}` for its project: reload the project, and
  reset the threads stream (`stream(:threads, rows, reset: true)`) with
  the running set read fresh, since the order may have changed.
- `{:project_files_changed, id, _}`: reset the files stream.
- `{:durable_tasks, tasks}` when one of `tasks` belongs to one of its
  threads: reset the threads stream the same way.

### 5.5 A context file

`PhotonWeb.ContextFileLive`:

- `:new` at `/projects/:slug/files/new`: a form `#file-form` with the
  name (`#file-name`) and the content (`#file-content`, a monospace
  textarea), and `Save` (`#file-save`). On success it goes to the file's
  page.
- `:edit` at `/projects/:slug/files/:name`: the name as the heading, a
  meta line `#file-meta` ("Version 4, changed 5 minutes ago by \"Fix the
  pump\""), `Write` and `Preview` tabs (`#file-tab-write`,
  `#file-tab-preview`; the preview `#file-preview` is
  `Photon.Markdown.to_html/1`), the form `#file-form` with the textarea
  and a hidden `version`, `Save` (`#file-save`) and `Delete`
  (`#file-delete`, with `data-confirm`).
- `phx-change="edit"` keeps the text in the form and marks it dirty.
- When `{:project_files_changed, id, key}` names this file: a clean
  editor reloads it; a dirty one shows `#file-changed` ("A thread changed
  this file while you were editing.", or "This file was saved somewhere
  else while you were editing." when the user saved it in another tab)
  with `Load the new version` (`#file-reload`, discards your text) and
  `Keep my text` (`#file-keep`, takes the new version's number so the
  next save writes over it; without it the user could never save their
  text over a thread's change). A save with an old version gets the same
  banner and keeps your text in the box. A file deleted meanwhile shows
  `#file-deleted`, and `Save` creates it again.
- The `:new` form has the `Write` and `Preview` tabs too. A dirty editor
  says "Unsaved changes" (`#file-dirty`) next to `Save`. When the server
  replaces the text (a clean reload, `#file-reload`), the editor's
  wrapper gets a new DOM ID (`#file-editor-<n>`), because LiveView leaves
  a focused textarea's value alone and the user would otherwise see, and
  save over, the old text.

### 5.6 New thread

`PhotonWeb.ThreadLive`, action `:new`, at `/projects/:slug/threads/new`:
the heading "New thread in Garden", the purpose (clamped to three lines),
and the composer (section 5.8) with the placeholder "What should this
thread work on?". Sending calls `Threads.start(project_id, text)` and
navigates to the new thread. Without a model it shows the sign-in panel
(`#thread-sign-in`) in place of the composer, as Blip does.

### 5.7 The thread page

`PhotonWeb.ThreadLive`, action `:show`, at `/projects/:slug/threads/:id`:

- Header: the project's name linking back (`#thread-project`), the title
  (`#thread-title`), and the state (`#thread-status`, `data-state` of
  `running` or `idle`).
- The conversation (`#thread-conversation`, the `PinToBottom` hook, with
  `jump_to_latest/1`): the entries (`#thread-entries`, a stream with DOM
  IDs `thread-entry-<entry id>`), each tool call as a line inside the
  answer that made it (`#thread-action-<call id>`), naming the machine
  ("Ran `ls` on mm1", "Looked at shot.png on mm1"), the running command's
  output tail under it, images under their line, and the in-flight answer
  (`#thread-live-output`). Context-file calls read "Checked the context
  files", "Read notes.md", "Wrote notes.md", "Edited notes.md".
- The composer (`#thread-composer`, `#thread-composer-input`,
  `#thread-send`), with, while the thread runs, the steer or follow-up
  toggle (`#thread-mode-toggle`), `Stop` (`#thread-stop`) and the queued
  messages (`#thread-queued`, each `#thread-queued-<id>` with a withdraw
  button).
- Stop calls `Threads.stop/1`: `Durable.abort/1` on the conversation,
  which withdraws everything queued (a thread has no background input).
- The composer row keeps clear of Blip's face in the corner
  (`blip-clear-x`), and the page makes room for a pinned Blip panel as
  every page does.

It subscribes with `Threads.subscribe/1` and folds `{:durable, ...}` and
`{:live, ...}` exactly as `BlipLive` does, through the shared helpers in
section 5.8.

### 5.8 Sharing the conversation view with Blip

Reusing step 1's rendering is sound: both pages show durable
conversations with the same entry kinds, the same tool-call rows and the
same live events. Only Blip's dock, bubbles, mood and empty state are
Blip's own. Three moves:

- `Photon.Assistant.Transcript` becomes `Photon.Transcript` (strict core,
  exported from `Photon`), unchanged except for a new `typed/2`: a user
  message's text as typed, which is its last text part when the entry's
  `source` has a `"page"` (section 5.9) and all of its text otherwise.
  The queued-message chips and the user bubble use it.
- `PhotonWeb.ConversationComponents` (function components) takes, from
  `BlipLive`, `entry/1`, `action/1`, `action_label/1`, `search/1`,
  `live_output/1`, `thinking/1`, `composer/1` (with its colocated
  `.Composer` hook) and `sign_in_to_talk/1`. Each takes an `id_prefix`
  attr (default `""`, so Blip's IDs `#composer`, `#stop`,
  `#action-<id>`, `#live-output` stay as they are; the thread page passes
  `"thread-"`), since both live on one document. `action/1` takes an
  `image_path` function attr (`fn entry_id, index -> path end`) so each
  page points at its own image route. Labels and icons for the four
  context-file tools join the existing ones; like the machine calls',
  they're in the present while the call runs ("Reading notes.md"). As
  built, `composer/1` also takes `placeholder` (default "Ask Blip
  anything...") and `class` (added to its outer row, for the thread
  page's `blip-clear-x`), and `sign_in_to_talk/1` takes `who` (default
  "Blip"), so neither has Blip's words built in.
- `PhotonWeb.ConversationView` (plain functions over a socket, no
  process, in the web layer): `mount_conversation(socket, entries, opts)`
  (assigns `results`, `calls`, `outputs`, `empty?`, `live`, `shown`,
  `busy`, `queued`, `mode`, `form`, and the `:entries` stream with an
  optional `dom_id`), `apply_changes(socket, changes, busy, queued)`,
  `apply_live(socket, event)` (both the `tool_output` tail and the
  in-flight answer) and `reset_form/1`. `BlipLive` and `ThreadLive` call
  these, so their `handle_info` clauses stay within 15 lines (rule 30)
  and the fold lives in one place. `BlipLive` keeps its outcome, bubbles
  and unread count on top.

`BlipLive`'s behaviour and tests don't change with this move (task S7);
the thread page then only composes the pieces. Whatever step 1's review
left in `BlipLive` when this step starts moves with it as it is. At the
time of writing, uncommitted review work in the step 1 checkout adds
`Transcript.machine_action/4` ("Running `uptime` on mm1" while a call
runs, "Ran" after, `local` always named) and a `canceled` marker in
`Ops.Shell`; both carry over unchanged, and the thread page gets the same
labels.

### 5.9 Blip's page context

Blip floats over every page, so a message like "what's left here?" means
the project, context file or thread on screen. This rebuilds
`Assistant.Page`, which step 1 removed when node sessions went, for
projects and threads.

- `.BlipDock` reports `location.pathname` when it mounts and on every
  `phx:page-loading-stop` (`pushEvent("page", {path})`), skipping a path
  it already reported, as it did before step 1.
- `BlipLive.handle_event("page", %{"path" => path}, ...)` assigns
  `page: Assistant.page_at(path)` and clears `page_dismissed`.
- `Assistant.page_at/1` calls `Page.at(path)`, which is pure:
  - `/projects/:slug/threads/:id` (but not `threads/new`) gives
    `{:thread, slug, id}`;
  - `/projects/:slug/files/:name` (but not `files/new`) gives
    `{:file, slug, name}`;
  - every other path under `/projects/:slug`, including the project page,
    `threads/new` and `files/new`, gives `{:project, slug}`;
  - `/projects/new`, `/projects`, and everything outside `/projects`
    give nil.

  It then reads the project (and the thread, which must belong to it, or
  the file) and returns `Page.of_project/1`, `Page.of_file/2` or
  `Page.of_thread/2`: `%{"kind", "project_id", "slug", "name",
  "thread_id", "title", "file", "label"}`, where `label` is "Garden",
  "Garden / notes.md" or "Garden / Fix the pump". Anything not found
  gives nil.
- The composer shows the page as a chip (`#page-chip`, "About Garden /
  Fix the pump") with a × (`#page-chip-dismiss`) that leaves it out of
  the next message.
- `Assistant.send(text, when_busy: mode, page: page)` reads the page's
  facts fresh at send time and submits two text parts:
  `[Message.text(Page.note(page, facts)), Message.text(text)]`, with
  `source: %{"kind" => "user", "page" => page}`. The model sees the note
  first; the conversation shows only what was typed
  (`Transcript.typed/2`) and a small "About Garden / Fix the pump" line
  under it. Nothing has to be parsed back out of the text.
- The facts (read by `Photon.Assistant` through `Photon.Projects` and
  `Photon.Threads`): for a project, its purpose, its context files'
  names and its threads' titles with running or idle; for a file, also
  the file's saved content (Blip has no tool to read context files until
  step 4, and "what's missing from this?" is the likely question on the
  editor); for a thread, also whether it is running and the text of its
  latest answer (`Threads.latest_answer/1`, from `Durable.last_entry/2`).
  Text the user typed in the editor and hasn't saved isn't in the note;
  the note says "as last saved".
- `Page.note(page, facts)` (pure) bounds everything: the purpose to
  1,000 characters, 30 file names, 10 threads, the first 4,000
  characters of a file (with "(cut; the file has 12,345 characters)"
  when longer), and the last 1,500 characters of the latest answer. On
  the editor the first line reads `[Looking at notes.md in the project
  "Garden", ...]`. Example for a thread:

  ```
  [Looking at the thread "Fix the pump" in the project "Garden", folder "garden" in each machine's workspace]
  Purpose: Keep the garden's irrigation running through winter...
  Context files: notes.md, zones.md
  The thread is idle. The end of its latest answer: "...the zone 2 valve is stuck open; it needs replacing."
  ```

- Blip's prompt gains one line under "How you work": a message may start
  with a note of the page the user has open, beginning "[Looking at";
  "this" and "here" mean that page. Blip can't read or change projects
  and threads with tools yet (step 4), but it can look at a project's
  folder on any machine with `shell`.
- Blip's `MockScript` matches on the last text part (the typed text), so
  the note doesn't hide its phrasings, and learns `here`: it answers with
  the note's first line, or "I don't know which page you're on." without
  one. The LiveView test uses it.

## 6. Module plan

Layers per the brief. "Boundary" is the `use Boundary` declaration.
Every public function gets a `@spec`, every struct a `@type t`. No new
processes and no new registered names anywhere in this step.

### 6.1 apps/node

| Module | Layer | Change |
|---|---|---|
| `PhotonNode.Ops.Shell` | worker | `prepare_files/1` first runs `File.mkdir_p(input["directory"])`; an error fails the op before the `process` checkpoint, with the message in section 3.4. Moduledoc says so. |
| `PhotonNode.Connection` | boundary | The join's `capabilities` become `["ops:2"]`. |
| `PhotonNode` | lifecycle | Moduledoc: the protocol summary names `ops:2` and what it adds. |

No Boundary or Credo list changes.

### 6.2 apps/hub: harness and machine tools

| Module | Layer | Boundary | Change |
|---|---|---|---|
| `Photon.Durable.Tx` | boundary | unchanged | `announce(tx, topic, message) :: :ok`, recorded as an `{:announce, topic, message}` change. |
| `Photon.Durable.Changes` | core | unchanged | `summarize/1` adds `announcements: [{topic, message}]` in commit order; `scope/1` gives nil for them. |
| `Photon.Durable.Store` | boundary | unchanged | `announce/1` broadcasts each announcement after the commit. Moduledoc lists it. |
| `Photon.Durable.Queries` | core | unchanged | `busy(conversation_ids)` (the live, unowned, foreground runs among them, selecting `conversation_id`), `busy_in_profile(profile)` (the same, over the conversations with that profile) and `last_entry(conversation_id, kind)`. |
| `Photon.Durable` | boundary | unchanged | `busy(conversation_ids)` and `busy_in_profile(profile)`, each `:: MapSet.t(String.t())`, and `last_entry(conversation_id, kind) :: Entry.t() \| nil`. |
| `Photon.Durable.Profile` | contract | unchanged | Optional `workdir/1` (section 3.4). |
| `Photon.Durable.ToolAPI` | boundary | unchanged | `workdir` field, `new/2`; `new/1` keeps nil. |
| `Photon.Durable.ToolTask` | boundary | unchanged | Builds the API with the profile's `workdir/1`, for `execute`, `resume` and `on_interrupt` alike. |
| `Photon.MachineTools.Translate` | core | unchanged | `shell_args(args, workdir)` and `view_image_args(args, workdir)` put `workdir` in `directory`. |
| `Photon.MachineTools.Call` | boundary | unchanged | Passes `api.workdir`. A parked call's check ends the call with `Translate.outdated_machine/1` when its machine is `:outdated` (section 3.4, point 7). |
| `Photon.MachineTools.Shell`, `.ViewImage` | boundary | unchanged | Descriptions say "your working directory". |
| `Photon.MachineTools.ListMachines` | boundary | unchanged | The working directory line when `api.workdir` is set (section 3.4). |
| `Photon.MachineTools.Guide` | core | new; `use Boundary, type: :strict, deps: []` | `shell(where) :: String.t()` (section 3.6). |
| `Photon.MachineTools.MockPhrases` | core | new; `use Boundary, type: :strict, deps: [PhotonCore, PhotonCore.LLM]` | `phrasings/0`, `relay_result/1` (section 3.6). |
| `Photon.MachineTools` | boundary | `use Boundary, deps: [Photon.Durable, Photon.Machines, PhotonCore, PhotonCore.LLM], exports: [Guide, MockPhrases]` | `PhotonCore.LLM` is new, for `MockPhrases`. Moduledoc lists the two modules. |
| `Photon.Machines.Roster` | core | unchanged | `@ops_capability "ops:2"`; moduledoc. |
| `Photon.Machines` | boundary | unchanged | `joined/1` and `push_for/2` push and write nothing for a machine whose status is `:outdated` (section 3.4, point 7). |
| `Photon.Settings` | boundary | unchanged | `reasoning/1`, moved from `Assistant.Prompt`. |

### 6.3 apps/hub: projects and threads

| Module | Layer | Boundary | Notes |
|---|---|---|---|
| `Photon.Projects` | boundary (API, no process) | `use Boundary, deps: [Photon.Durable, Photon.Events, Photon.Repo, PhotonCore, Ecto], exports: [Project, ContextFile]` (not `Rules`: callers outside get its answers through the API) | `subscribe/0`, `subscribe_files/1`, `list/0`, `get/1`, `get_by_slug/1`, `create/1`, `update/2`, `list_files/1`, `get_file/2` (by name, case-insensitive through `key`), `create_file/2`, `save_file/4` (name, content, version), `delete_file/2`, and for thread tools inside their commit `write_file_tx/5`, `edit_file_tx/6`, and for `Photon.Threads` inside its commits `threads_changed_tx/2` (announces `{:projects_changed, id}` when a thread is started or sent a message, so the topic stays this module's). Results: `{:ok, struct}`, `{:error, %{field => message}}` for form input, `{:error, :stale \| :exists \| :not_found}` for saves, `{:error, message}` for tool writes, returned from inside the commit. Validates once with `Projects.Rules` (rule 64), including for `write_file_tx/5` and `edit_file_tx/6`, so the thread tools check nothing themselves; every write is a `Durable.commit/1` that applies the rule's answer and calls `Tx.announce/3`. Moduledoc: what a project is, the slug rules' reason, and that there is no process. |
| `Photon.Projects.Project` | data (Ecto schema) | `use Boundary, type: :strict, deps: [Ecto]` | Section 2.1. |
| `Photon.Projects.ContextFile` | data (Ecto schema) | `use Boundary, type: :strict, deps: [Ecto]` | Section 2.3. |
| `Photon.Projects.Rules` | core | `use Boundary, type: :strict, deps: [Photon.Projects.Project, Photon.Projects.ContextFile]` | `project/2`, `name_from/1`, `slug/1`, `unique_slug/2`, `file_name/1`, `key/1` (the lookup key: `.md` added, downcased), `content/2`, `save_check/2`, `edit/4`, `count/1` ("1,234"). The file's name is an argument of `content/2` and `edit/4` for their messages. IDs and times are arguments. |
| `Photon.Threads` | boundary (API and the `"thread"` profile) | `use Boundary, deps: [Photon.ChatGPT, Photon.Durable, Photon.MachineTools, Photon.Projects, Photon.Repo, Photon.Settings, Photon.Transcript, PhotonCore, PhotonCore.LLM, Ecto], exports: [Thread]` (`Photon.Transcript` for `image/3`, as `Assistant.image/2` uses it; never `Photon.Assistant`, which depends on `Photon.Threads`) | API: `start/2`, `get/1`, `list/1`, `sidebar/1`, `running/1`, `project_id!/1`, `send/3`, `stop/1`, `withdraw/1`, `entries/1`, `busy?/1`, `queued/1`, `subscribe/1`, `image/3`, `latest_answer/1`. Profile: `llm/1`, `system_prompt/1`, `tools/1`, `workdir/1` (section 3.1). `start/2` checks the text isn't blank and creates the conversation, the row and the first submission in one commit (`Tx.create_conversation/2`, `Repo.insert!`, `Durable.submit_tx/4`), and announces `{:projects_changed, project_id}` (`Projects.threads_changed_tx/2`); it returns `{:ok, thread}` or `{:error, :blank \| :not_found}`. `send/3` submits and sets `active_at` in one commit and announces the same; it returns `{:ok, submission}` or `{:error, :blank \| :not_found \| :busy}`. `running(thread_ids)` is the `MapSet` of those running (`Durable.busy/1`). |
| `Photon.Threads.Thread` | data (Ecto schema) | `use Boundary, type: :strict, deps: [Ecto]` | Section 2.4. |
| `Photon.Threads.Rules` | core | `use Boundary, type: :strict, deps: []` | `title/1`, `listing/3`, `file_header/3` (the first line of a read; the reading thread's ID and the other threads' titles name who changed the file, as in `listing/3`), `missing_file/2` (a read's error, listing the names there are), `characters/1` ("1,234 characters"; `Projects.Rules.count/1` isn't exported). |
| `Photon.Threads.Prompt` | core | `use Boundary, type: :strict, deps: [Photon.MachineTools]` (reaches `Guide` through its parent's export; section 3.6) | `system_prompt(project, now)` (section 3.2); takes a map with `name`, `slug`, `purpose`. |
| `Photon.Threads.MockScript` | core | `use Boundary, type: :strict, deps: [PhotonCore, PhotonCore.LLM, Photon.MachineTools]` | Section 3.5. |
| `Photon.Threads.Tools.ListContextFiles`, `.ReadContextFile`, `.WriteContextFile`, `.EditContextFile` | boundary (durable tools) | inside `Photon.Threads` | Section 3.3. |
| `Photon.Transcript` | core | `use Boundary, type: :strict, deps: [PhotonCore]` | Moved from `Photon.Assistant.Transcript`; adds `typed/2` (section 5.8). |
| `Photon.Assistant` | boundary | deps add `Photon.Projects`, `Photon.Threads`, `Photon.Transcript`; `exports: [Notice]` | `page_at/1`; `send/2` takes `page:`; uses `Settings.reasoning/1`; `image/2` uses `Photon.Transcript`. |
| `Photon.Assistant.Page` | core | `use Boundary, type: :strict, deps: []` | `at/1`, `of_project/1`, `of_file/2`, `of_thread/2`, `note/2`, with the bounds in section 5.9. |
| `Photon.Assistant.Prompt` | core | deps add `Photon.MachineTools` | Uses `Guide.shell/1`; the page-note line; `reasoning/1` goes. |
| `Photon.Assistant.MockScript` | core | deps add `Photon.MachineTools` | Machine phrasings from `MockPhrases`; matches the last text part; `here`. |
| `Photon.Assistant.Notice` | core | deps `[PhotonCore, Photon.Transcript]` | Alias change only. |
| `Photon` | namespace | `exports` add `Projects`, `Projects.Project`, `Projects.ContextFile`, `Threads`, `Threads.Thread`, `Transcript`; drop `Assistant.Transcript` | Moduledoc lists the two contexts and the new pure modules. |

### 6.4 apps/hub: web

| Module | Layer | Notes |
|---|---|---|
| `PhotonWeb.Router` | boundary | Section 5.1. Every route lands in one task (S8), so `~p` links in the sidebar and pages always match a route. |
| `PhotonWeb.Shell` | boundary (on_mount hook) | `projects` and `running` in `@shell`; subscribes to `Projects.subscribe/0`; section 5.2. |
| `PhotonWeb.Layouts` | boundary (UI) | The sidebar of section 5.2; `active` takes tuples. Moduledoc updated. |
| `PhotonWeb.ConversationComponents` | boundary (UI components) | Section 5.8. |
| `PhotonWeb.ConversationView` | boundary (socket helpers for conversation pages) | Section 5.8. Calls only `Photon.Transcript` and the context passed in; it is not a LiveView, but follows the `LiveViewLogic` rules all the same. |
| `PhotonWeb.ConversationImageController` | boundary | Renamed from `BlipImageController`; `blip/2` and `thread/2`. |
| `PhotonWeb.BlipLive` | server (LiveView) | Uses the shared components and helpers; the page chip and the `page` event (section 5.9). |
| `PhotonWeb.ProjectNewLive`, `ProjectLive`, `ContextFileLive`, `ThreadLive` | server (LiveViews) | Sections 5.3 to 5.7. Each callback hands its message to `Photon.Projects`, `Photon.Threads` or the shared helpers in at most 15 lines (rule 30). `ProjectLive` streams its threads and files (section 5.4). |
| `PhotonWeb.ProjectText` | functional core (web formatting) | The project pages' words for times ("5 minutes ago"), file sizes ("4.2 KB") and who changed a file ("by you", `by "Fix the pump"`), given the time and the thread titles. `ProjectLive` uses it, and `ContextFileLive`'s `#file-meta` can. |
| `PhotonWeb.OverviewLive`, `NodesLive`, `SettingsLive` | server (LiveViews) | `active={:home}` for the overview; nothing else. |

### 6.5 Credo and Boundary lists

`apps/hub/.credo.exs`:

- `FunctionalCore` `core_modules`: add `Photon.Projects.Project`,
  `Photon.Projects.ContextFile`, `Photon.Projects.Rules`,
  `Photon.Threads.Thread`, `Photon.Threads.Rules`,
  `Photon.Threads.Prompt`, `Photon.Threads.MockScript`,
  `Photon.MachineTools.Guide`, `Photon.MachineTools.MockPhrases`,
  `Photon.Assistant.Page`; rename `Photon.Assistant.Transcript` to
  `Photon.Transcript`.
- `ProcessNameOwnership` `api_modules`: add `"Photon.Projects"` and
  `"Photon.Threads"`. No new `names`.
- No `PreferCall`, `NoSleep` or `DiscardNeedsReason` entries.

`apps/node/.credo.exs` and `apps/core/.credo.exs`: unchanged.

## 7. Test plan

General rules, as in step 1: core logic in `test/core` with plain inputs
(rule 52); boundary tests through the public API with `assert_receive`,
`start_supervised!/1` and no sleeping (rule 55), without retesting core
tables (rule 53); LiveView tests through element IDs with
`has_element?/2`, `element/2`, `render_submit/2` and `render_change/2`,
never raw HTML.

### 7.1 Core (apps/hub `test/core`)

- `projects/rules_test.exs`: purpose required and capped; the derived
  name (first sentence, 40 characters at a word boundary, punctuation
  dropped); slugs: accents (`Café Notes` to `cafe-notes`), punctuation
  runs, leading and trailing junk, 40-character cut back to a hyphen,
  empty to `project`, `new` to `new-project`; `unique_slug/2` with `-2`
  and `-3`; file names (adds `.md`, keeps `README.md`, refuses `../x`,
  `a/b.md`, `.hidden.md`, 65 characters, a space); content at 100,000
  and 100,001 characters; `save_check/2` for each case; `edit/4` found
  once, not found, found three times.
- `threads/rules_test.exs`: titles (first non-blank line, collapsed,
  60-character cut with `...`); `listing/3` names "you", "the user" and
  another thread's title, and says when there are no files.
- `threads/prompt_test.exs`: has the name, the purpose, the folder path
  with the slug and the shared shell lines; the same text for two times
  within one hour. (That nothing about the user gets in is checked on the
  profile's `system_prompt/1` in `threads_test.exs`, section 7.2, since
  the pure function never sees Settings.)
- `threads/mock_script_test.exs`: each phrasing to its tool call and
  arguments, relay of results and errors, the help text.
- `assistant/page_test.exs`: `at/1` gives `{:project, "x"}` for
  `/projects/x`, `/projects/x/threads/new` and `/projects/x/files/new`,
  `{:file, "x", "a.md"}` for `/projects/x/files/a.md`, `{:thread, "x",
  id}` for `/projects/x/threads/<id>`, and nil for `/`, `/nodes` and
  `/projects/new`, each with and without a trailing slash;
  `of_project/1`, `of_file/2` and `of_thread/2` labels; `note/2` for a
  file page names the file and includes its content; each bound hit
  (long purpose, 31 files, 11 threads, a 5,000-character file, a
  2,000-character answer).
- `assistant/prompt_test.exs`: today's text is unchanged except the
  page-note line (the `Guide` extraction is a no-op).
- `assistant/mock_script_test.exs`: matches the last text part; `here`
  with and without a note.
- `machine_tools/guide_test.exs`: both `where` texts.
- `machine_tools/translate_test.exs`: `directory` is the given workdir,
  or nil.
- `machines/roster_test.exs`: `ops:2` is online, `ops:1` alone is
  outdated.
- `durable/changes_test.exs`: announcements are collected in order and
  belong to no scope.
- `transcript_test.exs` (moved from `assistant/`): plus `typed/2`.

### 7.2 Boundary (apps/hub `test/boundary`)

- `durable_test.exs`: `Tx.announce/3` reaches a subscriber only after
  the commit (subscribe, commit, `assert_receive`); a rolled-back commit
  announces nothing (`refute_receive`); `busy/1` and `last_entry/2`.
- `tool_task_workdir_test.exs` (`@tag :durable`): with a test profile
  that implements `workdir/1` (add it to `Photon.TestProfile` as an
  option, or a new `Photon.TestProfile.Workdir`), a tool sees
  `api.workdir` in `execute/2`, `resume/2` and `on_interrupt/2`; the
  assistant profile gives nil.
- `machines_test.exs`: `joined/1` and `push_for/2` for a machine
  connected with `["ops:1"]` return no pushes and leave its open rows
  unpushed.
- `machine_tools_test.exs`: a `shell` call made with a workdir records
  an op row whose `args["directory"]` is the slug; `list_machines` with
  a workdir names the folder. A call parked on a known machine that is
  offline, which then connects with `["ops:1"]`
  (`Photon.MachineOps.connect/2`): no `op.start` is pushed to it
  (`refute_receive`), and the call ends with the outdated message at its
  next check, its row canceled; connecting again with `["ops:2"]`
  pushes no `op.start` for that call, only the `op.cancel` its canceled
  row keeps.
- `projects_test.exs`: create (slug, derived name, unique suffix when two
  projects share a name), update (slug unchanged, name derived again when
  cleared), errors as field maps; files: create, case-insensitive
  lookup, `:exists`, save with the right version bumps it, save with an
  old one is `:stale`, delete; each write announces
  `{:projects_changed, id}` or `{:project_files_changed, id, key}`
  (`assert_receive`); `write_file_tx/5` inside a commit that rolls back
  leaves no file and no announcement.
- `threads_test.exs` (`@tag :durable`, scripted model): `start/2` makes
  the row, the conversation (profile `"thread"`) and the first message,
  and the scripted answer arrives (`assert_receive {:durable, id, _}`
  until an answer entry); a blank first message is refused and makes
  nothing; `send/3` moves `active_at` and announces
  `{:projects_changed, id}`; `sidebar/1` groups, orders by `active_at`,
  limits to five, adds a running thread past the five, and counts the
  rest; `running/1` while a run is live and after; `stop/1`; the profile's tools are exactly the seven
  (no `schedule`, `update_memory` or anything that starts threads);
  `system_prompt/1` leaves out what Settings and memory hold.
- `thread_file_tools_test.exs` (`@tag :durable`): through the scripted
  model, `write notes.md: hello` creates the file with `updated_by` the
  thread's ID and announces it; `read notes.md` returns it; `edit
  notes.md: hello => bye` changes it; `edit` with text that isn't there
  returns the error and changes nothing; `files` lists it; `read` of a
  missing file lists the names there are. (That a stopped call keeps
  none of its commit's writes is the harness's `{:commit, fun}` contract
  in `Photon.Durable.Tool`; `projects_test.exs` covers a rolled-back
  `write_file_tx/5`.)
- `assistant_test.exs`: `page_at/1` for a project, a context file, a
  missing file (nil), a thread, a thread under the wrong slug (nil) and
  an unknown slug (nil); `send/2` with a
  page submits two parts and the page in `source`.

### 7.3 Node (apps/node `test/boundary`)

- `shell_test.exs` or `executor_test.exs`: an op whose `directory` is
  `<workspace>/proj` (missing) creates it and the command runs there
  (`pwd` output); a second op in it finds it; a directory blocked by a
  plain file fails with the "couldn't create" message and runs nothing
  (the command would touch a marker file, which must not exist).
- `connection_test.exs`: the join lists `ops:2`, and only it.

### 7.4 LiveView (apps/hub `test/web/live`)

- `sidebar_test.exs`: `#nav-home`, `#new-project`, `#nav-machines` with
  the online count and no `#side-node-*`; a project created by another
  process appears as `#side-project-<slug>` with `#new-thread-<slug>`;
  a started thread appears as `#side-thread-<id>`, with
  `[data-running=true]` while it runs and not after; six threads show
  five and `#side-more-<slug>`; sending a message to the sixth (oldest)
  thread moves it into the five, and it shows `[data-running=true]`
  while it runs; a project "Garden more" next to "Garden" with six
  threads renders `#side-project-garden-more` and `#side-more-garden`
  once each. Update `pages_test.exs`,
  `overview_live_test.exs` and `nodes_live_test.exs` for the new IDs.
- `project_new_live_test.exs`: a blank purpose shows the error under
  `#project-form`; a purpose alone creates the project and navigates to
  `/projects/<slug>` (`assert_redirect` or `follow_redirect`).
- `project_live_test.exs`: `#project-name`, `#project-folder` with the
  slug, `#project-purpose`; `#edit-project` then `#project-edit-form`
  saves; `#project-threads` (`phx-update="stream"`) lists
  `#project-thread-<id>` with running state, and a message sent to an
  older thread moves its row to the top; `#context-files` lists files and updates when a thread's tool
  writes one (commit through `Projects.write_file_tx/5` in the test);
  `#project-new-thread` and `#new-file` link where they should; an
  unknown slug redirects to `/`.
- `context_file_live_test.exs`: create through `#file-form`; a bad name
  shows the rule; edit and save bumps `#file-meta`'s version; a write by
  a thread while the form is clean reloads the text; while dirty
  (`render_change` on `#file-form`) it shows `#file-changed`, and
  `#file-reload` loads it; a save with an old version shows the banner
  and keeps the typed text; `#file-delete` deletes and returns to the
  project; `#file-tab-preview` shows `#file-preview`.
- `thread_live_test.exs` (`@tag :durable`, scripted model, a connected
  test machine from `Photon.MachineOps.connect/2` with `ops:2`): `:new`
  sends through `#thread-composer` and lands on the thread page;
  `on box: $ ls` shows `#thread-action-<call id>` naming `box`, streams a
  `tool_output` event into its tail, and shows the result; an image
  result's `img` points at `/threads/<id>/images/...`; while busy,
  `#thread-stop` ends the run and `#thread-queued-<id>` can be
  withdrawn; `#thread-status` follows the run; Blip's `#composer` and the
  thread's `#thread-composer` are both on the page with no duplicate IDs
  (`LazyHTML` count of each ID is 1).
- `blip_live_test.exs`: the existing tests pass unchanged after S7; on a
  project page, a context file's page, the new-thread page and a thread
  page, `#page-chip` shows the label after the hook's `page` event
  (`render_hook`), and on `/projects/new` it doesn't;
  `#page-chip-dismiss` hides it;
  sending `here` with the chip gets the note's first line back from the
  scripted model, and the user bubble shows only "here" with the "About"
  line; without the chip, "I don't know which page you're on."
- `test/web/controllers/conversation_image_controller_test.exs`: renamed
  from `blip_image_controller_test.exs`, plus a thread image, and a Blip
  entry ID asked for under a thread's route is a 404.

### 7.5 End to end

`apps/hub/test/integration/machine_tools_e2e_test.exs` gains a thread
test against the real local node: start a project, start a thread with
`on local: $ pwd`, and the result ends in `/workspace/<slug>`, the folder
exists in the node's data dir, and a second thread's `on local: $ ls`
in the same project sees a file the first one wrote there.

### 7.6 Checks

In every app the step touches (`apps/node` and `apps/hub`; `apps/core`
only if a shared module moves there, which this plan doesn't do):

- `mix precommit`
- `mix dialyzer`; any new ignore entry has a reason comment
- `mix test --cover` at the apps' thresholds (node and hub 85)
- `cd apps/core && mix test ../../tools/credo_checks/test` only if a
  credo check's code changes (none planned)
- After pulling, `mix compile --force` in `apps/hub` clears stale
  Boundary warnings from the moved `Transcript`

## 8. OTP rules that apply

| Rule | Where it bites |
|---|---|
| 2, 3, 31, 89 | No new process. A thread is a durable conversation; the harness already runs many (its tasks are the workers). `Photon.Projects` and `Photon.Threads` are APIs over the database and the commit line, like `Photon.Machines`. The sidebar's data is read by the existing `PhotonWeb.Shell` hook. |
| 6, 69 | One API per context: `Photon.Projects` and `Photon.Threads` export only their schemas, as `Photon.Durable` does. Errors are maps of field to message or short atoms, never changesets. |
| 11 | LiveViews call `Photon.Projects`, `Photon.Threads` and `Photon.Assistant`, and the shared helpers; no Repo, Ecto or PubSub in them (`LiveViewLogic`). |
| 15 | Files keep a version and who wrote them; a thread's running state is derived from its durable run, not stored. |
| 28, 29 | `Projects.Rules`, `Threads.Rules`, `Threads.Prompt`, `Threads.MockScript`, `Assistant.Page`, `MachineTools.Guide`, `MachineTools.MockPhrases` and `Transcript` are strict-Boundary pure modules. IDs (`p_`, `f_`) and times are minted in the APIs and passed in. |
| 30 | Every `handle_event`, `handle_info` and `handle_params` hands off in at most 15 lines; `ConversationView` keeps the two conversation pages' folds short. |
| 61 | Threads reuse the durable harness, its inbox, its abort and its live events; announcements reuse the Store's post-commit broadcast instead of a second mechanism. |
| 64 | Form input and tool arguments are checked once, in `Projects.Rules` through `Photon.Projects` (for thread tools, inside `write_file_tx/5` and `edit_file_tx/6`); everything behind trusts them. The node still checks `op.start` on its side. |
| 67 | Errors say what to do: the file-name rule with an example, "Split it into more than one file", the stale-save banner, the node's "couldn't create the working directory ... The command didn't run." |
| 73 | The sidebar rebuilds only when a changed task belongs to a listed thread, and lists five threads a project plus the running ones. The project page streams its lists rather than holding them. The page note is bounded (section 5.9). Context files are capped at 100,000 characters; old tool results are already shortened in context (step 1, 3.6). |
| 75 | A node without `ops:2` is reported outdated rather than sent work it would fail: a new call to it fails at the start, it gets no `op.start` when it joins, and a call parked on it ends with the outdated message at its next check. |
| 86 | Nothing new to lose in a crash: projects, files and threads are rows, announcements are hints every page re-reads on mount, and a thread's tool calls are durable as Blip's are. |

## 9. Is a TLA+ spec needed?

No. This step adds no concurrency protocol:

- A thread is one more conversation under the durable harness.
  `specs/tla/Durable.tla` already models the harness for any number of
  conversations, with machine tool calls, Stop, crashes and restarts, and
  the thread profile adds no task kind, wait state or signal.
- A context-file write is one commit on the Store's single line, made in
  the same commit as the tool result that reports it. Two writers
  serialize there; the user's version check and the edit tool's
  exactly-once match are decisions inside one commit, with nothing in
  flight between processes.
- `Tx.announce/3` broadcasts after the commit, like the existing
  `durable:*` announcements, and pages re-read on every hint.
- The node's directory creation happens in `prepare_files/1`, before the
  `process` checkpoint that `Executor.tla` models, and is idempotent, so
  every resume path of that spec still holds.

The specs stay as they are. If step 4's `ask_blip` (a thread waiting
durably on Blip, and Blip on the user) comes next, that is the protocol
worth modeling.

## 10. Ordered tasks

Each task is small enough for one agent, names its files and ends with
`mix precommit` passing in the apps it touched. "After" lists what must be
merged first. S1, S2 and S3 can start at once.

Two ordering rules shape the web half. Layouts and LiveViews build links
with `~p`, which warns at compile time when no route matches, and
`precommit` compiles with `--warnings-as-errors`; so every route arrives
in S8, with minimal LiveViews, before anything links to one. And a pure
module reaches another context's pure module only through that context
(section 3.6), so the contexts come before the modules that use them.

S1. Durable: announcements, busy runs, last entry, working directory.
- `apps/hub/lib/photon/durable/tx.ex` (`announce/3`),
  `durable/changes.ex` (`announcements`), `durable/store.ex` (broadcast
  them), `durable/queries.ex` and `durable.ex` (`busy/1`,
  `busy_in_profile/1`, `last_entry/2`), `durable/profile.ex` (optional
  `workdir/1`), `durable/tool_api.ex` (`workdir`, `new/2`),
  `durable/tool_task.ex` (build the API with the profile's `workdir/1`).
- Tests: `test/core/durable/changes_test.exs`,
  `test/boundary/durable_test.exs`,
  `test/boundary/tool_task_workdir_test.exs`, and a workdir option in
  `test/support/test_profile.ex` (section 7.2).

S2. The node makes the working directory; capability `ops:2`; outdated
nodes get no work.
- `apps/node/lib/photon_node/ops/shell.ex`,
  `apps/node/lib/photon_node/connection.ex`,
  `apps/node/lib/photon_node.ex` (moduledoc).
- `apps/hub/lib/photon/machines/roster.ex`; `apps/hub/lib/photon/machines.ex`
  (`joined/1` and `push_for/2` skip an outdated machine);
  `apps/hub/lib/photon/machine_tools/call.ex` (a parked call ends with the
  outdated message); the comment in
  `apps/hub/lib/photon_web/channels/node_channel.ex` (section 3.4, points
  6 and 7).
- Tests: node `test/boundary/shell_test.exs` (or `executor_test.exs`)
  and `connection_test.exs`; hub `test/core/machines/roster_test.exs`,
  `test/boundary/machines_test.exs` and the parked-call case in
  `test/boundary/machine_tools_test.exs`; `ops:1` to `ops:2` in
  `test/support/machine_ops.ex`, `test/boundary/assistant_test.exs` and
  `test/boundary/machine_tools_test.exs`.

S3. Move the transcript fold. No dependencies.
- Move `apps/hub/lib/photon/assistant/transcript.ex` to
  `apps/hub/lib/photon/transcript.ex` as `Photon.Transcript`; add
  `typed/2`.
- Update `assistant.ex` (deps, exports), `assistant/notice.ex`,
  `photon_web/live/blip_live.ex`, `lib/photon.ex` exports,
  `.credo.exs`.
- Move `test/core/assistant/transcript_test.exs` to
  `test/core/transcript_test.exs`; add `typed/2` cases.

S4. Machine tools take the working directory; shared guidance and mock
phrasings. After S1 and S2 (S2 also changes `call.ex` and
`machine_tools_test.exs`).
- `apps/hub/lib/photon/machine_tools/translate.ex`, `call.ex`,
  `shell.ex`, `view_image.ex`, `list_machines.ex`.
- New `machine_tools/guide.ex` and `machine_tools/mock_phrases.ex`;
  `machine_tools.ex` exports them and adds `PhotonCore.LLM` to its deps.
- `apps/hub/lib/photon/assistant/prompt.ex` uses `Guide.shell/1` (text
  unchanged, Boundary deps `[Photon.Assistant.Memory,
  Photon.MachineTools]`) and loses `reasoning/1`;
  `apps/hub/lib/photon/settings.ex` gains it; `assistant.ex` calls it;
  `assistant/mock_script.ex` uses `MockPhrases` (deps add
  `Photon.MachineTools`).
- `apps/hub/.credo.exs`: `Guide`, `MockPhrases` in `FunctionalCore`.
- Tests: `translate_test.exs`, `guide_test.exs`, `settings_test.exs`,
  `prompt_test.exs` (unchanged text), `mock_script_test.exs`,
  `machine_tools_test.exs` (directory in the row, the `list_machines`
  line).

S5. The projects context. After S1.
- Migration `20261007000000_create_projects.exs`;
  `test/support/data_case.ex` `@tables`.
- New `apps/hub/lib/photon/projects.ex`, `projects/project.ex`,
  `projects/context_file.ex`, `projects/rules.ex` (sections 2.1 to 2.3,
  6.3, events in section 4). `write_file_tx/5` and `edit_file_tx/6`
  validate and return `{:error, message}` from inside the commit (section
  3.3).
- `apps/hub/lib/photon.ex`: exports and moduledoc.
- `apps/hub/.credo.exs`: the three core modules; `Photon.Projects` in
  `api_modules`.
- Tests: `test/core/projects/rules_test.exs`,
  `test/boundary/projects_test.exs`.

S6. The threads context and the `"thread"` profile. After S3, S4 and S5.
- Migration `20261007010000_create_threads.exs` (with `active_at`);
  `@tables`.
- New `apps/hub/lib/photon/threads.ex`, `threads/thread.ex`,
  `threads/rules.ex`, `threads/prompt.ex`, `threads/mock_script.ex`,
  `threads/tools/list_context_files.ex`, `read_context_file.ex`,
  `write_context_file.ex`, `edit_context_file.ex` (sections 2.4, 3.1 to
  3.5). Boundary deps as in section 6.3: `Photon.Transcript` on
  `Photon.Threads`, `Photon.MachineTools` (not `Guide` or
  `MockPhrases`) on `Prompt` and `MockScript`.
- `apps/hub/config/config.exs` and `config/test.exs`: the profile.
- `apps/hub/lib/photon.ex`: exports and moduledoc.
- `apps/hub/.credo.exs`: the four core modules; `Photon.Threads` in
  `api_modules`.
- Tests: `test/core/threads/{rules,prompt,mock_script}_test.exs`,
  `test/boundary/threads_test.exs`,
  `test/boundary/thread_file_tools_test.exs`.

S7. Share the conversation view; generalize the image controller. After
S3.
- New `apps/hub/lib/photon_web/components/conversation_components.ex`
  and `apps/hub/lib/photon_web/live/conversation_view.ex` (section 5.8),
  taken out of `blip_live.ex`, with `id_prefix` and `image_path`, and
  the context-file tool labels.
- `blip_live.ex` uses them; its rendering and IDs don't change.
- Rename `controllers/blip_image_controller.ex` to
  `controllers/conversation_image_controller.ex` (`blip/2` only for
  now); `router.ex`.
- Tests: `blip_live_test.exs` passes unchanged; rename the controller
  test.

S8. Every route, with minimal pages. After S6 and S7.
- `router.ex`: all of section 5.1, including `/threads/:thread_id/images/...`.
- `ConversationImageController.thread/2` through `Threads.image/3`.
- New `live/project_new_live.ex`, `live/project_live.ex`,
  `live/context_file_live.ex`, `live/thread_live.ex`, each only a mount
  that loads its project (and file or thread) through `Photon.Projects`
  and `Photon.Threads`, redirects to `/` with the flash of section 5.1
  when it's missing, and renders `<Layouts.app ...>` with a heading. The
  later tasks fill them in.
- Tests: the controller test's thread cases (a thread image; a Blip
  entry under a thread's route is a 404); a mount test per route and its
  not-found redirect, which the later tasks extend.

S9. The sidebar. After S8.
- `apps/hub/lib/photon_web/shell.ex` (section 5.2),
  `components/layouts.ex` (the sidebar, `active` tuples),
  `live/overview_live.ex` (`active={:home}`), and `active` on the four
  pages from S8.
- Tests: new `test/web/live/sidebar_test.exs`; update `pages_test.exs`,
  `overview_live_test.exs`, `nodes_live_test.exs`.

S10. New project and the project page. After S8.
- Fill in `live/project_new_live.ex` and `live/project_live.ex`
  (sections 5.3, 5.4; threads and files as streams).
- Tests: `test/web/live/project_new_live_test.exs`,
  `test/web/live/project_live_test.exs`.

S11. The context file editor. After S8.
- Fill in `live/context_file_live.ex` (section 5.5).
- Tests: `test/web/live/context_file_live_test.exs`.

S12. Thread pages. After S8.
- Fill in `live/thread_live.ex` (sections 5.6, 5.7), with the shared
  pieces from S7.
- Tests: `test/web/live/thread_live_test.exs`.

S13. Blip's page context. After S10, S11 and S12 (its LiveView tests
open a project page, a context file, the new-thread page and a thread).
- New `apps/hub/lib/photon/assistant/page.ex` (section 5.9).
- `assistant.ex` (`page_at/1`, `send/2` with `page:`, the facts; deps add
  `Photon.Projects` and `Photon.Threads`), `assistant/prompt.ex` (the
  page-note line), `assistant/mock_script.ex` (last text part, `here`).
- `blip_live.ex`: the hook's `page` reports, the `page` and
  `dismiss_page` events, the chip; `conversation_components.ex`: the
  "About" line under a user message with a page.
- `apps/hub/.credo.exs`: `Photon.Assistant.Page` in `FunctionalCore`.
- Tests: `test/core/assistant/page_test.exs`, `prompt_test.exs`,
  `mock_script_test.exs`, `test/boundary/assistant_test.exs`,
  `blip_live_test.exs` (section 7.4).

S14. End to end, docs and the final checks. After all of the above.
- `apps/hub/test/integration/machine_tools_e2e_test.exs`: the thread
  test (section 7.5).
- `docs/architecture.md`: the module map (both new contexts, the moved
  `Transcript`, the shared web modules, the renamed controller), the
  hub's supervision tree note (no new processes; the `/live` routes),
  and a step 2 entry at the end of the refactor log.
- `docs/projects-and-blip.md`: a status line under "Build order" and in
  "Hub and nodes" (`ops:2`, the folder made on first use).
- `apps/hub/lib/photon.ex` moduledoc final pass.
- Section 7.6 in `apps/node` and `apps/hub`. The PR description says to
  delete the hub database and reinstall every node (`ops:2`).

## 11. Decisions for the user

None need deciding before the build. The owner's decisions in the task
and in `docs/projects-and-blip.md` settle the model; these are the
choices this plan makes inside them, all reversible:

- A project's name is optional and made from the purpose when blank,
  since the sidebar needs a label and the purpose is the only required
  field.
- The slug is fixed at creation and survives renames, because folders on
  machines are named after it. `new` is reserved.
- No deleting or archiving projects and threads yet, and no renaming
  threads (titles come from the first message). Context files can be
  deleted by the user, not by threads.
- Context files are flat, end in `.md`, and hold up to 100,000
  characters. The user's saves are checked against the version they
  loaded; threads' writes replace the file without a check, and their
  edits must match a passage exactly once.
- Threads get four context-file tools: list, read, write and edit.
  `edit` is beyond the list/read/write the brief named, because it lets a
  thread change one passage without rewriting the file over the user's
  edits.
- Threads can search the web, as Blip can, and use the reasoning setting
  from Settings.
- The node creates a missing working directory, which is a protocol
  change (`ops:2`), so every node needs reinstalling once.
- The sidebar shows each project's five most recently active threads,
  plus any running thread beyond them, with a running dot, and "N more".
  A thread is active when it gets a message.
- The project page shows no placeholders for skills and schedules; its
  second column is where step 3 puts them.
- Blip's page note includes the project's purpose, file names and
  threads, and for a thread the end of its latest answer, so Blip can
  answer "what's left here?" before it has project tools in step 4.

## Review

A review of this plan raised nine findings. All nine hold against the
code and the owner's decisions, and are applied:

- Blip knows the project on every page inside it, and the file on the
  editor (section 5.9, `page_test.exs` in 7.1).
- Threads are ordered by `active_at` everywhere, and the sidebar keeps a
  running thread listed past the five (sections 2.4, 5.2).
- Pure modules reach `Guide` and `MockPhrases` through
  `Photon.MachineTools`, which adds `PhotonCore.LLM` to its deps
  (sections 3.6, 6.2, 6.3). Boundary's `validate_dep_allowed/4` refuses
  the direct deps the plan had.
- Every route, the thread image route included, arrives in S8 with
  minimal LiveViews, so no `~p` link points at a missing route.
- `Photon.Threads` depends on `Photon.Transcript`, and S6 (threads) runs
  after S3 (the move).
- The thread tools validate nothing; `write_file_tx/5` and
  `edit_file_tx/6` check and return `{:error, message}` from inside the
  commit, which `Photon.Durable.Tool`'s `{:commit, fun}` contract allows
  (section 3.3).
- An outdated node gets no ops when it joins, and a call parked on it
  ends with the outdated message (section 3.4, point 7, and S2).
- "N more" is `#side-more-<slug>` (section 5.2).
- The project page streams its threads and files (section 5.4).

Two limits on the last one. `ProjectLive` still keeps a `MapSet` of its
thread IDs, to tell which `{:durable_tasks, _}` messages concern it
without a query per message; that is IDs only, not rows. And the sidebar
stays a plain assign in `@shell`: it is bounded (five threads a project
plus the running ones), and as a stream it would have to be threaded
through every page's own template, since `@shell` is set by an
`on_mount` hook and rendered by `Layouts.app`.

Nothing was rejected.

# Step 3: skills on the hub, and schedules in projects

Plan for build step 3 of `docs/projects-and-blip.md`. Two features land
together:

- **Skills.** Instructions an agent loads when a task calls for them. The
  owner writes them in the app or installs them from a pasted SKILL.md or
  a link. A new skill is off everywhere. Each project has its own set of
  enabled skills and Blip has its own. An agent's prompt lists the enabled
  skills' names and descriptions, and a `load_skill` tool puts one's
  instructions into the conversation.
- **Schedules in projects.** Today's routines become schedules, which can
  belong to a project and, at set times, either start a new thread there
  or wake one of its threads. The owner manages them on the project page.
  Blip keeps its own schedules for things outside projects.

The work ships as one pull request, built as the ordered tasks in section
11. Each section is meant to be read on its own: an agent handed one task
reads section 1, the sections its task points to, and the task. Rule
numbers refer to `docs/otp-design-guide.md`; the short version is
`docs/plans/otp-brief.md`. Paths are relative to the repo root. Module
names are the plan's; the placement is the point.

This plan was written against `impl/step-2` at `7d78c36`, plus the step 2
review work that was in progress there at the time: threads named by the
model after their first run (`Photon.Threads.Titling`, the
`"thread_title"` task kind) and renamed by the owner
(`Photon.Threads.rename/2`). Build on the final step 2. Where this plan
changes `Photon.Threads.start/2`, the titling task it creates stays.

Nothing here keeps old data. Two new migrations add the tables; Blip's
existing routines (durable tasks of kind `"routine"` with the old input
shape) are not carried over. The PR description says to delete the hub
database. Photon has one user.

## 1. Goal and scope

After this step:

- The sidebar has **Skills** (`/skills`), between Machines and Settings.
  The Skills page lists every skill, says where each is turned on, and
  has a switch per skill for Blip.
- The owner writes a skill in the app (name, description, instructions in
  Markdown) or installs one: paste a SKILL.md, or give a link to a
  SKILL.md, a skill's folder on GitHub, or a GitHub folder (or repo) that
  holds several skills. Install keeps only the name, the description and
  the instructions, and says what it left out: other files in the folder,
  front matter fields other than `name` and `description`, and files the
  instructions mention that weren't installed.
- A new or installed skill is off everywhere. The project page has a
  Skills section to turn skills on and off for that project. Blip's set is
  turned on and off on the Skills page and on each skill's page.
- Blip's and every thread's prompt lists the skills enabled for it (name,
  version, description). `load_skill` loads one; its result is the
  instructions. A skill turned off, edited or deleted mid-conversation is
  handled as section 2.7 says.
- Schedules have their own table and context, `Photon.Schedules`. A
  project's schedule starts a new thread in the project each time, or
  wakes one chosen thread. The project page lists them; a form at
  `/projects/:slug/schedules/new` and `/projects/:slug/schedules/:id`
  creates and edits them, and each one can be run now or deleted.
- Blip's `schedule`, `list_schedules` and `cancel_schedule` tools work as
  today, over `Photon.Schedules`, on Blip's own schedules only. The home
  page lists Blip's schedules as today.
- The consent rule holds: a scheduled firing uses the owner's plan only
  when Settings allows scheduled work (or on the scripted model); otherwise
  it is skipped and the skip is recorded where the owner sees it.
- Schedules survive hub restarts, as routines do today: each is a durable
  task waiting for its next time.
- `PHOTON_MOCK_MODEL=1` covers both: the scripted models list and load
  skills, and scheduled prompts reach them.

Out of scope, for later steps:

- Blip's tools over projects and threads, `ask_blip`, the home page and
  ambient mode (steps 4 and 5). Blip can't see or change project
  schedules or project skill sets; its schedule tools touch only its own.
- Skills scoped to machines, and skills with scripts or other files.
  Section 2.5 says where machine scoping would go.
- Re-fetching an installed skill from its source to update it, and
  exporting a skill as a SKILL.md file.
- Pausing a schedule (delete and recreate it), calendar rules such as
  "weekdays at 9", and repeats that follow the owner's time zone across
  daylight saving changes (section 3.9).
- Schedules created by threads. Threads have no schedule tools, since a
  schedule that starts threads would let a thread start threads.

## 2. Skills

### 2.1 Data

Two tables, behind `Photon.Skills` (section 7.2). Every write goes through
`Photon.Durable.commit/1` and announces with `Tx.announce/3`, as
`Photon.Projects` does.

Table `skills`, schema `Photon.Skills.Skill`:

| Column | Type | Notes |
|---|---|---|
| `id` | string, primary key | `sk_<suffix>`, minted by `Photon.Skills` with `PhotonCore.ID.new("sk_")` |
| `name` | string, not null, unique index | section 2.2; what the agent passes to `load_skill` and what the URL uses |
| `description` | text, not null | when to use it; this is what agents see before loading |
| `instructions` | text, not null | Markdown, the SKILL.md body |
| `version` | integer, not null | 1 when created, plus 1 on every save |
| `origin` | string, not null | `"written"`, `"pasted"` or `"fetched"` |
| `source_url` | string, null | for `"fetched"`: the link the SKILL.md came from (for a skill found in a folder, its own `github.com/.../blob/...` address) |
| `install_notes` | text, null | what install left out and why, as shown at install (section 2.4), kept for the skill's page |
| `files_left_out` | `{:array, :string}`, not null, default `[]` | the paths install left out that an agent might go looking for: the ones the instructions mention first, then the folder's other files, at most 20, deduplicated. `Prompt.loaded/1` names them (section 2.6). `[]` for a written skill. `ecto_sqlite3` stores it as JSON |
| `inserted_at`, `updated_at` | `utc_datetime_usec` | |

Table `skill_enablements`, schema `Photon.Skills.Enablement`, no primary
key column:

| Column | Type | Notes |
|---|---|---|
| `skill_id` | string, not null, references `skills` (`on_delete: :delete_all`) | |
| `scope` | string, not null | `"blip"`, or a project's ID (`p_...`) |
| `inserted_at` | `utc_datetime_usec` | |

Unique index on `[scope, skill_id]`, and an index on `skill_id`. `scope`
is a string rather than a foreign key so Blip and projects share one
table; projects aren't deleted in this product yet, and when they are, the
delete removes the project's rows in the same commit.

In code, a scope is `:blip | {:project, project_id}`; only
`Photon.Skills` turns it into the column's string.

### 2.2 Rules

`Photon.Skills.Rules` (pure). Errors are a map of field to message, as in
`Photon.Projects.Rules`.

- `name`: trimmed. 1 to 64 characters of lowercase letters, digits and
  single hyphens, not starting or ending with a hyphen
  (`~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/`), which is the SKILL.md format's rule.
  Otherwise: `A skill's name uses lowercase letters, digits and hyphens,
  like "pdf-forms".` `new` and `install` are reserved (the routes use
  them): "That name is taken by the app; pick another." A name another
  skill has: "There's already a skill called pdf-forms." (checked inside
  the commit, backed by the unique index).
- `suggest_name(text)`: what install prefills when a SKILL.md's name
  breaks the rule: NFD-normalized with combining marks dropped,
  downcased, every run outside `a-z0-9` replaced by one `-`, trimmed of
  `-`, cut to 64; empty gives `skill`. "PDF Forms" becomes `pdf-forms`.
- `description`: trimmed; required ("Say when an agent should use this
  skill."); at most 1,024 characters ("Keep the description under 1,024
  characters; agents read it on every request."). Stored as written; the
  prompt collapses its whitespace (section 2.6).
- `instructions`: required after trimming ("A skill needs instructions.");
  at most 50,000 characters, counted in code points ("pdf-forms's
  instructions are 61,234 characters; the limit is 50,000, since a skill
  is loaded whole into the conversation.").
- `save_check(current_version, expected_version)`: `:ok` or `:stale`, as
  context files do. The skill page sends the version it loaded.
- `mentions(instructions, left_out)`: the paths in `left_out` that the
  instructions name (as written, or as a Markdown link target), so install
  can say "The instructions mention scripts/fill.py, which wasn't
  installed." With no folder listing (a paste), `left_out` is empty and
  `mentions/2` falls back to relative link targets and backticked paths
  under `scripts/`, `references/` or `assets/`, or ending in `.py`, `.sh`,
  `.js` or `.ts`.
- `enable_check(enabled_count)`: at most 30 skills per scope ("30 skills
  are on here already. Turn one off first: agents read every enabled
  skill's description on every request."). This bounds the prompt (rule
  73).

### 2.3 The SKILL.md format Photon reads

`Photon.Skills.SkillMd.parse(text)` (pure) reads the common format: YAML
front matter between a first line `---` and the next line `---`, then the
body.

```
---
name: pdf-forms
description: Fill in PDF forms. Use when the user asks to fill or flatten a PDF form.
license: Apache-2.0
allowed-tools: Bash(python:*)
---

# PDF forms

...
```

There is no YAML library in the project, and AGENTS.md says not to add
dependencies without asking, so `SkillMd` parses the subset that SKILL.md
files use:

- a leading byte order mark and `\r\n` line ends are accepted
- top-level `key: value` lines; a key is everything before the first `:`
- values: plain (with indented continuation lines folded into one line),
  single-quoted (`''` is a quote), double-quoted (`\"`, `\\`, `\n`, `\t`
  escapes), and block scalars `|`, `|-`, `>` and `>-` with their indented
  lines
- a key whose value is a nested block (`metadata:` followed by indented
  lines) is skipped as a whole and counted as ignored
- comments (`# ...` on their own line) are skipped

It returns `{:ok, %{name, description, instructions, ignored}}`, where
`ignored` lists the other top-level keys in order (`["license",
"allowed-tools"]`), or `{:error, message}`:

- no front matter: "A SKILL.md starts with front matter: a line `---`,
  then `name:` and `description:`, then `---`."
- front matter that never closes: "The front matter never ends: add a
  line `---` after it."
- empty body: "This SKILL.md has no instructions after its front matter."

A missing `name` or `description` is not a parse error: install opens the
preview with that field empty and the rule's message under it, so the
owner can fill it in.

### 2.4 Installing

Two ways in, both ending in a preview where the owner checks, edits and
installs (section 6.5).

**Paste.** `Photon.Skills.read(text)` runs `SkillMd.parse/1` and returns
one candidate (below), with `origin: "pasted"`.

**A link.** `Photon.Skills.fetch(url)` returns `{:ok, [candidate]}` or
`{:error, message}`. It is the only place Photon fetches skills; it runs
in the install page's `start_async` task, never in a LiveView callback.
`Photon.Skills.Source` (pure) decides what a link is and turns GitHub's
answers into candidates; `Photon.Skills.Fetch` (boundary) makes the
requests with `Req`.

`Source.classify(url)`:

| Link | Means |
|---|---|
| not `http://` or `https://` | error: "Give an https:// link to a SKILL.md, or to a folder on GitHub." |
| `https://github.com/<o>/<r>` (optionally `.git` or a trailing `/`) | the repo's root folder, on its default branch |
| `https://github.com/<o>/<r>/tree/<ref>/<path>` | a folder |
| `https://github.com/<o>/<r>/blob/<ref>/<path>` | a file (expected to be a SKILL.md) |
| `https://raw.githubusercontent.com/<o>/<r>/<ref>/<path>` | a file |
| anything else | a file at that address |

`<ref>` is taken as the first path segment after `tree` or `blob`. A
branch name with a slash in it then misses, and the 404 message says so
(below).

For a GitHub link, `Fetch` makes at most two API calls and then one raw
download per SKILL.md:

1. With no ref (a repo root link): `GET
   https://api.github.com/repos/<o>/<r>` for `default_branch`.
2. `GET https://api.github.com/repos/<o>/<r>/git/trees/<ref>?recursive=1`:
   the whole tree in one call. `Source.skills_in_tree(tree, path, kind)`
   (pure) finds the candidates:
   - a file link: the file's folder is the skill's folder
   - a folder link whose folder has a `SKILL.md`: that folder
   - any other folder link: every folder under it that has a `SKILL.md`,
     at any depth, sorted by path, at most 30 ("This folder has 41
     skills; showing the first 30. Link to a deeper folder for the
     rest."); a `SKILL.md` inside another candidate's folder belongs to
     that candidate and is skipped
   - none: "There's no SKILL.md in that folder."
   - a tree GitHub marks `truncated`: "That repository is too big to list
     in one go. Link to the skill's folder or its SKILL.md instead."

   For each candidate, `left_out` is every other file under its folder,
   as paths relative to it (`scripts/fill.py`, `reference.md`), at most
   20 named and then "and 14 more".
3. `GET https://raw.githubusercontent.com/<o>/<r>/<ref>/<folder>/SKILL.md`
   for each candidate, through `Task.async_stream/3` with
   `max_concurrency: 6`, `timeout: 20_000` and `on_timeout: :kill_task`
   (bounded, rule 93; the stream runs inside the page's `start_async`
   task). A candidate whose download fails keeps its error and is shown
   unselectable.

If the tree call fails but the link was to a file, the file is still
downloaded on its own, with the note "Couldn't list the folder on GitHub,
so other files it may have weren't checked."

For any other link, `Fetch` downloads it as a file.

Every download:

- `Req.get/2` with `retry: false`, `receive_timeout: 15_000`,
  `redirect: true` with at most 3 redirects, and the app's
  `req_options` (`config :photon, Photon.Skills, req_options: [...]`,
  a `Req.Test` plug in tests, as `Photon.ChatGPT` does)
- stops reading past 256 KB (`into:` a collector that halts) and refuses:
  "That file is over 256 KB, too big for a skill."
- refuses a `text/html` response, or a body starting with `<!DOCTYPE` or
  `<html`: "That link is a web page, not a SKILL.md. Link to the file on
  GitHub, or to its raw address."
- refuses a body that isn't UTF-8: "That file isn't text."
- turns HTTP errors into what to do: 404 "GitHub says there's nothing at
  <path>. If the branch name has a slash in it, link to the SKILL.md's
  raw address instead." (non-GitHub: "Nothing at that address (404).");
  403 or 429 from the API "GitHub's limit for requests without a sign-in
  was reached. Try again within the hour, or paste the SKILL.md."; a
  timeout "The download didn't finish in 15 seconds."; anything else
  "The download failed: <status or reason>."

A candidate is a plain map:

```elixir
%{
  path: "skills/pdf-forms",          # the folder, "" for a paste or plain link
  source_url: "https://github.com/o/r/blob/main/skills/pdf-forms/SKILL.md",
  name: "pdf-forms",                 # as found, or suggest_name/1's when it breaks the rule
  description: "...",
  instructions: "...",
  notes: ["Left out: scripts/fill.py, reference.md. Photon skills are instructions only.",
          "Ignored front matter: license, allowed-tools.",
          "The instructions mention scripts/fill.py, which wasn't installed."],
  error: nil                         # or the message for a candidate that can't be installed
}
```

The notes are built by `Source.notes/3` (pure) from `left_out`, the
parser's `ignored` keys, `Rules.mentions/2`, and a renamed name ("Renamed
from "PDF Forms" to pdf-forms: names use lowercase letters, digits and
hyphens."). The owner's decision is "refuse or strip anything else, and
say so": Photon strips (other files are never downloaded; other front
matter is dropped) and says so in these notes, which the preview shows
and the skill keeps in `install_notes`. It refuses only what it can't
read as a skill: a web page, a binary file, a file over 256 KB, or a
SKILL.md with no instructions. It doesn't edit the instructions: cutting
sentences that mention a script could change what they mean, so the note
names the mentions and leaves the text to the owner.

A candidate also carries `files_left_out` (section 2.1), which
`Source.candidate/3` builds from the same `left_out` and mentions.

`Photon.Skills.install(params, candidate)` creates the skill from the
preview form's `name`, `description` and `instructions`, with `origin`,
`source_url`, `install_notes` and `files_left_out` taken from the
candidate the LiveView holds (not from form params), turned on nowhere.

### 2.5 Enabling

- `Skills.enable(skill_id, scope)` and `Skills.disable(skill_id, scope)`
  insert or delete one `skill_enablements` row in a commit and announce
  (section 5). Enabling checks the project exists (through
  `Photon.Projects`), applies `Rules.enable_check/1` to the scope's count,
  and is idempotent. Disabling a skill that isn't on does nothing.
- `Skills.enabled(scope)` is the scope's skills, by name: one query,
  which both profiles run on every model request (section 2.6).
- `Skills.scopes(skill_id)` is where a skill is on, for the Skills page
  and a skill's page.

Room for machine scoping, not built: a later step adds a nullable
`machines` column (a list of machine IDs) on `skill_enablements`, and
`enabled/2` takes the machines a conversation is using. Nothing in this
step names machines, so that is a column and an argument, not a
redesign.

### 2.6 How agents see skills

**The prompt.** `Photon.Skills.Prompt.section(skills)` (pure) returns nil
for no skills, so a prompt without enabled skills has no trace of the
feature. Otherwise:

```
## Skills

Skills are instructions for particular kinds of task, written or installed by the user. When a task matches a skill's description, load it with load_skill before you start, and follow it. Load only the skills the task needs.

Only the skills listed here are turned on. If you loaded a skill earlier in this conversation and it isn't listed any more, it was turned off or deleted: stop following it. If a skill's version here is higher than the one you loaded, load it again before you use it.

<available_skills>
<skill><name>pdf-forms</name><version>2</version><description>Fill in PDF forms. Use when the user asks to fill or flatten a PDF form.</description></skill>
</available_skills>
```

The shape follows the node's old `SkillPrompt` (removed in step 1):
XML-escaped names and descriptions inside `<available_skills>`, one
`<skill>` per line, by name. The node's `<location>` goes, since there
are no files, and `<version>` is new (section 2.7). Descriptions have
their whitespace collapsed to one line.

- `Photon.Threads.Prompt.system_prompt(project, now, skills)` puts the
  section after "How you work" and before "Now".
- `Photon.Assistant.Prompt.system_prompt(settings, memory, now, skills)`
  puts it after "How you work" and before "Memory".
- `Photon.Threads.system_prompt/1` reads `Skills.enabled({:project,
  project_id})`; `Photon.Assistant.system_prompt/1` reads
  `Skills.enabled(:blip)`. The profile resolves the prompt at every model
  request (`Photon.Durable.Profile`), so a change applies to the next
  request.

Prompt caching: the prompt changes only when a skill is turned on or off
for that scope, or a listed skill is renamed, re-described or saved
(version). All of those are rare next to model requests.

Threads get nothing about the owner in their prompts. A skill's text is
the owner's, but the owner chose to turn it on for that project, which is
the point of a per-project set; Blip's skills never reach threads.

**The tool.** `load_skill`, in both profiles' tool lists, always (even
with no skills on, so the tool list stays stable for caching and earlier
calls in a conversation always name a tool the profile has):

- Parameters: `name` (string, required, "The skill's name, as listed
  under Skills.").
- Description: "Load a skill's instructions into this conversation. Use
  it when a task matches a skill listed under Skills, before you start
  the task."
- `replay: :safe`. `execute/2` returns `{:commit, fn tx ->
  Skills.load_tx(tx, scope, name) end}`, so the skill is read inside the
  commit that records the result (section 2.7).
- Two thin modules, one per context, because the scope comes from the
  conversation and `Photon.Skills` can't depend on `Photon.Threads`
  (which depends on it): `Photon.Assistant.Tools.LoadSkill` (scope
  `:blip`) and `Photon.Threads.Tools.LoadSkill` (scope `{:project,
  Threads.project_id!(api.conversation_id)}`). Both take `name/0`,
  `description/0` and `parameters/0` from `Photon.Skills.Prompt`
  (`tool_name/0`, `tool_description/0`, `tool_parameters/0`).
- `Skills.load_tx(tx, scope, name)` trims and downcases `name`, finds the
  skill enabled for the scope, and returns the tool result:
  - found: `{:ok, Prompt.loaded(skill), %{"skill" => name, "version" =>
    v, "full_output" => "Load it again with load_skill(\"pdf-forms\") to
    read all of it"}}`, where `Prompt.loaded/1` is

    ```
    <skill name="pdf-forms" version="2">
    ...the instructions...
    </skill>
    ```

    When the skill's `files_left_out` isn't empty, one line follows the
    closing tag: "This skill was installed without its other files
    (scripts/fill.py, reference.md). They aren't on any machine: don't look
    for them or run them. Do what you can from the instructions, and tell
    the user if the task needs a missing file." Without it, a thread told
    to "run scripts/fill.py" would look for that path in the project's
    directory, and in a repo that happens to have one, run an unrelated
    file.
  - not found or not on: `{:error, "There's no skill called pdf-form
    turned on here. Turned on here: pdf-forms, release-notes."}`, or
    "No skills are turned on here." with none.

**Older results.** `Photon.Durable.Context` shortens text over 4,000
code points in tool results from earlier runs, which includes a long
skill. That rule takes nothing from the profile and stays as it is:
`load_tx/3` sets `details["full_output"]`, so the cut reads "...12,345
characters of this older result left out. Load it again with
load_skill("pdf-forms") to read all of it...", and the model can.

### 2.7 Turning off, editing or deleting mid-conversation

| What happens | What the agent sees |
|---|---|
| A skill is turned on | It is listed from the next model request. |
| A skill is turned off, or deleted | It isn't listed from the next request. The prompt's rule tells the model to stop following a loaded skill that isn't listed. A new `load_skill` call returns the "no skill called ..." error. The instructions it loaded earlier stay in the transcript: nothing rewrites history. |
| A skill is saved (version + 1) | The listing shows the new version. The prompt's rule tells the model to load it again when the listed version is above the one it loaded, which the loaded text's header names. |
| A skill is renamed | It is listed under the new name and version. Loading the old name fails with the list of names. |
| A load is in flight when the skill is turned off | `load_tx/3` reads inside the commit that records the result, and the toggle is a commit too. They serialize on the Store, so the call either records the skill's text from before the toggle or the error from after it, never text from a skill that was already off. |
| A run is in progress | The current request finishes with the prompt it was sent with; the next request in the same run uses the new prompt. |

A deleted skill's enablements go with it (`on_delete: :delete_all`).
Nothing per conversation is stored about loaded skills; the transcript
and the version in the loaded text are the record. This is a choice (see
section 12): removing loaded text from model input would mean a profile
hook in `Photon.Durable.Context`, and a model told plainly to stop
following a skill does so.

## 3. Schedules

### 3.1 Data

Table `schedules`, schema `Photon.Schedules.Schedule`, behind
`Photon.Schedules` (section 7.3):

| Column | Type | Notes |
|---|---|---|
| `id` | string, primary key | `sc_<suffix>`, minted by `Photon.Schedules` |
| `project_id` | string, null, references `projects` (`on_delete: :delete_all`), indexed | nil for Blip's own |
| `conversation_id` | string, null | the conversation a firing posts into: Blip's conversation for Blip's schedules, or the thread a project schedule wakes. Nil for a project schedule that starts a new thread each time |
| `prompt` | text, not null | what the firing says, at most 4,000 characters |
| `first_at` | `utc_datetime_usec`, not null | the first time; with `every_minutes`, the grid of times |
| `every_minutes` | integer, null | nil for once; at least 5 |
| `version` | integer, not null | 1 when created, plus 1 on every edit; part of the task's request ID |
| `task_id` | string, null | the routine task that carries the current version (section 3.3) |
| `created_by` | string, not null | `"owner"` (the project page) or `"blip"` (Blip's `schedule` tool) |
| `last_run_at` | `utc_datetime_usec`, null | the last firing, run-now included |
| `last_outcome` | string, null | `"started"`, `"sent"`, `"queued"`, `"skipped_consent"`, `"skipped_running"`, `"skipped_queued"`, `"skipped_missing"` (section 3.5) or `"failed"` (the task failed, section 3.3) |
| `last_thread_id` | string, null | the thread the last firing started or woke |
| `inserted_at`, `updated_at` | `utc_datetime_usec` | |

The row is the schedule's definition and a summary of its last firing.
Its next time and state are derived from its task, never stored on the
row (rule 15). `Schedules.list/1` reads the rows and their tasks in two
queries and returns, for each, `%{schedule: Schedule.t(), next_at:
DateTime.t() | nil, state: :waiting | :done | {:stopped, reason}}`, by
`next_at` (nil last), then `inserted_at`:

- `:waiting`: the task hasn't finished; `next_at` is its
  `checkpoint["next_at"] || input["first_at"]`, as today's
  `list_schedules` reads it
- `:done`: the task finished `done` (a one-off that fired); `next_at` nil
- `{:stopped, reason}`: the task `failed`, with `outcome["reason"]`;
  `next_at` nil. A failure is a bug (a Repo error, a crash in the fire
  step), but the row outlives its task, so a repeating schedule would
  otherwise sit there never firing again with nothing on the page to say
  so. Section 3.3 says how a failure is announced, and section 6.6 how it
  shows.

What each firing did is in the conversations it touched; the row keeps
only the last one, enough for the project page to say "Last ran 09:00,
started "Check the backups"".

### 3.2 Targets and what a firing does

A schedule's target follows from its columns:

| `project_id` | `conversation_id` | Target | A firing |
|---|---|---|---|
| nil | Blip's | Blip | posts `"[Scheduled] <prompt>"` into Blip's conversation, as today |
| set | a thread of that project | that thread | posts `"[Scheduled] <prompt>"` into the thread, through `Threads.send_tx/4`, which moves its `active_at` and announces `{:projects_changed, project_id}` |
| set | nil | a new thread | starts a thread in the project through `Threads.start_tx/4`, with `"[Scheduled] <prompt>"` as its first message; the thread's first title comes from the prompt (`Threads.Rules.title/1`), and the model names it after its first run, like any thread |

The submission's `source` is `%{"kind" => "routine", "schedule_id" =>
schedule.id}` for all three. `"routine"` stays the source kind, so the
conversation view's existing "Scheduled" bubble (`ConversationComponents`
matches it) works on the thread page unchanged. Its request ID is
`"schedule:<schedule id>:<task id>:<runs>"`, where `runs` is the routine's
checkpoint count, so one firing makes one submission in a conversation.

A thread whose first message came from a schedule has no "owner" source:
its row is the same as any thread's.

### 3.3 The routine task

`Photon.Assistant.Routine` moves to `Photon.Schedules.Routine` and keeps
the `"routine"` kind name (`config/config.exs` and `config/test.exs`
register it under `kinds`, next to `"thread_title"`).

- Created by `Photon.Schedules` in the same commit as the row (and on
  every edit, section 3.4): `kind: "routine"`, `conversation_id: nil`
  (the task belongs to no conversation; its row names where it posts),
  `background: true`, `phase: "start"`, `request_id:
  "schedule:<id>:v<version>"`, `input: %{"schedule_id" => id, "first_at"
  => next_ms, "every_ms" => every_minutes * 60_000 | nil}`, where
  `next_ms` is `Rules.arm/4`'s answer (below).
- `step("start")`: `first_wait/1`, as today.
- `step("fire")`: reads consent (`Schedules.consent?/0`: the scripted
  model, or `Settings.scheduled_work?/1`) and the clock outside the
  commit, then `Runtime.commit(runtime, fn tx -> ... end)` does all of
  this in one commit:
  1. read the schedule row (`Repo.get` inside the commit, so it sees the
     latest edit)
  2. gather the facts for `Rules.fire/2` with `Tx.active_run/2` and
     `Tx.queued/2` (section 3.5)
  3. apply the decision: start a thread, submit, or skip (a skip into
     Blip or a thread appends the notice entry)
  4. update the row's `last_run_at`, `last_outcome`, `last_thread_id`
  5. `Tx.announce(tx, "schedules", {:schedules_changed, project_id})`
  6. return `after_fire(task, now)`: the next wait, or `{:done, ...}` for
     a one-off

  `Runtime.commit/2` applies everything or nothing: when the task was
  marked for abort (an edit or delete landed first), finished, or isn't
  the start this step belongs to (a Scheduler restart), none of 1 to 5 is
  kept. That fence is what makes a firing happen once and never after its
  schedule was edited or deleted; section 10 checks it in TLA+.
- A row that is gone when the step runs can only mean the fence failed;
  the step finishes the task (`{:done, %{"gone" => true}}`) and writes
  nothing.
- `on_fail/3` (run by the Scheduler inside the commit that fails the
  task): when the row still names this task (`task_id == task.id`; an
  edit may have replaced it), it sets `last_outcome: "failed"` and
  announces `{:schedules_changed, project_id}`, so the pages show the
  schedule as stopped (section 6.6). It returns `:ok`, never `:retry`: a
  fire step that crashes will crash the same way again, and saving the
  schedule starts a fresh task.
- `first_wait/1`, `after_fire/2`, `next_after/3`, `prompt/1` and
  `request_id/1` stay pure helpers; `next_after/3` moves to
  `Schedules.Rules`, since editing uses it too.

`Rules.arm(first_at_ms, every_ms, now_ms, fired_through_ms)` is the
first time a new or edited schedule waits for, or `:finished`.

The form and Blip's tool both accept a time up to a minute ago (section
3.4): the browser's `datetime-local` input only goes down to the minute,
so picking the current minute at 14:05:40 gives 14:05:00, and Blip's
`in_minutes: 0` is already a few milliseconds old when its commit runs.
`arm/4` must fire those, not drop them. It must also not fire a time
twice: an edit saved at 14:05:30 to a schedule that fired at 14:05:00
keeps `first_at` 14:05:00, which is still inside the grace.
`fired_through_ms` is the latest time on the schedule's times that its
current task has already fired (or skipped as missed), nil for a new
schedule. `update/3` gets it from the old task with
`Rules.fired_through(input, checkpoint, status)` (pure, plain maps): nil
while the task hasn't fired (`checkpoint["runs"]` is 0 or absent);
`input["first_at"]` for a one-off that finished `done`; for a repeating
task that has fired, `checkpoint["next_at"] - every_ms` (the slots
between the last firing and `next_at` were missed and skipped, so they
count as fired). A firing in flight when the edit lands hasn't
committed, so its slot doesn't count, and the new task fires it instead
(the old step is fenced out).

With `lower = max(now - 60_000, fired_through + 1)` (`now - 60_000` when
`fired_through` is nil):

- once, `first_at >= lower`: `first_at`. A time in the past wakes at
  once, as today's routines do with an `until` in the past.
- once, otherwise: `:finished`. Only an edit of a one-off that already
  fired at that time gets here, since the rules refuse older times
  first. `update/3` then keeps the old, finished task and its `task_id`,
  so the row still reads as done.
- repeating, `first_at >= lower`: `first_at`
- repeating, otherwise: the first time on the grid at or after `lower`,
  `first_at + ceil((lower - first_at) / every) * every`

`create/2`, `update/3` and `blip_schedule_tx/5` read the clock once and
pass the same `now` to `Rules.schedule/2` (or `from_tool/2`) and
`arm/4`, so a time the rules accepted is never `:finished` for want of a
few milliseconds.

### 3.4 Creating, editing, deleting, running now

All four are commits in `Photon.Schedules` that announce `{:schedules_changed,
project_id}` on `"schedules"`.

- `create({:project, project_id}, params)`: `Rules.schedule/2` checks the
  form (below), the commit checks the project exists and, for a thread
  target, that the thread belongs to it, inserts the row (`created_by:
  "owner"`) and its routine task, and stores the task's ID on the row.
- `update(id, params, version)`: in one commit, refuses a stale edit
  (`{:error, :stale}` when the row's `version` isn't the one the form
  loaded, as skills and context files do), re-checks the params, marks
  the old task for abort (`Tx.request_abort(tx, task, background:
  true)`, a no-op on a finished task), bumps `version`, arms a new task
  (none when `arm/4` says `:finished`), and updates the row with the new
  `task_id`. Every edit replaces the task, even one that only changes the
  prompt: one path, and the task's input always matches the row. A firing
  that was about to commit is fenced out (section 3.3); the replacement
  fires the slot the old task didn't (`fired_through`, section 3.3), so
  an edit made in the second a schedule is due neither skips nor repeats
  that firing.
- `delete(id)`: in one commit, marks the task for abort and deletes the
  row.
- `run_now(id)`: fires once now, outside the schedule's times: one commit
  running the same steps 1 to 5 as a firing, with consent taken as given
  (the owner pressed the button, so nothing runs while they're away) and
  a request ID `"schedule:<id>:now:<ID.new>"`. The overlap rule still
  applies. It doesn't touch the task. Returns `{:ok, outcome}`.

`Rules.schedule(params, %{now: now, thread_ids: ids})` (pure) reads the
owner's form:

| Param | Rule and message |
|---|---|
| `prompt` | trimmed, required ("Say what this schedule should ask for."), at most 4,000 characters ("Keep the prompt under 4,000 characters, and put the rest in a context file.") |
| `at` | an ISO 8601 time with offset, which the page's hook fills in from the owner's local time (section 3.9); required ("Pick a date and time."); for a one-off, not more than a minute ago ("That time has passed.") |
| `repeat` | `"once"` or `"every"` |
| `every`, `unit` | with `repeat: "every"`: a whole number and `minutes`, `hours`, `days` or `weeks`; at least 5 minutes ("Repeat no more often than every 5 minutes.") and at most 52 weeks ("Repeat at least once a year.") |
| `target` | `"new_thread"`, or the ID of one of `thread_ids` ("Pick one of this project's threads, or a new thread each time.") |

It returns `{:ok, %{prompt, first_at, every_minutes, conversation_id}}`
or `{:error, %{field => message}}`.

`Rules.from_tool(args, now)` reads Blip's `schedule` tool's arguments
(`prompt`, `in_minutes` or `at`, `every_minutes`) with today's messages
unchanged, so Blip's tool behaves as it does now. Its `at` rule is
today's: refused only when more than a minute ago (`ms < now - 60_000`),
the same grace as the form's, which `arm/4` honours.

### 3.5 Consent and overlap

`Rules.fire(target, facts)` (pure), with `facts = %{allowed?: boolean,
last_thread_running?: boolean, queued?: boolean, thread?: boolean}`:

| Situation | Decision | `last_outcome` |
|---|---|---|
| not allowed (no consent and not the scripted model) | skip; into Blip or a thread, append a notice entry saying so | `"skipped_consent"` |
| new-thread target and the thread the last firing started is still running (`Tx.active_run(tx, last_thread_id)`) | skip | `"skipped_running"` |
| Blip or thread target, and a submission from this schedule is still queued there (`Tx.queued/2`, matched on `source["schedule_id"]`) | skip | `"skipped_queued"` |
| thread target and the thread is gone (can't happen until threads can be deleted) | skip | `"skipped_missing"` |
| new-thread target | start a thread | `"started"` |
| Blip or thread target, conversation idle | submit; it starts a run | `"sent"` |
| Blip or thread target, conversation busy | submit as a follow-up, queued behind the current run | `"queued"` |

`last_thread_running?` is `false` when the row's `last_thread_id` is nil
(a new-thread schedule that hasn't fired yet, or only skipped), and
`Tx.active_run/2` is called only for a set ID: `Queries.active_run/1`
compares `t.conversation_id == ^conversation_id`, and Ecto raises on a
nil comparison, which would fail every new-thread schedule's first
firing. Likewise `thread?` and `queued?` are gathered only for a target
that has a conversation.

The consent rule is today's `scheduled_work?` check, unchanged in what it
allows; it is checked at every firing, so turning consent off stops the
next firing. The overlap rules are new and apply to Blip's schedules too:
without them a five-minute schedule on a thread that is stuck in a long
command would queue a prompt every five minutes, and a new-thread schedule
would start a thread every five minutes while the last one is still
working (rule 73). The facts are read inside the firing's commit, so they
are current when the decision lands.

The notice entries (kind `"error"`, `"notice" => true`, which
`Durable.Context` never sends to the model):

- Blip, as today: `Skipped "<prompt>": scheduled work is off. Turn it on
  in Settings to let me use your plan while you're away.`
- A thread: `Skipped the scheduled prompt "<prompt>": scheduled work is
  off. Turn it on in Settings to let schedules use your ChatGPT plan
  while you're away.`

A new-thread schedule has no conversation to put a note in; its row's
`last_outcome` shows on the project page (section 6.6), which also warns
when scheduled work is off.

### 3.6 Blip's own schedules

Blip keeps `schedule`, `list_schedules` and `cancel_schedule`, with the
same names, parameters and result texts, rewritten over
`Photon.Schedules`:

- `schedule`: `execute/2` returns `{:commit, fn tx ->
  Schedules.blip_schedule_tx(tx, api.conversation_id, args,
  "schedule:" <> ToolAPI.task_id(api), now) end}`. The row (`project_id:
  nil`, `conversation_id:` Blip's, `created_by: "blip"`) and its task are
  created in the commit that records the result, so a rerun after a
  restart can't make a second schedule. Result: "Scheduled sc_...: first
  at 2026-10-08 09:00 UTC, then every 1440 minutes." with details
  `%{"schedule_id" => id}`.
- `list_schedules`: Blip's schedules with a next time
  (`Schedules.list(:blip)`), in today's format with the `sc_` IDs.
- `cancel_schedule`: `Schedules.delete_tx(tx, id, :blip)` inside the
  result's commit; a project schedule's ID gets "There is no schedule
  sc_...." as an unknown one does.

None of them takes a project or a thread, so Blip can't schedule work in
projects until step 4 gives it project tools. Blip's panel floats over
the project page and its page note names the project, so an owner
looking at Garden may ask Blip to "check Garden's backups every
morning". Blip would make one of its own schedules, the prompt would
land in Blip's conversation each morning, and nothing would show on
Garden's Schedules list. Two texts change so Blip says so instead:

- `Photon.Assistant.Prompt`'s line "Use schedule for anything recurring
  or for later." becomes "Use schedule for anything recurring or for
  later. Your schedules post to this conversation, not to a project. For
  recurring work in a project, tell the user to add it with New schedule
  on that project's page."
- The `schedule` tool's description gains "It posts here, in your own
  conversation; it can't schedule work in a project." `Photon.Assistant.schedules/0`
and `cancel_schedule/1` become `Schedules.list(:blip)` and
`Schedules.delete/1`, for the home page.

`Assistant.stop/0` keeps scheduled prompts that are waiting, as today;
the check moves to `Photon.Durable.Submission.background?/1` (section
3.7). A thread's Stop withdraws them (section 3.7).

### 3.7 Threads and schedules

- A thread's tools are unchanged by schedules: no `schedule` tool, so a
  thread can't create a schedule, and no schedule targets anything a
  thread chose. The threads profile test asserts the exact tool list
  (the machine tools, the four context-file tools and `load_skill`).
- `Threads.start_tx(tx, project_id, text, opts)` and `Threads.send_tx(tx,
  thread_id, text, opts)` become public, for `Photon.Schedules` to call
  inside its commit (today `start/2` and `send/3` wrap private versions).
  `opts` takes `:source` (default `%{"kind" => "user"}`) and
  `:request_id`. `start_tx/4` keeps creating the titling task.
- `Threads.stop/1` doesn't change: Stop in a thread withdraws everything
  queued, scheduled prompts included, as step 2 chose ("a thread has no
  background input to keep"). `Durable.abort/2` withdraws what its filter
  picks and then `continue_inbox/2` starts the next queued input, so a
  kept scheduled prompt would start a new run the moment the owner
  pressed Stop. The owner stops a thread to halt its work, and Stop has to
  look like it worked. The withdrawn prompt shows as withdrawn in the
  thread, the row's `last_outcome` stays `"queued"` (what the firing
  did), and the schedule's next firing still comes: a withdrawn
  submission isn't queued, so it doesn't trigger `"skipped_queued"`.
  Blip's Stop keeps its scheduled prompts, as today.
- `Photon.Durable.Submission.background?/1` (a small reader on the data
  module): whether the submission came from background work, today
  `source["kind"] == "routine"`. `Assistant.stop/0` uses it, and
  `Assistant.background_input?/1` goes.
- The thread prompt gains one line under "How you work": "A message
  starting with "[Scheduled]" comes from one of the project's schedules,
  not from the user typing it. The user may not be watching, so record
  what matters in the context files."

### 3.8 Durability across restarts

Nothing new is kept in memory. A schedule is a row and a durable task
waiting with `"until"`. After a hub restart the Scheduler finds the task
waiting and wakes it at its time; a firing whose step was running when
the hub died reruns, and its commit either landed (the task moved on) or
didn't (it runs again once), as routines do today. A time missed while
the hub was down fires once when it comes back, then the schedule
continues on its grid (`next_after/3` skips the rest). Edits, deletes and
run-now are single commits.

### 3.9 Times in the UI

Elixir has only UTC without a time zone database, and the project has
none (Settings' time zone is free text for Blip's prompt). The browser
knows the owner's zone, so the pages convert there:

- `PhotonWeb.TimeComponents.local_time/1` renders `<time id=...
  datetime="<ISO UTC>" phx-hook=".LocalTime" data-format="datetime">` with
  a UTC fallback ("Oct 8, 14:00 UTC"). The colocated hook rewrites its
  text with `Intl.DateTimeFormat` in `mounted()` and `updated()`.
- `local_datetime_input/1` renders a `datetime-local` input
  (`phx-update="ignore"`, its value set by the `.LocalDateTime` hook from
  `data-utc` on mount) and the hidden form field the server reads. On
  every change the hook writes `new Date(value).toISOString()` into the
  hidden field and dispatches an `input` event so `phx-change` sees it.
  Tests set the hidden field directly with `render_change/2`.
- A repeat is an interval on a UTC grid, as routines are today. "Every
  day" from 09:00 in winter fires at 10:00 local after the clocks go
  forward. The form says "Repeats every 1 day from the first time" so
  this isn't a surprise; calendar rules come later.

## 4. The scripted model

Both scripted models learn the same skill phrasings, from
`Photon.Skills.MockPhrases` (pure, exported by `Photon.Skills`, used the
way `Photon.MachineTools.MockPhrases` is):

- `skills`: answers from the request's `system` text, without a tool
  call: "Skills turned on here: pdf-forms (version 2), release-notes
  (version 1)." or "No skills are turned on here." It reads the
  `<skill><name>...</name><version>...</version>` lines, so LiveView and
  end-to-end tests can see what the prompt listed.
- `load skill <name>`: calls `load_skill` with `name`.
- After a `load_skill` result, the existing relay prints it, so the loaded
  instructions show on the page.

`phrasings(request)` takes the request (for the `system` text) and returns
`{regex, reply_fun}` pairs as `MachineTools.MockPhrases.phrasings/0`
does. `Photon.Assistant.MockScript` and `Photon.Threads.MockScript` add
them after the machine phrasings, and their help texts list them.

`Photon.Threads.MockScript` also strips a leading `"[Scheduled] "` before
matching, as Blip's already does, so a project schedule whose prompt is
`on local: $ uptime` runs that command on the scripted model. Under
`PHOTON_MOCK_MODEL=1` consent counts as given (the scripted model uses
nobody's plan), so schedules fire in development without touching
Settings.

## 5. Events

Every announcement is a hint to re-read committed state, sent after the
commit with `Tx.announce/3`, through `Photon.Events`.

| Topic | Message | Sent when | Who listens |
|---|---|---|---|
| `"skills"` (`Skills.subscribe/0`) | `{:skills_changed, skill_id}` | a skill is created, installed, saved or deleted, or turned on or off anywhere | `SkillsLive`, `SkillLive`, `ProjectLive` (its skills section) |
| `"schedules"` (`Schedules.subscribe/0`) | `{:schedules_changed, project_id \| nil}` | a schedule is created, edited or deleted; every firing, run-now and skip (its next time and last run changed); its task fails (`on_fail/3`) | `ProjectLive` (its own project), `ScheduleLive` (its own project), `OverviewLive` (nil, Blip's) |
| `"projects"` (existing) | `{:projects_changed, project_id}` | a firing starts or wakes a thread (through `Threads.start_tx/4` and `send_tx/4`, as today) | `PhotonWeb.Shell`, `ProjectLive`, `ThreadLive` |
| `"durable:" <> thread_id` (existing) | `{:durable, ...}`, `{:live, ...}` | a scheduled prompt, a skip notice, a `load_skill` call | `ThreadLive`, `BlipLive` |

`OverviewLive` stops reading schedules on `{:durable_tasks, _}` and
listens on `"schedules"` instead. Routine tasks still appear in
`{:durable_tasks, _}`; `ProjectLive` and the shell already ignore tasks
that don't belong to a listed thread.

## 6. UI

### 6.1 Routes

Inside the existing `live_session :gui`, after the project routes:

```elixir
live "/projects/:slug/schedules/new", ScheduleLive, :new
live "/projects/:slug/schedules/:id", ScheduleLive, :edit
live "/skills", SkillsLive
live "/skills/new", SkillLive, :new
live "/skills/install", SkillInstallLive
live "/skills/:name", SkillLive, :edit
```

`/skills/new` and `/skills/install` come before `/skills/:name`, and
`new` and `install` are reserved names (section 2.2). A missing skill
redirects to `/skills` with "There's no skill called pdf-form."; a
missing project or schedule, or a schedule under another project's slug,
redirects as step 2's pages do ("There's no such schedule in Garden.").
Blip's page note (`Assistant.Page.at/1`) already treats every path under
`/projects/:slug` as the project, so the schedule pages get the chip with
no change; `/skills` paths give no page.

`/projects/:slug/schedules/new` takes `?thread=<id>` to preselect that
thread as the target.

### 6.2 The sidebar

`Skills` (`#nav-skills`, icon `hero-book-open`, links to `/skills`)
between `Machines` and `Settings`. `Layouts.app`'s `active` takes
`:skills`, which the three skills pages pass.

### 6.3 The Skills page

`PhotonWeb.SkillsLive` at `/skills`:

- Header "Skills", subtitle "Instructions an agent loads when a task
  calls for them. A new skill is off everywhere until you turn it on for
  Blip or a project."
- `Write a skill` (`#new-skill`, to `/skills/new`) and `Install`
  (`#install-skill`, to `/skills/install`).
- The skills (`#skills`, a stream, rows `#skill-<id>`): the name linking
  to `/skills/<name>`, the description clamped to two lines, a line
  `#skill-<id>-scopes` ("On for Blip, Garden and House", or "Off
  everywhere"), the origin ("Written here", "Pasted", or "From
  github.com/..."), and a switch `#skill-<id>-blip` ("Blip") that calls
  `Skills.enable/2` or `disable/2` with `:blip`. A refused enable (30 on
  already) shows the message as a flash.
- Empty (`#no-skills`, the stream's `hidden only:block` first child): "No
  skills yet. Write one, or install one from a SKILL.md or a GitHub
  link."
- On `{:skills_changed, _}` it resets the stream. Project names for the
  scopes line come from `Projects.list/0`, read with the rows.

### 6.4 A skill

`PhotonWeb.SkillLive`:

- `:new` at `/skills/new`: the form `#skill-form` with `Name`
  (`#skill-name`, hint "Lowercase letters, digits and hyphens. Agents
  load the skill by this name."), `Description` (`#skill-description`,
  hint "When should an agent use it? Agents see this before they load
  the skill."), `Instructions` (`#skill-instructions`, a monospace
  textarea, `phx-debounce="400"`), `Write` and `Preview` tabs
  (`#skill-tab-write`, `#skill-tab-preview`, `#skill-preview` through
  `Photon.Markdown.to_html/1`), and `Save` (`#skill-save`). On success it
  navigates to `/skills/<name>` with the flash "Saved pdf-forms. It's off
  everywhere; turn it on below."
- `:edit` at `/skills/:name`: the same form with a hidden `version`, a
  meta line `#skill-meta` ("Version 3. Installed from
  github.com/o/r/.../SKILL.md on Oct 7." or "Written here."), the install
  notes if any (`#skill-install-notes`), and `Delete` (`#skill-delete`,
  `data-confirm` "Delete pdf-forms? Blip and threads can't load it any
  more."), which returns to `/skills`.
- "Turned on for" (`#skill-scopes`): a switch for Blip
  (`#skill-scope-blip`) and one per project (`#skill-scope-<project
  id>`, by name), each calling `enable/2` or `disable/2`. The projects
  are a stream.
- A rename that saves navigates to the new name's URL
  (`push_patch`).
- A save against an older version shows `#skill-stale` ("This skill
  changed since you opened it.") with `Load the saved version`
  (`#skill-reload`) and keeps the typed text, as the context file editor
  does. `enable/2` and `disable/2` announce the same `{:skills_changed,
  id}` as a save without changing the version, so on `{:skills_changed,
  id}` for this skill the page does two separate things. It always
  resets the `#skill-scopes` stream from `Skills.scopes/1`, so a toggle
  made on `/skills` or a project page shows here. And only when the
  stored version differs from the form's loaded version does a clean form
  reload, or a dirty one show `#skill-stale`; a toggle on this page while
  the owner is typing leaves the form and the banner alone. A deleted
  skill sends the page to `/skills` with "pdf-forms was deleted." A dirty
  form asks before leaving,
  with the context file editor's `.UnsavedGuard` hook: K9 moves that
  colocated hook out of `ContextFileLive` into a shared function component
  (`PhotonWeb.CoreComponents.unsaved_guard/1` or a new
  `PhotonWeb.EditorComponents`) so both editors use it.

### 6.5 Install

`PhotonWeb.SkillInstallLive` at `/skills/install`:

- Two tabs: `From a link` (`#install-tab-url`) and `Paste SKILL.md`
  (`#install-tab-paste`).
- From a link: the form `#install-url-form` with `#install-url`
  (placeholder `https://github.com/owner/repo/tree/main/skills/pdf-forms`)
  and `Fetch` (`#install-fetch`). Submitting runs `start_async(:fetch, fn
  -> Skills.fetch(url) end)` and shows `#install-fetching` ("Fetching...")
  until it returns. An error shows under the field (`#install-error`).
- Paste: the form `#install-paste-form` with `#install-paste` (a
  monospace textarea) and `Read` (`#install-read`), which calls
  `Skills.read/1`.
- One candidate: the preview form `#install-form` with `#install-name`,
  `#install-description` and `#install-instructions` prefilled and
  editable, the notes (`#install-notes`, one `<li>` each), the source line
  ("From github.com/..."), field errors from the rules, and `Install`
  (`#install-save`). Success navigates to `/skills/<name>` with "Installed
  pdf-forms. It's off everywhere; turn it on below."
- Several candidates (a folder of skills): a list `#install-candidates`,
  each `#install-candidate-<n>` with a checkbox, its name, description,
  notes, and a reason it can't be picked when it can't (its download
  failed, its name is taken: "There's already a skill called pdf-forms."),
  and `Install selected` (`#install-selected`), which installs each picked
  one under its own name and goes to `/skills` with "Installed 3 skills.
  They're off everywhere until you turn them on." A pick that fails (a
  name taken meanwhile) stays listed with its message.
- The candidates live in the socket (`assigns.candidates`), and install
  takes `origin`, `source_url` and the notes from there, not from the
  form.

### 6.6 The project page: skills and schedules

`PhotonWeb.ProjectLive`'s second column gets two sections under Context
files, both streams:

**Skills** (`#project-skills`, rows `#project-skill-<skill id>`):

- Each enabled skill: its name (linking to `/skills/<name>`), its
  description on one line, and a `Turn off` button
  (`#project-skill-<id>-off`).
- `Turn on skills` (`#project-add-skill`) opens a picker
  (`#project-skill-picker`, a stream of the skills not on here, each
  `#project-skill-option-<id>` with name and description; clicking turns
  it on). A refused enable shows its message in the picker
  (`#project-skill-error`).
- Empty (`#no-project-skills`): "No skills turned on. Skills are
  instructions this project's threads load when a task calls for them."
  With no skills at all, the picker says "No skills yet." and links to
  `/skills` (`#project-skills-page`).

**Schedules** (`#project-schedules`, rows `#schedule-<id>`), with `New
schedule` (`#new-schedule`, to `/projects/<slug>/schedules/new`):

- Each row: the prompt clamped to two lines; when (`#schedule-<id>-when`,
  from `list/1`'s `state`: "Every day · next <local time>" or "Once ·
  <local time>" while `:waiting`; "Done" for a one-off whose task is
  `:done`; for `{:stopped, reason}`, "Stopped after an error: <reason>.
  Save it to start it again." for a repeating schedule, and "Stopped after
  an error: <reason>. Pick a time and save it to run it." for a one-off,
  in the error colour); the target ("Starts a new thread each time", or
  `Wakes "Fix the pump"` linking to the thread); the last run
  (`#schedule-<id>-last`: "Last ran <local time>: started "Check the
  backups"", with the thread linked as `#schedule-<id>-last-thread`, or
  "skipped: scheduled work is off" linking to Settings, "skipped: the
  last thread was still running", "skipped: the last prompt was still
  waiting"); and `Run now` (`#schedule-<id>-run`), `Edit`
  (`#schedule-<id>-edit`, to `/projects/<slug>/schedules/<id>`), and
  `Delete` (`#schedule-<id>-delete`, `data-confirm` "Delete this
  schedule? Threads it started stay.").
- When `Schedules.consent?/0` is false and the project has schedules, a
  banner `#schedules-consent`: "Scheduled work is off, so these skip their
  runs. Turn it on in Settings to let schedules use your ChatGPT plan
  while you're away." linking to `/settings`.
- Empty (`#no-schedules`): "No schedules. A schedule starts a thread, or
  wakes one, at set times."
- `Run now` flashes the outcome ("Started a thread.", "Sent to "Fix the
  pump".", or the skip reason).

What it hears, added to step 2's list (the minute `:tick` needn't touch
schedules: their times are absolute, and the browser formats them):

- `{:skills_changed, _}` (it subscribes with `Skills.subscribe/0`): reset
  the skills stream and the picker.
- `{:schedules_changed, id}` for its project (`Schedules.subscribe/0`):
  reset the schedules stream.
- `{:projects_changed, id}` for its project (step 2's handler): also
  reset the schedules stream. Its rows embed thread titles (`Wakes "..."`
  and the last run's thread), and a thread is renamed by the model after
  its first run (titling) or by the owner, which announces only
  `{:projects_changed, id}`. For a new-thread schedule the first title is
  always replaced, so without this the row would usually show a stale
  one.

`PhotonWeb.ScheduleText` (pure, web formatting, like `ProjectText`)
gives the words: `every(minutes)` ("every 5 minutes", "every hour",
"every 2 hours", "every day", "every 3 days", "every week"; minutes that
aren't a whole number of hours, days or weeks are said in minutes),
`outcome(outcome)` ("started", "skipped: scheduled work is off", ...,
"stopped after an error"), `state(state, every_minutes)` (the when line's
words for each state, above), and `target(schedule, thread_title)`. Times are rendered by
`TimeComponents.local_time/1`.

### 6.7 The schedule form

`PhotonWeb.ScheduleLive`:

- `:new` at `/projects/:slug/schedules/new` and `:edit` at
  `/projects/:slug/schedules/:id`, one form `#schedule-form`
  (`phx-change="validate"`, `phx-submit="save"`):
  - `Prompt` (`#schedule-prompt`, textarea, "What should the thread be
    asked each time? It arrives as a message starting with
    [Scheduled].")
  - `When` (`local_datetime_input/1`: `#schedule-at-local` and the hidden
    `#schedule-at`), defaulting to the next whole hour
  - `Repeat` (`#schedule-repeat`, `Once` or `Every`), and with `Every`,
    `#schedule-every` (number) and `#schedule-unit` (minutes, hours,
    days, weeks); the line "Repeats on a fixed interval from the first
    time."
  - `Thread` (`#schedule-target`, a select): "A new thread each time"
    first, then the project's threads by last activity
  - `Save` (`#schedule-save`)
- `:edit` adds the next and last run (`#schedule-next`,
  `#schedule-last`), `Run now` (`#schedule-run`) and `Delete`
  (`#schedule-delete`), and a line that saving replaces the timer ("Saving
  starts the schedule over from the next time after now.").
- On success it returns to the project page with "Schedule saved."; on
  error the field messages show under their fields.
- `?thread=<id>` on `:new` preselects that thread.
- `:edit` carries the row's `version` in a hidden field and saves with
  `Schedules.update/3`. A stale save (the schedule was edited in another
  tab) shows `#schedule-stale` ("This schedule changed since you opened
  it.") with `Load the saved version` (`#schedule-reload`), and keeps the
  typed fields, as the skill editor does.
- On `{:schedules_changed, id}` for its project, the page re-reads its
  schedule with `Schedules.get/1` and refreshes only `#schedule-next` and
  `#schedule-last` (and `#schedule-stale` when the version moved). It
  never rebuilds the form: a five-minute schedule fires every five
  minutes, each firing announces, and rebuilding would wipe a prompt the
  owner is typing. When the schedule is gone (deleted in another tab), it
  returns to the project page with "That schedule was deleted."

### 6.8 The thread page and the home page

- `ThreadLive` `:show` gets `Schedule` (`#thread-schedule`, a small
  button beside the title) linking to
  `/projects/<slug>/schedules/new?thread=<id>`.
- The scheduled prompt shows as the existing "Scheduled" bubble (source
  kind `"routine"`), and a skip notice as the existing notice line.
- `OverviewLive` reads `Schedules.list(:blip)` (only those with a next
  time), subscribes with `Schedules.subscribe/0`, cancels with
  `Schedules.delete/1`, and shows times with `local_time/1`. Its IDs
  (`#schedules`, `#schedule-<id>`) stay; the rows are `sc_` IDs now. The
  empty text stays "None yet. Ask Blip for something recurring, like
  "every morning, check my disks"." and gains "Project schedules are on
  each project's page."

### 6.9 The conversation view

`PhotonWeb.ConversationComponents` gets a label and icon for
`load_skill`: "Loading the pdf-forms skill" while it runs, "Loaded the
pdf-forms skill" after, "Couldn't load pdf-form" on an error, icon
`hero-book-open`. Clicking the line shows the result as other tool lines
do. Nothing else changes for skills or schedules.

### 6.10 Settings

Project schedules now depend on the `scheduled_work` setting, and the
project page's consent banner sends the owner to Settings. Today the
checkbox there reads "Let Blip use my plan for schedules while I'm away",
with the hint "Schedules you set up (like a morning check) run on your
plan without you there. Off, Blip skips them and says so." That names
only Blip, and the hint is wrong for a new-thread schedule, which posts
no note anywhere when skipped.

`PhotonWeb.SettingsLive` changes the words, not the setting:

- Label: "Let schedules use my plan while I'm away"
- Hint: "Blip's schedules and your projects' schedules run on your plan
  without you there. Off, they skip their runs: Blip and threads say so
  in the conversation, and the project page shows it on the schedule."

## 7. Module plan

Layers per the brief. "Boundary" is the `use Boundary` declaration. Every
public function gets a `@spec`, every struct a `@type t`. No new
processes and no new registered names in this step.

### 7.1 apps/node and apps/core

No changes.

### 7.2 apps/hub: skills

| Module | Layer | Boundary | Notes |
|---|---|---|---|
| `Photon.Skills` | boundary (API, no process) | `use Boundary, deps: [Photon.Durable, Photon.Events, Photon.Projects, Photon.Repo, PhotonCore, PhotonCore.LLM, Ecto, Req], exports: [Skill, Prompt, MockPhrases]` | `subscribe/0`, `list/0` (each skill with its scopes), `get/1`, `get_by_name/1`, `create/1`, `install/2`, `update/3` (id, params, version), `delete/1`, `enable/2`, `disable/2`, `enabled/1`, `scopes/1`, `read/1`, `fetch/1`, and `load_tx/3` for the two `load_skill` tools inside their commit. Results: `{:ok, skill}`, `{:error, %{field => message}}`, `{:error, :stale \| :not_found}`, `{:error, message}` for enable, read and fetch. Validates once with `Skills.Rules` (rule 64). Moduledoc: what a skill is, the scopes, the room for machines, that there is no process. `PhotonCore.LLM` is for `MockPhrases`. |
| `Photon.Skills.Skill` | data (Ecto schema) | `use Boundary, type: :strict, deps: [Ecto]` | Section 2.1. |
| `Photon.Skills.Enablement` | data (Ecto schema) | `use Boundary, type: :strict, deps: [Ecto]` | Section 2.1. `@primary_key false`. |
| `Photon.Skills.Rules` | core | `use Boundary, type: :strict, deps: []` | Section 2.2. |
| `Photon.Skills.SkillMd` | core | `use Boundary, type: :strict, deps: []` | Section 2.3. |
| `Photon.Skills.Source` | core | `use Boundary, type: :strict, deps: [Photon.Skills.Rules, Photon.Skills.SkillMd]` | `classify/1`, the GitHub API and raw URLs, `skills_in_tree/3`, `candidate/3` (a parsed SKILL.md plus its folder facts to a candidate), `notes/3`, `error_message/2` (an HTTP status or reason to the messages in section 2.4). |
| `Photon.Skills.Fetch` | boundary (HTTP through `Req`, inside `Photon.Skills`) | none of its own | `get(url, kind)` with the limits of section 2.4; `github/1`. Reads `req_options` from app env. Called only by `Photon.Skills.fetch/1`. |
| `Photon.Skills.Prompt` | core | `use Boundary, type: :strict, deps: [Photon.Skills.Skill]` | `section/1`, `loaded/1` (with the left-out files line, section 2.6), `not_loaded/2`, `tool_name/0`, `tool_description/0`, `tool_parameters/0`, `full_output_hint/1`. |
| `Photon.Skills.MockPhrases` | core | `use Boundary, type: :strict, deps: [PhotonCore, PhotonCore.LLM]` | Section 4. |
| `Photon.Assistant.Tools.LoadSkill`, `Photon.Threads.Tools.LoadSkill` | boundary (durable tools) | inside their contexts | Section 2.6. |
| `Photon.Threads` | boundary | deps add `Photon.Skills` | `tools/1` adds `Tools.LoadSkill`; `system_prompt/1` passes `Skills.enabled/1`. |
| `Photon.Threads.Prompt` | core | deps add `Photon.Skills` (reaches `Skills.Prompt` through its parent's dep, as with `MachineTools.Guide`) | `system_prompt/3`; the `[Scheduled]` line (section 3.7). |
| `Photon.Threads.MockScript` | core | deps add `Photon.Skills` | Skill phrasings; strips `[Scheduled] `. |
| `Photon.Assistant` | boundary | deps add `Photon.Schedules`, `Photon.Skills` | `tools/1` adds `Tools.LoadSkill`; `system_prompt/1` passes `Skills.enabled(:blip)`; `schedules/0` and `cancel_schedule/1` over `Photon.Schedules`; `stop/0` uses `Submission.background?/1`. |
| `Photon.Assistant.Prompt` | core | deps add `Photon.Skills` | `system_prompt/4`. |
| `Photon.Assistant.MockScript` | core | deps add `Photon.Skills` | Skill phrasings. |

### 7.3 apps/hub: schedules

| Module | Layer | Boundary | Notes |
|---|---|---|---|
| `Photon.Schedules` | boundary (API, no process) | `use Boundary, deps: [Photon.Durable, Photon.Events, Photon.Projects, Photon.Repo, Photon.Settings, Photon.Threads, PhotonCore, Ecto], exports: [Schedule]` | `subscribe/0`, `list/1`, `get/1` (with `next_at` and `state`), `create/2`, `update/3` (id, params, version), `delete/1`, `run_now/1`, `consent?/0`, `new_params/1` (the form's defaults for a time), and for Blip's tools `blip_schedule_tx/5`, `delete_tx/3`. Moduledoc: targets, the routine, the fence, consent and overlap, that there is no process. |
| `Photon.Schedules.Schedule` | data (Ecto schema) | `use Boundary, type: :strict, deps: [Ecto]` | Section 3.1. |
| `Photon.Schedules.Rules` | core | `use Boundary, type: :strict, deps: []` | `schedule/2`, `from_tool/2`, `arm/4`, `fired_through/3`, `next_after/3`, `fire/2`, `text/1` (`"[Scheduled] " <> prompt`), `skipped_note/2`, `request_id/3`, `when_text/2` (the tool's "first at ..., then every N minutes"). Times are Unix milliseconds or `DateTime`s passed in. |
| `Photon.Schedules.Routine` | worker logic (task kind, inside `Photon.Schedules`) | none of its own | Moved from `Photon.Assistant.Routine` (section 3.3). |
| `Photon.Threads` | boundary | unchanged deps | `start_tx/4`, `send_tx/4` public with `:source` and `:request_id`. `stop/1` unchanged (section 3.7). |
| `Photon.Durable.Submission` | data | unchanged | `background?/1`. |
| `Photon.Assistant.Tools.Schedule`, `.ListSchedules`, `.CancelSchedule` | boundary (durable tools) | inside `Photon.Assistant` | Section 3.6, including `schedule`'s new description line. |
| `Photon.Assistant.Prompt` | core | (deps as in 7.2) | The schedule line of section 3.6. |
| `Photon` | namespace | `exports` add `Schedules`, `Schedules.Schedule`, `Skills`, `Skills.Skill` | Moduledoc lists the two contexts and their pure modules. |

`Photon.Assistant.Routine` and `test/core/assistant/routine_test.exs` are
deleted (the tests move to `test/core/schedules/rules_test.exs` and
`test/boundary/schedules_test.exs`).

### 7.4 apps/hub: web

| Module | Layer | Notes |
|---|---|---|
| `PhotonWeb.Router` | boundary | Section 6.1, all in task K7. |
| `PhotonWeb.Layouts` | boundary (UI) | `#nav-skills`; `active` takes `:skills`. |
| `PhotonWeb.TimeComponents` | boundary (UI components) | `local_time/1`, `local_datetime_input/1`, the colocated hooks `.LocalTime` and `.LocalDateTime` (section 3.9). Imported in `html_helpers`. |
| `PhotonWeb.ScheduleText` | functional core (web formatting) | Section 6.6. |
| `PhotonWeb.SkillsLive`, `SkillLive`, `SkillInstallLive` | server (LiveViews) | Sections 6.3 to 6.5. Talk only to `Photon.Skills` and `Photon.Projects`. `SkillInstallLive` fetches in `start_async`. |
| `PhotonWeb.ScheduleLive` | server (LiveView) | Section 6.7. Talks to `Photon.Schedules`, `Photon.Projects`, `Photon.Threads`. |
| `PhotonWeb.ProjectLive` | server (LiveView) | Section 6.6. Adds `Photon.Skills` and `Photon.Schedules`. |
| `PhotonWeb.ThreadLive` | server (LiveView) | `#thread-schedule`. |
| `PhotonWeb.OverviewLive` | server (LiveView) | Section 6.8. |
| `PhotonWeb.SettingsLive` | server (LiveView) | Section 6.10: the scheduled-work checkbox's label and hint. |
| `PhotonWeb.ConversationComponents` | boundary (UI components) | Section 6.9. |

Every `handle_event`, `handle_info`, `handle_params` and
`handle_async` hands its message to a context in at most 15 lines (rule
30). No Repo, Ecto, Req or PubSub in a LiveView (`LiveViewLogic`).

### 7.5 Credo and Boundary lists

`apps/hub/.credo.exs`:

- `FunctionalCore` `core_modules`: add `Photon.Skills.Skill`,
  `Photon.Skills.Enablement`, `Photon.Skills.Rules`,
  `Photon.Skills.SkillMd`, `Photon.Skills.Source`, `Photon.Skills.Prompt`,
  `Photon.Skills.MockPhrases`, `Photon.Schedules.Schedule`,
  `Photon.Schedules.Rules`, `PhotonWeb.ScheduleText`.
- `ProcessNameOwnership` `api_modules`: add `"Photon.Schedules"` and
  `"Photon.Skills"`. No new `names`.
- No `PreferCall`, `NoSleep` or `DiscardNeedsReason` entries.

`apps/core` and `apps/node`: unchanged.

## 8. Test plan

As in steps 1 and 2: core logic in `test/core` with plain inputs (rule
52); boundary tests through the public API with `assert_receive`,
`start_supervised!/1` and no sleeping (rule 55), without retesting core
tables (rule 53); LiveView tests through element IDs, never raw HTML.
Add `schedules skill_enablements skills` to `@tables` in
`test/support/data_case.ex`, children first: `schedules threads
project_files skill_enablements skills projects ...`.

### 8.1 Core (`test/core`)

- `skills/rules_test.exs`: names (`pdf-forms` ok; `PDF`, `-x`, `x-`,
  `a--b`, 65 characters, `new` and `install` refused with their
  messages); `suggest_name/1` (`PDF Forms`, `Café notes`, `***` to
  `skill`); description required and capped at 1,024; instructions at
  50,000 and 50,001; `save_check/2`; `mentions/2` with a folder listing
  and without (relative links, `scripts/` paths, `.py` names);
  `enable_check/1` at 29 and 30.
- `skills/skill_md_test.exs`: a plain file; CRLF and a BOM; quoted
  values with escapes; `|`, `|-`, `>`, `>-` blocks; a plain value folded
  over indented lines; a nested `metadata:` block skipped and listed in
  `ignored`; comments; missing front matter, unclosed front matter, empty
  body; missing name or description gives `nil` fields, not an error.
  Use two real SKILL.md files from public skill repositories as fixtures
  (in `test/support/fixtures/skills/`).
- `skills/source_test.exs`: `classify/1` for each row of the table in
  section 2.4 (including `.git`, trailing slashes, a non-http scheme);
  `skills_in_tree/3` for a file link, a folder with SKILL.md, a folder of
  skills at two depths, a nested SKILL.md skipped, 31 skills cut to 30,
  none, `truncated`; `left_out` capped at 20 with "and N more";
  `notes/3`; `candidate/3`'s `files_left_out` (mentions first, then the
  folder's files, deduplicated, at most 20; a paste with backticked
  `scripts/fill.py` gets that path); `error_message/2` for 404, 403, 429,
  timeout.
- `skills/prompt_test.exs`: `section([])` is nil; two skills by name,
  XML-escaped, whitespace collapsed, versions shown; `loaded/1` without
  left-out files (no extra line) and with `["scripts/fill.py",
  "reference.md"]` (the line naming both);
  `not_loaded/2` with and without enabled skills.
- `skills/mock_phrases_test.exs`: `skills` lists from a system text and
  says none without; `load skill x` calls `load_skill`.
- `schedules/rules_test.exs`: `schedule/2` for each row of its table;
  `from_tool/2` with today's messages (moved from the routine test);
  `arm/4`: a one-off at `now` and at `now - 30_000` arms at that time, at
  `now - 61_000` is `:finished`, a one-off whose `fired_through` equals
  its `first_at` (edited at 14:05:30 after firing at 14:05:00) is
  `:finished`; a repeating one with `first_at` 30 seconds ago arms at
  `first_at`, one with `fired_through` on that slot arms at the next
  slot, and one with `first_at` a day ago arms at the first slot at or
  after `now - 60_000`; `fired_through/3` for a task that hasn't fired, a
  done one-off, and a repeating task after a firing and after missed
  slots; `next_after/3` (moved); `fire/2` for every
  row of section 3.5's table; `text/1`; `skipped_note/2` for Blip and a
  thread; `request_id/3`.
- `threads/prompt_test.exs`: the skills section is absent with none and
  present with two; the `[Scheduled]` line; the text without skills is
  unchanged apart from that line.
- `assistant/prompt_test.exs`: with no skills there is no Skills section
  and nothing else moves (compare against the prompt built without the
  argument's section, not a stored copy, since K6 changes the schedule
  line); with skills the section sits between "How you work" and
  "Memory"; the schedule line says Blip's schedules post to its own
  conversation and points project work to New schedule (K6).
- `threads/mock_script_test.exs`, `assistant/mock_script_test.exs`: the
  skill phrasings; `[Scheduled] on box: $ ls` runs the command.
- `test/web/schedule_text_test.exs`: `every/1` for 5, 60, 90, 120, 1440,
  4320 and 10080 minutes; each outcome; `state/2` for waiting, done, and
  stopped for a repeating schedule and for a one-off.

### 8.2 Boundary (`test/boundary`)

- `skills_test.exs`: create (and a taken name), update with the right
  version bumps it, an old version is `:stale`, rename, delete removes its
  enablements; enable and disable for Blip and a project, idempotent, an
  unknown project refused, the 31st refused; `enabled/1` by name and per
  scope (a project's skills don't show for Blip or another project);
  `scopes/1`; every write announces `{:skills_changed, id}`; `install/2`
  keeps origin, source, notes and `files_left_out` from the candidate;
  `read/1` (written in K3, with `Source`).
- `skills_fetch_test.exs` (a `Req.Test` stub named `Photon.Skills`): a
  blob link (one tree call, one raw download, `left_out` from the tree);
  a tree link to a skill folder; a repo root link (the repo call for the
  default branch first); a folder of three skills, one of whose downloads
  fails; a plain non-GitHub link; an HTML page refused; a 300 KB file
  refused; a binary refused; a 404, a 403 rate limit; the tree call
  failing on a file link still downloads it with the note.
- `skill_tools_test.exs` (`@tag :durable`, scripted model): a thread in a
  project with `pdf-forms` on: `skills` answers with it; `load skill
  pdf-forms` records a result with the instructions and the details;
  a skill installed with `files_left_out` loads with the line naming
  them; turning it off, then `load skill pdf-forms` gets the error and
  `skills` no longer lists it; Blip with the skill on only for the
  project gets the error; the profile prompts list the skill for the
  right scopes only; a long skill loaded in an earlier run is cut in the
  next run's model input with the hint (through
  `Photon.Durable.Context.messages/1` on the stored entries).
- `schedules_test.exs` (`@tag :durable`, scripted model, a connected test
  machine with `ops:2` where a prompt runs a command):
  - create with each target; the row, the task (`conversation_id` nil,
    background) and the announcement
  - a one-off new-thread schedule a second ahead starts a thread whose
    first message is `[Scheduled] ...`, with source kind `"routine"` and
    the schedule's ID, records `"started"` and the thread on the row, and
    the task finishes
  - the first firing of a repeating new-thread schedule (`last_thread_id`
    nil) starts a thread instead of crashing, and its task is waiting
    again afterwards
  - a one-off created for 30 seconds ago (the current minute, as the form
    sends it) fires at once; editing it within the same minute, keeping
    the time, doesn't fire it again (`list/1` says `:done`)
  - a thread-target schedule wakes the thread and moves its `active_at`;
    while the thread is busy it queues (`"queued"`); a second firing while
    that one is still queued is `"skipped_queued"`
  - a repeating new-thread schedule skips while its last thread is still
    running (`"skipped_running"`): the prompt `on box: $ sleep 60` parks
    the thread on an op the test machine (`Photon.MachineOps.connect/2`)
    never finishes, and `run_now/1` a second time reports the skip
  - consent off (a non-async test that turns `:mock_model` off with
    `Application.put_env/3` and restores it `on_exit`, with Settings'
    `scheduled_work` false): `"skipped_consent"`, a notice entry in the
    thread for a thread target, none for a new-thread target
  - `update/3` aborts the old task and makes one new one with the new
    request ID; an old version is `{:error, :stale}`
  - a firing step that commits after the update is ignored. F10's way of
    holding a step (the blocking scripted model) doesn't apply: the fire
    step never blocks, and suspending the Store only queues the update
    behind the step's commit. Call the step directly instead: arm a
    thread-target schedule a second ahead, wait for the Scheduler to start
    its fire step (the task is `running` in `"fire"`, or build that state
    with `Tx`), keep that started `TaskRecord`, run `Schedules.update/3`,
    then call `Photon.Schedules.Routine.step("fire", started,
    %Photon.Durable.Runtime{task: started})` from the test. Assert it
    returns `:ignored`, no submission or thread came from it, and exactly
    one routine task is live (the new one). No test seam in production
    code
  - a task that fails: inside `Photon.Durable.commit/1`, finish the task
    as the Scheduler does (`Tx.finish(tx, task, "failed", ...)`) and call
    `Routine.on_fail(task, "boom", tx)`; the row's `last_outcome` is
    `"failed"`, `list/1` gives `{:stopped, "boom"}`, the change is
    announced, and saving the schedule arms a fresh task. A failure for a
    task the row no longer names changes nothing
  - `delete/1` aborts the task and nothing fires afterwards
  - `run_now/1` fires once without touching the task, and ignores
    consent
  - restart: create a schedule, stop and start the durable children as
    `durable_lifecycle_test.exs` does, and it still fires once
  - a thread-target firing queued behind a busy run, then
    `Threads.stop/1`: the scheduled prompt is withdrawn, no new run
    starts, and the next `run_now/1` is `"sent"`, not
    `"skipped_queued"`
- `assistant_tools_test.exs`: `schedule`, `list_schedules` and
  `cancel_schedule` over `Photon.Schedules` with today's texts and `sc_`
  IDs; cancelling a project schedule's ID is "There is no schedule";
  a rerun of the `schedule` call (same task ID) makes one schedule;
  `in_minutes: 0` fires at once; the `schedule` tool's description says
  it posts to Blip's own conversation.
- `threads_test.exs`: the profile's tools are exactly the eight;
  `start_tx/4` and `send_tx/4` with a source.
- `assistant_test.exs`: `stop/0` with `Submission.background?/1`.

### 8.3 LiveView (`test/web/live`)

- `sidebar_test.exs`: `#nav-skills` links to `/skills` and is marked on
  the skills pages.
- `pages_test.exs`: each new route mounts, and each not-found case
  redirects with its flash (task K7).
- `skills_live_test.exs`: empty state; rows with scopes; `#skill-<id>-blip`
  turns Blip on and off and the scopes line follows; a skill created in
  another process appears.
- `skill_live_test.exs`: create through `#skill-form` lands on
  `/skills/<name>`; a bad name shows the rule; preview tab; save bumps
  `#skill-meta`'s version; rename patches the URL; stale save shows
  `#skill-stale` and keeps the text; `#skill-scope-blip` and
  `#skill-scope-<project id>` toggle; with a dirty form, toggling
  `#skill-scope-blip` shows no `#skill-stale` and keeps the typed text; a
  toggle made from another process (`Skills.enable/2` for a project)
  turns on `#skill-scope-<project id>`; `#skill-delete` returns to
  `/skills`.
- `skill_install_live_test.exs` (the `Req.Test` stub): a paste fills
  `#install-form` and shows `#install-notes` for ignored front matter;
  a blob link fetches (`render_async/1`) and installs with
  `install_notes` kept; a folder of skills lists
  `#install-candidate-<n>` and `#install-selected` installs the picked
  ones; a taken name is shown and unselectable; a 404 shows
  `#install-error`.
- `project_live_test.exs`: `#project-add-skill` opens
  `#project-skill-picker`, an option turns the skill on and it appears in
  `#project-skills`; `#project-skill-<id>-off`; a toggle from
  `/skills` updates the open page; schedules list with
  `#schedule-<id>-when`, `-last`, `-last-thread` after a firing;
  `#schedule-<id>-run` flashes and starts a thread;
  `#schedule-<id>-delete`; `#schedules-consent` shows when consent is
  off (the non-async setup above); a firing announced from another
  process updates the row; renaming the thread a schedule last started
  (`Threads.rename/2`, or the titling task's rename) updates
  `#schedule-<id>-last-thread`; a schedule whose task failed shows the
  stopped words in `#schedule-<id>-when`.
- `schedule_live_test.exs`: create with each target and repeat through
  `#schedule-form` (setting `schedule[at]` directly), errors under their
  fields (blank prompt, past one-off, 2 minutes, a thread from another
  project), `?thread=` preselects, edit replaces the task (one live
  routine task afterwards), `#schedule-run`, `#schedule-delete`; saving
  a one-off with `schedule[at]` set to the current minute (up to 59
  seconds ago) fires it: the project gets a thread and the row says
  `"started"`; with a prompt typed but not saved, a firing from another
  process (`Schedules.run_now/1`) updates `#schedule-last` and leaves
  `#schedule-prompt`'s typed text; a save after another process edited
  the schedule shows `#schedule-stale`; deleting it elsewhere returns to
  the project page.
- `thread_live_test.exs`: `#thread-schedule` links to the form with the
  thread; a scheduled prompt shows the "Scheduled" bubble; a `load_skill`
  call shows its line.
- `overview_live_test.exs`: Blip's schedules from `Photon.Schedules`,
  cancel, and a project schedule not listed.
- `test/web/components/time_components_test.exs`: `local_time/1` renders
  the ISO `datetime` and the UTC fallback.
- `settings_live_test.exs`: the scheduled-work checkbox's label reads
  "Let schedules use my plan while I'm away" (an element test on the
  label for `settings[scheduled_work]`).

### 8.4 End to end

`apps/hub/test/integration/machine_tools_e2e_test.exs` gains one test
against the real local node: a project with a skill `say-hello` turned
on ("Run `echo hello` when asked to greet."); a one-off new-thread
schedule a second ahead with the prompt `on local: $ pwd`; the schedule
starts a thread whose command's output ends in `/workspace/<slug>`, and
the row says `"started"` with that thread; in that thread, `load skill
say-hello` returns the instructions.

### 8.5 Checks

In `apps/hub` (the only app this step changes):

- `mix precommit`
- `mix dialyzer`; any new ignore entry has a reason comment
- `mix test --cover` at the hub's threshold (85)
- TLC for the `Durable` configs listed in section 10

## 9. OTP rules that apply

| Rule | Where it bites |
|---|---|
| 2, 3, 31, 89 | No new process. Skills and schedules are rows behind APIs; a schedule's timer is a durable task the existing Scheduler runs; fetching runs in the install page's `start_async` task. |
| 6, 69 | `Photon.Skills` exports its schema and the two pure modules the profiles' prompts and scripts need; `Photon.Schedules` exports its schema. Errors are field maps, short atoms or messages, never changesets. |
| 11 | LiveViews call the contexts; `Req` only in `Photon.Skills.Fetch`. |
| 15 | A schedule's next time is derived from its live task; a skill's place is its enablement rows; nothing about loaded skills is stored outside the transcript. |
| 28, 29 | `Skills.Rules`, `SkillMd`, `Source`, `Prompt`, `MockPhrases`, `Schedules.Rules` and `ScheduleText` are pure; IDs (`sk_`, `sc_`) and times are passed in. |
| 30 | Callbacks stay within 15 lines; the routine's step is a commit around core decisions. |
| 61 | Schedules reuse the durable task, its wait, its fence and its abort; skill loads reuse the tool's `{:commit, fun}`; announcements reuse `Tx.announce/3`. |
| 64 | Form input, tool arguments and fetched files are checked once, in the rules, through the contexts. |
| 67 | Every refusal says what to do: the name rule with an example, the 30-skill limit, the GitHub rate limit, "That time has passed.", the consent banner. |
| 73 | Prompts list at most 30 skills per scope; downloads are capped at 256 KB and 30 candidates with bounded concurrency; schedules can't repeat faster than five minutes and skip instead of piling up (section 3.5). |
| 86 | A crash loses nothing new: rows, durable tasks and the transcript hold it all; a fetch in flight is lost with its page and the owner fetches again. |
| 93 | `Task.async_stream/3` with `max_concurrency: 6` for candidate downloads. |

## 10. TLA+: is a spec change needed?

Yes, a change to `specs/tla/Durable.tla`, not a new spec. Skills need
none: a load is a read inside one commit, and a toggle is one commit, so
they serialize on the Store with nothing in flight between processes.
Schedules are different. `Durable.md` lists "recurring routines" and
"`cancel_schedule`" among what the spec leaves out, and this step makes
both owner-facing: an edit or delete from the project page can land
while a firing step is running, before or after a hub crash or a
Scheduler restart, and a new-thread firing makes a thread with no
request-ID dedupe to fall back on. The plan's claim (section 3.3) is that
the step fence alone makes each firing happen once and never after its
schedule was replaced. That is the kind of claim F10 showed is worth
checking.

What to add, following the code in section 3:

- Constants: `Spares` (routine IDs an edit can create; `{}` leaves edits
  out), `MaxFires` (firings of a repeating routine; 1 is today's one-off),
  `MaxEdits`, `MaxDeletes`, `Target` (`"conv"`: each firing posts
  `RS(r, k)` into the modeled conversation, as Blip's and thread-target
  schedules do; `"thread"`: each firing starts a thread, another
  conversation, so it is a ghost count), and two bug switches,
  `BugEditKeepsOld` and `BugFireIgnoresAbort`, both `FALSE` in the
  normal configs.
- Variables: `carrier` (the routine carrying the schedule, or `"none"`
  after a delete), `fires` (firing commits per routine), `retired` (an
  edit or delete replaced it), and ghosts `lateFire` and `dupFire`.
- `RoutineFire` generalized: in one fenced commit (`Ignored(st)` as now),
  post `RS(r, k)` or count a thread, then wait again with the next
  `until` while `fires < MaxFires`, else finish. `SubIds` grows to
  `RS(r, k)` for `k` in `1..MaxFires`.
- `OwnerEdit`: one commit that marks the carrier for abort (background
  included) and creates a pending spare routine as the new carrier
  (`BugEditKeepsOld` skips the mark). `OwnerDelete`: marks the carrier
  for abort and sets `carrier` to `"none"`.
- Invariants: `OneCarrier` (at most one routine is live and not marked
  for abort, and it is the carrier), `NoFireAfterRetire` (`~lateFire`: no
  firing commit lands for a routine after the commit that retired it),
  `FireOncePerSlot` (`~dupFire`: no two firing commits for the same
  routine and checkpoint), and `BackgroundNotWithdrawn` over the
  `RS(r, k)`. Liveness: `RetiredEnds` (a retired routine ends `aborted`)
  and the existing `PlacedSettles` and `NoRunningForever`.
- The overlap rules and consent are decisions inside the firing commit
  over committed state, so they are left out; `Durable.md` says so.
- The modeled conversation's Stop keeps background input, so with
  `Target = "conv"` it is Blip's conversation. A thread's Stop withdraws
  scheduled prompts too (section 3.7), which is the existing withdraw of
  a queued submission and needs no new action; `BackgroundNotWithdrawn`
  is about Blip, and `Durable.md` says so.
- Times aren't modeled, so `arm/4`'s grace and `fired_through` (section
  3.3) are checked by `schedules/rules_test.exs`, not here.

Configs:

| Config | Shape | Checks |
|---|---|---|
| `Durable-schedule.cfg` | no user input (K1: with one, TLC passed 160M states in two hours without finishing; the scheduled prompts queue behind each other instead), no tool calls, `Routines = {"r1"}`, `Spares = {"r2"}`, `MaxFires = 2`, `Target = "conv"`, 1 edit, 1 delete, 1 hub crash, 1 Scheduler crash, 1 step crash, 1 Stop | the safety set, `OneCarrier`, `NoFireAfterRetire`, `FireOncePerSlot`, `BackgroundNotWithdrawn` |
| `Durable-schedule-thread.cfg` | the same with `Target = "thread"`, and 1 user input so the conversation isn't empty | the same |
| `Durable-schedule-live.cfg` | 1 user input, `MaxFires = 2`, 1 edit, 1 hub crash, 1 Stop | `RetiredEnds`, `PlacedSettles`, `NoRunningForever` |
| `Durable-bug-edit-keeps-old.cfg` | `Durable-schedule.cfg` with `BugEditKeepsOld = TRUE` | expected to fail `OneCarrier` |
| `Durable-bug-fire-after-retire.cfg` | `Durable-schedule.cfg` with `BugFireIgnoresAbort = TRUE` | expected to fail `NoFireAfterRetire` |

Every existing `Durable*.cfg` sets `Spares = {}`, `MaxFires = 1`,
`MaxEdits = 0`, `MaxDeletes = 0`, `Target = "conv"` and both bug switches
`FALSE`, which is today's model; rerun them all and check their state
counts match the table in `Durable.md` (any difference is a modeling
error to explain). Run each with

```sh
cd specs/tla
java -XX:+UseParallelGC -cp ~/.local/share/tla/tla2tools.jar tlc2.TLC -workers auto -deadlock \
  -metadir /tmp/tlc-Durable -config Durable-schedule.cfg Durable.tla
```

adding `-lncheck final` for the config with `PROPERTIES`. Record the
results (states, time, the two bug configs' traces) in `Durable.md`, and
a step 3 entry in `docs/verification.md`. If TLC finds a problem in the
plan's rules, fix section 3.3 or 3.4 of this plan before K5a starts; K1
comes first for that reason. `HubOps.tla` and `Executor.tla` don't
change.

K1's result: every config passed, the two bug configs failed on the
property meant to catch them, and the 15 older configs reached their old
state counts. TLC found no problem in sections 3.3 and 3.4, which stand
as written. `specs/tla/Durable.md` has the numbers.

## 11. Ordered tasks

Each task is small enough for one agent, names its files and ends with
`mix precommit` passing in `apps/hub` (K1 ends with its TLC runs). "After"
lists what must be merged first. K1 and K2 can start at once.

Two ordering rules, as in step 2. Every route arrives in K7 with minimal
LiveViews before anything links to one, since `~p` warns at compile time
and `precommit` compiles with `--warnings-as-errors`. And a pure module
reaches another context's pure module only through that context, so a
context comes before the modules that use it.

K1. Durable.tla: repeating routines, edits and deletes. No dependencies.
- `specs/tla/Durable.tla`; new `Durable-schedule.cfg`,
  `Durable-schedule-thread.cfg`, `Durable-schedule-live.cfg`,
  `Durable-bug-edit-keeps-old.cfg`, `Durable-bug-fire-after-retire.cfg`;
  the new constants in every existing `Durable*.cfg`.
- TLC runs of every `Durable*.cfg` (section 10).
- `specs/tla/Durable.md` (what is modeled, the new actions and
  properties, results, the bug configs, the code it follows:
  `schedules/routine.ex`, `schedules.ex`), `docs/verification.md` (a
  step 3 entry).

K2. The skills context. No dependencies.
- Migration `apps/hub/priv/repo/migrations/20261008000000_create_skills.exs`
  (with `files_left_out`); `test/support/data_case.ex` `@tables`.
- New `apps/hub/lib/photon/skills.ex` (all of section 7.2's API except
  `read/1`, `fetch/1` and `load_tx/3`), `skills/skill.ex`,
  `skills/enablement.ex`, `skills/rules.ex`, `skills/skill_md.ex`
  (sections 2.1 to 2.3, 2.5, events in section 5). `install/2` takes the
  candidate as a plain map; nothing in K2 builds one.
- `apps/hub/lib/photon.ex` exports and moduledoc; `apps/hub/.credo.exs`
  (the four core modules, `Photon.Skills` in `api_modules`).
- Tests: `test/core/skills/rules_test.exs`,
  `test/core/skills/skill_md_test.exs` with the fixtures,
  `test/boundary/skills_test.exs` (all but `read/1`, with hand-built
  candidates for `install/2`).

K3. Reading and fetching skills. After K2.
- New `apps/hub/lib/photon/skills/source.ex` (with `candidate/3`,
  `notes/3` and `files_left_out`) and `skills/fetch.ex`; `Skills.read/1`
  and `Skills.fetch/1` in `skills.ex`. `read/1` comes here because its
  candidate and notes come from `Source` (section 2.4).
- `apps/hub/config/test.exs`: `config :photon, Photon.Skills,
  req_options: [plug: {Req.Test, Photon.Skills}]`.
- `.credo.exs`: `Photon.Skills.Source` in `FunctionalCore`.
- Tests: `test/core/skills/source_test.exs`,
  `test/boundary/skills_fetch_test.exs`, and `read/1` in
  `test/boundary/skills_test.exs`.

K4. Agents see and load skills. After K2.
- New `apps/hub/lib/photon/skills/prompt.ex` (with `loaded/1`'s
  left-out files line), `skills/mock_phrases.ex`; `Skills.load_tx/3`;
  `skills.ex` exports `Prompt` and `MockPhrases`.
- New `apps/hub/lib/photon/threads/tools/load_skill.ex` and
  `apps/hub/lib/photon/assistant/tools/load_skill.ex`.
- `threads.ex` (tools, prompt with skills, Boundary dep),
  `threads/prompt.ex` (`system_prompt/3`), `threads/mock_script.ex`;
  `assistant.ex` (tools, prompt with skills, dep),
  `assistant/prompt.ex` (`system_prompt/4`), `assistant/mock_script.ex`.
- `apps/hub/lib/photon_web/components/conversation_components.ex`: the
  `load_skill` label and icon.
- `.credo.exs`: `Prompt`, `MockPhrases` in `FunctionalCore`.
- Tests: `test/core/skills/prompt_test.exs`,
  `test/core/skills/mock_phrases_test.exs`, the prompt and mock script
  tests of both profiles, `test/boundary/skill_tools_test.exs`,
  `threads_test.exs` (the tool list), the conversation components test.

K5a. Schedule data and rules. After K1 (TLC may change sections 3.3 and
3.4).
- Migration `apps/hub/priv/repo/migrations/20261008010000_create_schedules.exs`;
  `@tables`.
- New `apps/hub/lib/photon/schedules/schedule.ex` and
  `schedules/rules.ex`: everything in section 7.3's `Rules` row,
  including `arm/4`, `fired_through/3`, `fire/2` and `from_tool/2`
  (sections 3.1 to 3.5).
- New `apps/hub/lib/photon/schedules.ex` with only its moduledoc and
  `use Boundary` declaration, so the schema and rules sit in their final
  boundary from the start; `photon.ex` exports; `.credo.exs`
  (`Schedule`, `Rules` in `FunctionalCore`, `Photon.Schedules` in
  `api_modules`).
- Tests: `test/core/schedules/rules_test.exs`, including copies of
  `routine_test.exs`'s `next_after` and `from_tool` cases (that file and
  `assistant/routine.ex` stay until K5c).

K5b. Threads take scheduled input. After K4 (K4 changes `threads.ex`,
`threads/prompt.ex` and `threads/mock_script.ex` too). Can run beside
K5a.
- `threads.ex`: `start_tx/4` and `send_tx/4` public, with `:source`
  (default `%{"kind" => "user"}`) and `:request_id`; `start/2` and
  `send/3` call them. `stop/1` doesn't change (section 3.7).
- `threads/prompt.ex`: the `[Scheduled]` line. `threads/mock_script.ex`:
  strip a leading `"[Scheduled] "`.
- Tests: `threads_test.exs` (`start_tx/4` and `send_tx/4` with a source
  and a request ID, a repeated request ID making one submission),
  `threads/prompt_test.exs`, `threads/mock_script_test.exs`.

K5c. The schedules context and the routine. After K5a and K5b.
- `apps/hub/lib/photon/schedules.ex`: the API of section 7.3 except
  `blip_schedule_tx/5` and `delete_tx/3` (sections 3.1 to 3.5, 3.8).
- `schedules/routine.ex`, moved from `assistant/routine.ex` (deleted),
  with the three targets, the facts gathered only for set IDs, the
  overlap rules and `on_fail/3`.
- `apps/hub/config/config.exs` and `config/test.exs`: `"routine" =>
  Photon.Schedules.Routine`.
- Tests: `test/boundary/schedules_test.exs` (section 8.2, including the
  direct-step race test, the first firing with no last thread, the
  failure, and Stop on a thread); delete
  `test/core/assistant/routine_test.exs`.
- Until K6, Blip's `schedule` tool still creates `"routine"` tasks with
  today's input (`"prompt"`, no `"schedule_id"`), and its tests must keep
  passing. So K5c's routine keeps today's behaviour for a task without
  `"schedule_id"` (post `"[Scheduled] " <> input["prompt"]` into the
  task's conversation, with today's consent note), and K6 removes that
  path. `assistant.ex`'s moduledoc line naming `Photon.Assistant.Routine`
  changes to `Photon.Schedules.Routine`.

K6. Blip's schedules over the context. After K5c.
- `Schedules.blip_schedule_tx/5`, `delete_tx/3`.
- `apps/hub/lib/photon/assistant/tools/schedule.ex` (with the new
  description line), `list_schedules.ex`, `cancel_schedule.ex` (section
  3.6); `assistant.ex` (`schedules/0`, `cancel_schedule/1`, `stop/0` with
  `Submission.background?/1`; `background_input?/1` goes; Boundary dep
  `Photon.Schedules`); `assistant/prompt.ex` (the schedule line, section
  3.6).
- `apps/hub/lib/photon/durable/submission.ex`: `background?/1`.
- `apps/hub/lib/photon_web/live/overview_live.ex`: `Schedules.list(:blip)`
  and `Schedules.subscribe/0` (times stay as today's text until K8).
- Remove K5c's no-`schedule_id` case from `schedules/routine.ex`.
- Tests: `test/boundary/assistant_tools_test.exs`, `assistant_test.exs`,
  `assistant/prompt_test.exs` (the schedule line),
  `test/web/live/overview_live_test.exs`, `assistant/mock_script_test.exs`
  (schedule results with `sc_` IDs).

K7. Every route, with minimal pages, and the sidebar entry. After K2 and
K5c.
- `apps/hub/lib/photon_web/router.ex`: section 6.1.
- New `apps/hub/lib/photon_web/live/skills_live.ex`, `skill_live.ex`,
  `skill_install_live.ex`, `schedule_live.ex`, each a mount that loads
  through its context, redirects with section 6.1's flash when the thing
  is missing, and renders `<Layouts.app ...>` with a heading and the
  right `active`.
- `apps/hub/lib/photon_web/components/layouts.ex`: `#nav-skills`,
  `active={:skills}`.
- Tests: `test/web/live/pages_test.exs` (mounts and redirects),
  `sidebar_test.exs` (`#nav-skills`).

K8. Times and schedule words. After K6.
- New `apps/hub/lib/photon_web/components/time_components.ex` (with the
  `.LocalTime` and `.LocalDateTime` colocated hooks) and
  `apps/hub/lib/photon_web/schedule_text.ex`; import the components in
  `photon_web.ex`'s `html_helpers`.
- `overview_live.ex`: schedule times through `local_time/1`, words
  through `ScheduleText` (`every/1`, `outcome/1`, `state/2`), and the line
  about project schedules.
- `.credo.exs`: `PhotonWeb.ScheduleText` in `FunctionalCore`.
- Tests: `test/web/schedule_text_test.exs`,
  `test/web/components/time_components_test.exs`,
  `overview_live_test.exs`.

K9. The Skills page and the skill editor. After K7.
- Fill in `apps/hub/lib/photon_web/live/skills_live.ex` and
  `skill_live.ex` (sections 6.3, 6.4).
- Move the `.UnsavedGuard` hook out of
  `apps/hub/lib/photon_web/live/context_file_live.ex` into a shared
  component, and use it in both editors (`context_file_live_test.exs`
  must still pass).
- Tests: `test/web/live/skills_live_test.exs`,
  `test/web/live/skill_live_test.exs`.

K10. Installing from the app. After K3 and K7.
- Fill in `apps/hub/lib/photon_web/live/skill_install_live.ex` (section
  6.5).
- Tests: `test/web/live/skill_install_live_test.exs`.

K11. The project page's skills and schedules, the thread page's
Schedule link, and the Settings wording. After K7 and K8.
- `apps/hub/lib/photon_web/live/project_live.ex` (section 6.6, including
  the schedules reload on `{:projects_changed, id}` and the stopped
  state), `apps/hub/lib/photon_web/live/thread_live.ex`
  (`#thread-schedule`), `apps/hub/lib/photon_web/live/settings_live.ex`
  (section 6.10).
- Tests: `test/web/live/project_live_test.exs`, `thread_live_test.exs`,
  `settings_live_test.exs`.

K12. The schedule form. After K7 and K8.
- Fill in `apps/hub/lib/photon_web/live/schedule_live.ex` (section 6.7:
  the version field and `#schedule-stale`, and the
  `{:schedules_changed, _}` handler that never touches the form);
  `Schedules.new_params/1` if K5c left it out.
- Tests: `test/web/live/schedule_live_test.exs`.

K13. End to end, docs and the final checks. After all of the above.
- `apps/hub/test/integration/machine_tools_e2e_test.exs`: section 8.4.
- `docs/architecture.md`: the module map (both contexts, the moved
  routine, the load tools, the new web modules), the supervision note (no
  new processes; the new `/live` routes), a step 3 entry in the refactor
  log.
- `docs/projects-and-blip.md`: status lines under "Build order" and in
  "Concepts" for skills and schedules, and the choices of section 12 that
  change the design's words: Stop in a thread withdraws everything
  queued, scheduled prompts included, while Blip's Stop keeps them; the
  overlap rules.
- `apps/hub/lib/photon.ex` and `Photon.Application` moduledocs, final
  pass.
- Section 8.5. The PR description says to delete the hub database (Blip's
  old routines aren't carried over).

## 12. Decisions made in this plan

None need the owner before the build. The owner's decisions in
`docs/projects-and-blip.md` settle the model; these are the choices made
inside them, all reversible:

- Skills follow the SKILL.md format: a name of lowercase letters, digits
  and hyphens (at most 64), a description of at most 1,024 characters,
  and instructions of at most 50,000. Names are unique and are how agents
  load skills.
- Install strips rather than refuses: it never downloads other files,
  drops other front matter, keeps the instructions as written, and says
  all of that in notes kept on the skill. It refuses only what isn't a
  readable skill.
- GitHub links are read through GitHub's API without a sign-in (60
  requests an hour, two per link). The rate-limit message says to try
  later or paste.
- A link to a folder of skills offers up to 30 to pick from.
- At most 30 skills on per scope, to bound every prompt.
- `load_skill` is offered even with no skills on, so tool lists stay
  stable.
- A loaded skill that was installed without some of its files names
  them and tells the agent not to look for them.
- Turning a skill off doesn't rewrite history: the prompt tells the model
  to stop following loaded skills that aren't listed, and to reload one
  whose version went up.
- Schedules get their own table; the durable task is only the timer. An
  edit replaces the task, and the new task fires the first time on the
  schedule that the old one hadn't fired, allowing a minute's grace.
- A firing is skipped instead of piling up: a new-thread schedule waits
  for its last thread to finish, and a prompt doesn't queue behind one
  of its own. This applies to Blip's schedules too, a small change from
  today.
- A Stop in a thread withdraws scheduled prompts that are waiting, as in
  step 2, so Stop doesn't start the next run at once; the schedule's next
  firing still comes. Blip's Stop keeps them, as today.
- A one-off time up to a minute ago fires at once, from the form or from
  Blip, and an edit never fires a time the schedule already fired
  (section 3.3).
- A schedule's edit form refuses a stale save, as skills and context
  files do, and a firing never rebuilds the form.
- A schedule whose task fails says so on the project page and starts
  again when saved; there is no automatic retry.
- Blip's schedules post to Blip's conversation, and Blip says so when
  asked for project work until step 4 gives it project tools.
- Run now fires without the consent check, since the owner is there.
- Times are entered and shown in the browser's time zone; repeats are
  fixed intervals and drift by an hour across daylight saving changes.
- Blip's schedules are still made by asking Blip and listed on the home
  page; there is no form for them.

## 13. Review

A review of this plan raised fourteen findings. Each was checked against
the plan, `docs/projects-and-blip.md` and the step 2 code
(`impl/step-2` at `0729fef`). All fourteen were real, and two of them
(1 and 6) were the same bug. Where a finding offered a choice, or its fix didn't go far enough,
the notes say what this plan did instead.

- Findings 1 and 6 (major): a one-off for the current minute never
  fires and shows Done, and `arm/3` drops one-offs the form and Blip
  accept. They are the same bug. `Rules.from_tool` today refuses only `ms < now - 60_000`,
  the form allows the same minute, and `arm/3` returned `:finished`
  for any past one-off. Fixed in section 3.3 with `arm/4`, which fires
  anything within the grace. The suggested fix alone would fire a
  one-off twice when it is edited in the minute after it fired, keeping
  its time, and would re-fire a repeating schedule's first slot. So
  `arm/4` also takes `fired_through`, read from the old task, and
  `:finished` remains only for a time already fired. The clock is read
  once per commit and shared by the rules and `arm/4`. Tests in 8.1,
  8.2 and 8.3.
- Finding 2: the Settings checkbox names only Blip. Real: `settings_live.ex`
  says "Let Blip use my plan for schedules while I'm away" and "Off,
  Blip skips them and says so." New section 6.10, in K11, with a test.
  The hint says where each kind of skip shows, rather than the
  finding's "say so on the project page or in the conversation".
- Finding 3: Stop on a thread restarts it when a scheduled prompt is queued.
  Real: `Durable.abort/2` withdraws only what its filter picks, then
  `continue_inbox/2` places the next queued input. Took the first
  option: `Threads.stop/1` stays as step 2 has it and withdraws
  everything, and the schedule's next firing still comes (section
  3.7). Keeping the prompt and showing it after Stop would leave the
  owner one more thing to cancel. This also takes the `stop/1` change
  out of the task list. K13 records it in the design doc, and section
  10 says the spec's Stop is Blip's.
- Finding 4: Blip puts project schedule requests in its own conversation. Real:
  Blip's prompt says "Use schedule for anything recurring or for
  later." and nothing about where they go. Section 3.6 changes that
  line and the tool's description, in K6, with a prompt test.
- Finding 5: a loaded skill doesn't say its files were left out. Real. Added a
  `files_left_out` column (section 2.1), built by `Source.candidate/3`
  and named in `Prompt.loaded/1`'s output (section 2.6). It is stored
  rather than parsed out of `install_notes`, which is prose for the
  owner.
- Finding 7: `Tx.active_run/2` with a nil thread ID. Real:
  `Queries.active_run/1` pins `conversation_id` in a `==`, and Ecto
  refuses nil there. Section 3.5 now gathers that fact only for a set
  ID; 8.2 tests the first firing.
- Finding 8: a failed routine task stops the schedule silently. Real:
  `Assistant.Routine` has no `on_fail/3`, and nothing announces a
  failure on `"schedules"`. `list/1` now returns a `state`,
  `Routine.on_fail/3` records `"failed"` and announces (section 3.3),
  and the project page shows the stopped state (section 6.6). The
  optional bounded retry is left out: the fire step's failures are
  bugs that would fail the same way on a retry, and saving the
  schedule starts it again.
- Finding 9: toggling a skill on its own page shows the stale banner. Real:
  toggles and saves announce the same message, and `ContextFileLive`'s
  pattern ignores same-version events. Section 6.4 splits the handler;
  two tests in 8.3.
- Finding 10: `ScheduleLive`'s reaction to `{:schedules_changed, _}` was
  unspecified. Real. Section 6.7 refreshes only the next and last run
  lines, and `update/3` takes the version and refuses a stale save
  (the row already had a `version` column). Tests in 8.3.
- Finding 11: project rows keep a thread's old title. Real once the step 2
  titling and rename work lands (it isn't in `impl/step-2` at
  `0729fef`; this plan already builds on it). Step 2's
  `{:projects_changed, id}` handler in `ProjectLive` reloads the
  project and threads only. It now resets the schedules stream too
  (section 6.6), with a test.
- Finding 12: the edit race can't be tested the F10 way. Real: F10 parks a step
  in the blocking scripted model, and the fire step has nothing to
  park on. Section 8.2 now calls `Routine.step("fire", ...)` directly
  with the started task after the update. `Runtime` is a plain struct
  with one field, `task`, so this needs no seam.
- Finding 13: K2's `read/1` needs K3's `Source`. Real. `read/1` and its test move
  to K3.
- Finding 14: K5 is too large. Real. Split into K5a (migration, schema, rules and
  their core tests, after K1), K5b (threads take scheduled input,
  after K4) and K5c (the context and the routine with the boundary
  tests, after both). `Submission.background?/1` moves to K6, its
  only user now that `Threads.stop/1` doesn't change.


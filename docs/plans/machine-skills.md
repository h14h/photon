# Skills turned on per machine

Plan for a small follow-up to the five build steps of
`docs/projects-and-blip.md`. Today a skill is on or off per scope: Blip,
or a project. This adds machines as a third kind of scope. A machine
skill is about working on that machine ("hosting private web apps" on
mp1, "running iOS simulators" on mm1), so it is offered to every agent
that can use the machine: Blip and every thread in every project,
whatever their own skill sets hold.

The work ships as one pull request, built as the ordered tasks in
section 12. Each section is meant to be read on its own: an agent handed
one task reads section 1, the sections its task points to, and the task.
Rule numbers refer to `docs/otp-design-guide.md`; the short version is
`docs/plans/otp-brief.md`. Paths are relative to the repo root. Module
names are the plan's; the placement is the point.

This plan was written against `main` at `12ea46e` ("Step 5 demo: A
run-now press that sent nothing flashes as an error."). Each task
re-reads the files it names before changing it.

The live hub has data, so nothing here resets it. As it turns out there
is no schema change at all (section 2.1), so there is no migration
either. No new dependency, process, registered name or route.

## 1. Goal and scope

After this change:

- A skill's page (`/skills/:name`) has a third group under "Turned on
  for": MACHINES, after ASSISTANT and PROJECTS, with one switch per
  machine the hub knows (connected or offline, not removed). The
  switches look like the others.
- A skill on for a machine is listed in Blip's prompt and in every
  thread's prompt, under that machine, in the Skills section. The agent
  is told to load it with `load_skill` when it starts work on that
  machine.
- `load_skill` accepts a skill that is on for any known machine, as well
  as the agent's own set (Blip's, or the thread's project's).
- `list_machines` names each machine's skills on its line, so the
  machine list says "mm1 ... skills: ios-simulators".
- A machine's skills are tied to its name. Uninstalling and reinstalling
  a machine under the same name keeps them. While a machine is removed,
  its skills are hidden everywhere and offered to no agent (section 2.4).
- Each machine holds at most 30 skills, the same limit as Blip and each
  project. The limit is per set, so it no longer bounds one prompt: an
  agent's prompt carries up to 30 for its own set plus 30 for each
  machine with skills on (section 3.3).
- Prompt caching holds: the Skills section changes only when a machine's
  skills change, a listed skill is saved or renamed, or a machine with
  skills is installed or removed. A machine connecting or disconnecting
  changes nothing in the prompt.
- `PHOTON_MOCK_MODEL=1` covers it: the scripted models' `skills` reply
  names the machine skills the prompt listed, and `load skill <name>`
  loads one. Section 7 walks through it with the built-in node, `local`.

Out of scope:

- A tool for Blip or threads to turn machine skills on or off. Blip
  keeps `set_project_skill` for projects only. A machine's skills are the
  owner's to change on a skill's page, as Blip's own set is. `list_skills`
  does report machine scopes, so Blip can say where a skill is on.
- Any "only on these machines" filter on project or Blip skills. Machine
  skills add to what an agent is offered; they never narrow it.
- Showing a machine's skills on the Nodes page. The skill page is where
  they are turned on; the Nodes page can list them later if it helps.
- Anything reaching a node. Skills stay instructions on the hub; nodes
  see only the shell commands an agent runs after reading one.

## 2. Data and the Skills API

### 2.1 The scope

`skill_enablements` already has a free-form `scope` string column,
`"blip"` or a project ID (`p_...`), with a unique index on
`[scope, skill_id]` and an index on `skill_id`. A machine scope is the
string `"machine:" <> machine_id`, for example `"machine:mm1"`.

- The prefix is needed. A node ID matches `~r/\A[\w.\-]{1,64}\z/`
  (`Photon.Provision.Jobs`), so a machine could be called `blip` or
  `p_x`. Node IDs can't contain `:`, so `"machine:"` can't collide with
  either of the other two forms.
- No column is added. Step 3 (section 2.5 of
  `docs/plans/step-3-skills-and-schedules.md`) left room for a nullable
  `machines` list on each row, but that was for narrowing a Blip or
  project enablement to some machines, which the owner ruled out. A
  third kind of scope fits the existing column exactly.
- Existing rows are untouched, so the live hub keeps its skills and needs
  no migration. Rows with the new prefix appear only once the owner
  turns a skill on for a machine.

In code a scope becomes `:blip | {:project, project_id} | {:machine,
machine_id}`. Only `Photon.Skills` turns it into the column's string and
back. `scope/1` (column to scope) gets the `"machine:" <> id` clause
before the project fallback, which today would read `"machine:mm1"` as
a project ID.

### 2.2 Which machines exist

`Photon.Machines` gets one public function:

- `known/0 :: [String.t()]`: the IDs of every machine the hub knows,
  connected or offline but not removed, `local` first, then by ID. The
  set is `roster/0`'s, read the same way (the connected machines from
  the registry, the IDs of node keys that aren't revoked, and `local`
  when the hub runs its own node). The order doesn't depend on who is
  connected, unlike `roster/0`'s (which lists connected machines before
  offline ones).

  Every connected machine other than `local` has a key, and `local` is
  known whenever the hub runs its own node, so in practice the set
  changes only when a node is installed (`NodeKeys.issue/2`) or removed
  (`NodeKeys.revoke/1`). That is what keeps prompts stable across
  connects and disconnects (section 3.3).

The rule is pure: `Photon.Machines.Roster.ids(online_infos, known_ids,
local_node?)`, beside `build/3`, returns the unique IDs sorted by
`{id != "local", id}`. `known/0` calls it with the same three inputs
`roster/0` reads.

### 2.3 The Skills API

All in `Photon.Skills` (`apps/hub/lib/photon/skills.ex`), with the pure
parts in `Photon.Skills.Rules` and `Photon.Skills.Prompt`.

Changed:

- `@type scope` adds `{:machine, String.t()}`.
- `enable/2` and `enable_tx/3` accept `{:machine, id}`. `scope_exists/1`
  checks `id in Machines.known()`; otherwise `{:error, "There's no
  machine called mm9."}`. The 30 limit (`Rules.enable_check/1`) counts
  the machine's own rows, so it applies per machine. Idempotent, and
  announces `{:skills_changed, skill_id}` as today.
- `disable/2` and `disable_tx/3` accept `{:machine, id}` for any ID,
  known or not, and do nothing when the row isn't there.
- `enabled/1` works for `{:machine, id}` unchanged (one query on the
  column string).
- `scopes/1` and `list/0` include machine scopes, but only for machines
  in `Machines.known/0`. Order: Blip first, then the rest in the order
  they were turned on, as today.
- `load_tx/3` keeps its signature. It reads `offered(scope)` inside the
  commit and finds the skill (by trimmed, downcased name) first in the
  agent's own set, then among the machine skills. Section 4 has the
  results.

New:

- `machine_skills/0 :: [{String.t(), [Skill.t()]}]`: each known machine
  that has skills on, with them by name, machines in `known/0` order. One
  query, every enablement whose scope starts with `"machine:"` joined to
  its skill (`like(e.scope, "machine:%")`), ordered by skill name; then
  `Rules.by_machine/2` groups the `{machine_id, skill}` pairs and keeps
  the known machines in order. A machine with no skills is left out.
- `offered/1 :: Prompt.offered()`, for an agent's scope (`:blip` or
  `{:project, id}`): `%{own: enabled(scope), machines:
  machine_skills()}`. Both profiles call it on every model request, so it
  is two queries plus `known/0`'s read of the node keys and the registry.

`Photon.Skills.Rules.by_machine(pairs, known)` (pure): `pairs` are
`{machine_id, skill}` in skill-name order, `known` the IDs in order.
Returns `[{machine_id, [skill]}]` for each ID in `known` that has at
least one pair, in `known`'s order; pairs for other IDs are dropped.

Boundary: `Photon.Skills` deps add `Photon.Machines`. There is no cycle:
`Photon.Machines` depends on `Durable`, `Events`, `NodeKeys` and `Repo`
only.

### 2.4 Removing and reinstalling a machine

The Nodes page has two steps for taking a machine away: Remove
(uninstall, which revokes the node's key with `NodeKeys.revoke/1` and
keeps the row with `revoked_at`) and then Forget (`NodeKeys.forget/1`,
which deletes the row). Neither touches `skill_enablements`.

- From Remove on, the machine isn't in `known/0`. Its rows stay but are
  hidden: no switch on the skill page, no "On for mm1" on the Skills
  page, nothing in `list_skills`, nothing in any prompt, and `load_skill`
  refuses its skills. Turning a skill on for it is refused ("There's no
  machine called mm1."), since there's no switch to do it from.
- Reinstalling under the same name (`NodeKeys.issue/2`, from the Nodes
  page or a manual install) makes it known again, and its skills are back
  as they were, after Forget too. The skills are tied to the name,
  which is what the owner asked for.
- The cost is that a different computer installed later under a
  forgotten machine's name inherits its skills. That is the same rule
  read the other way, and the skill page shows the switches on, so the
  owner sees it.
- Deleting a skill deletes its machine rows with the rest
  (`on_delete: :delete_all`).
- A manual uninstall the hub never hears about leaves the key
  unrevoked, so the machine stays known (offline) with its switches until
  the owner removes it on the Nodes page. That is how the Nodes page
  already treats it.

## 3. The prompt

### 3.1 Where machine skills appear

There is no machine list in either prompt today: an agent calls
`list_machines` for it, because online state changes too often to put in
a cached prompt. So machine skills go in the Skills section, grouped
under their machine, and `list_machines` names them on each machine's
line (section 5). That gives the agent both: the prompt tells it which
skills go with which machine before it starts, and the machine list it
reads says the same.

`Photon.Skills.Prompt.section/1` now takes an `offered()` map:

```elixir
@type offered :: %{own: [listed()], machines: [{String.t(), [listed()]}]}
```

and returns:

- `nil` when both are empty, as today
- with machines empty, exactly today's text, byte for byte. A hub where
  no skill is on for a machine sends the same prompt as before, so the
  deploy doesn't change any cached prompt
- otherwise today's heading and two preamble paragraphs, the
  `<available_skills>` block when `own` isn't empty, then the machine
  part:

```
## Skills

Skills are instructions for particular kinds of task, written or installed by the user. When a task matches a skill's description, load it with load_skill before you start, and follow it. Load only the skills the task needs.

Only the skills listed here are turned on. If you loaded a skill earlier in this conversation and it isn't listed any more, it was turned off or deleted: stop following it. If a skill's id or version here differs from the one you loaded, it has changed: load it again before you use it.

<available_skills>
<skill><name>pdf-forms</name><version>2</version><id>sk_...</id><description>Fill in PDF forms.</description></skill>
</available_skills>

Some skills are turned on for a machine because they are about working on it. Each is listed under its machine. Before you start work on one of these machines, load the ones your work there needs with load_skill, and follow them while you work on that machine. They don't apply to work on other machines.

<machine_skills>
<machine name="mm1">
<skill><name>ios-simulators</name><version>1</version><id>sk_...</id><description>Run and drive iOS simulators on this Mac.</description></skill>
</machine>
<machine name="mp1">
<skill><name>hosting-private-apps</name><version>3</version><id>sk_...</id><description>Serve a web app privately on the tailnet.</description></skill>
</machine>
</machine_skills>
```

Machines are in `known/0` order (`local` first, then by ID), skills by
name within each. The machine name is escaped like the other fields. A
skill on for Blip (or the project) and for a machine is listed in both
places; that is rare and costs one line.

### 3.2 Blip and threads

- `Photon.Threads.Prompt.system_prompt(project, now, offered)` and
  `Photon.Assistant.Prompt.system_prompt(settings, memory, now, offered,
  ambient?)` take the `offered()` map where they took the list, and pass
  it to `section/1`. The section stays where it is in each prompt.
- `Photon.Threads.system_prompt/1` passes `Skills.offered({:project,
  project.id})`; `Photon.Assistant.system_prompt/1` passes
  `Skills.offered(:blip)`.
- Neither prompt's other text changes. The thread prompt's moduledoc
  line "Nothing about the user goes in" still holds: a machine skill is
  the owner's text, turned on for that machine on purpose, as a project
  skill is turned on for that project.

### 3.3 What changes the prompt

| What happens | The agent's next request |
|---|---|
| A skill is turned on or off for a machine | Listed under it, or not, from the next request. A load in flight is ordered against the toggle by the Store (section 4). |
| A machine skill is saved, renamed or deleted | As step 3's section 2.7 says for any skill: new version or name, or gone. |
| A machine with skills is removed | Its group goes from the next request. The preamble already says to stop following a skill that isn't listed any more. |
| It is reinstalled under the same name | Its group is back. |
| A machine connects or disconnects | Nothing changes (`known/0` doesn't depend on it). |
| A run is in progress | The current request keeps its prompt; the next one in the run uses the new one, as today. |

The 30-skill limit applies to each set, so it bounds one prompt only as
30 × (machines with skills + 1). Every Blip and thread prompt carries the
machine groups, whatever the agent's own set holds. A description can be
up to 1,024 characters, so four machines at the limit would add 120
descriptions, up to about 120 KB, to every model request. The plan
accepts that and adds no hub-wide cap, because the owner set the limit
per machine and a single owner turns on a few skills for a few machines.
The `Photon.Skills` moduledoc states the bound in these terms. The
refusal at 30 ("30 skills are on here already. Turn one off first:
agents read every enabled skill's description on every request.") stays
as it is; it is as true of a machine as of a project.

## 4. `load_skill`

Both tools keep their modules and arguments
(`Photon.Assistant.Tools.LoadSkill` with `:blip`,
`Photon.Threads.Tools.LoadSkill` with the thread's project). Only
`Skills.load_tx/3` changes, so their moduledocs gain one sentence each
saying a machine's skills load too.

`load_tx(tx, scope, name)`:

- reads `offered(scope)` inside the commit that records the result, as
  it reads `enabled/1` today, so a load racing a toggle returns the text
  from before it or the error from after it
- found in the own set: today's result, unchanged
- otherwise found under one or more machines: `{:ok,
  Prompt.loaded(skill, machines), details}`, where `machines` are the
  machine IDs it is on for, in `known/0` order, and `details` adds
  `"machines" => machines` to today's `"skill"`, `"version"` and
  `"full_output"`
- not found: `{:error, Prompt.not_loaded(name, own_names,
  machine_names)}`, with `machine_names` as `[{machine_id, [name]}]`

`Prompt.loaded(skill, machines)` (pure; `loaded/1` stays as
`loaded(skill, [])`): with machines, the header names them and a line
follows the closing tag (before the left-out files line, if any):

```
<skill name="ios-simulators" id="sk_..." version="1" machines="mm1">
...the instructions...
</skill>
This skill is turned on for mm1: follow it when you work on mm1.
```

For several machines: `machines="mm1 mp1"` and "This skill is turned on
for mm1 and mp1: follow it when you work on those machines."

`Prompt.not_loaded(name, own, machines)`:

- `machines == []`: exactly today's `not_loaded/2` text, so its tests
  and the scripted models' replies stay as they are
- nothing on anywhere is the `machines == []` case with `own == []`:
  "No skills are turned on here."
- otherwise: "There's no skill called x turned on here or for a
  machine." then "Turned on here: a, b." when `own` isn't empty, then
  "For machines: mm1 has ios-simulators; mp1 has hosting-private-apps."

A removed machine's skills are refused as "no skill called ...",
because `offered/1` doesn't list them. A load that runs while the
machine is being removed may still return the skill: `NodeKeys` writes
outside the Store, so the removal isn't ordered against the commit.
That's harmless (the text is instructions, and the next request's prompt
no longer lists the skill, which tells the agent to stop following it).

## 5. Other readers of scopes

- `Photon.MachineTools.ListMachines`: each line gains "; skills: a, b"
  for a machine with skills on, from `Skills.machine_skills/0`, after
  whatever the line says now (online facts, offline, or outdated). For
  example `- mm1: offline; skills: ios-simulators`. One extra query per
  call. `Photon.MachineTools` Boundary deps add `Photon.Skills` (no
  cycle: `Photon.Skills` doesn't depend on it). Its moduledoc says so.
- `Photon.Assistant.Tools.ListSkills`: `place({:machine, id}, _)` is
  `"machine " <> id`, so a line reads "On for: you, garden, machine
  mm1." Its description adds: "or for a machine (the user turns
  machine skills on and off on the skill's page)". `Readout.skills/1`
  doesn't change.
- `PhotonWeb.SkillText.scopes/2`: `{:machine, id}` is labelled
  `"machine " <> id`, as `list_skills` does, so the Skills page reads
  "On for Blip, Garden and machine mm1", or "On for machine local". The
  word keeps a machine apart from a project name in the same list. Its
  `scope` type adds the machine form, and its moduledoc example names a
  machine.
- Both readers match scopes with closed clauses today (`:blip` and
  `{:project, _}`), so a machine row would crash them: `SkillText.scopes/2`
  raises `FunctionClauseError` and the Skills page fails to mount, and
  `list_skills` fails. Their machine clauses therefore land in K2, the
  task that starts returning `{:machine, id}` (section 12).
  `ListSkills`'s description and the `list_machines` suffix wait for K4.
- `Photon.Assistant.Tools.SetProjectSkill`, `ReadProject` and the
  project page's list read only a project's own scope and don't change.
- The project page's copy does change, since a project with no skills of
  its own still gets machine skills. `PhotonWeb.ProjectLive`'s empty
  state (`#no-project-skills`) becomes "No skills turned on. Skills are
  instructions this project's threads load when a task calls for them.
  Skills turned on for a machine reach them too." Its moduledoc's "the
  skills its threads may load" becomes "the skills turned on for it
  (threads also get the skills turned on for each machine)". No new UI.

## 6. The skill page and the Skills page

No new routes. The skill page already exists at `/skills/:name`, and
nothing new links anywhere.

### 6.1 The skill page (`PhotonWeb.SkillLive`)

The "Turned on for" section (`#skill-scopes-section`) gets a third
group after PROJECTS:

From `xl:` (wide screens):

```
Turned on for                Agents there see its name and description, ...
ASSISTANT     PROJECTS                         MACHINES
[o] Blip      [o] Garden      [ ] House        [o] local
                                               [ ] mm1
                                               [ ] mp1
                                               For Blip and every thread,
                                               when they work there.
```

Below `xl:`, MACHINES is a row of its own under the other two:

```
Turned on for                Agents there see its name and description, ...
ASSISTANT     PROJECTS
[o] Blip      [o] Garden      [ ] House

MACHINES
[o] local     [ ] mm1
[ ] mp1
For Blip and every thread, when they work there.
```

- Heading "Machines", the same `<h3>` classes as the other two.
- `#skill-machine-scopes`, a stream container (`phx-update="stream"`),
  with the grid classes in the Layout bullet below. Rows `skill-machine-row-<id>`
  (`stream_configure(:machines, dom_id: ...)`), each a `<.switch>` with
  `id="skill-scope-machine-<id>"`, `label` the machine ID,
  `phx-click="scope"`, `phx-value-machine={id}` and
  `phx-value-on={to_string(!on?)}`, so a double click or a stale page
  can't flip it the wrong way.
- `#skill-no-machines`: "No machines yet." (`hidden only:block`, like
  `#skill-no-projects`).
- `#skill-machines-hint` under the list, `text-[11.5px] text-ink-faint`:
  "For Blip and every thread, when they work there."
- Layout: the three groups share one row only from `xl:`. The page is
  `max-w-4xl` and the sidebar takes 256px from `lg:`, so at `sm:`
  (640px) the section has about 550px inside its padding, and at `lg:`
  (1024px) about 680px. A fixed MACHINES column in the same row would
  leave PROJECTS' two-column grid about 250px at `sm:` and 370px at
  `lg:`, cutting off most project names. From `xl:` (1280px) the
  section has about 800px, which leaves PROJECTS about 470px, room for
  two columns of names.
  - The outer container becomes `mt-4 flex flex-col gap-4 xl:flex-row
    xl:gap-8`.
  - Inside it, ASSISTANT and PROJECTS move into a wrapper with today's
    classes (`flex min-w-0 flex-1 flex-col gap-4 sm:flex-row sm:gap-8`),
    so the two keep exactly today's layout at every width.
  - MACHINES is `xl:w-52 xl:shrink-0`. Its list uses the PROJECTS grid,
    `grid gap-x-6 gap-y-2.5 sm:grid-cols-2`, plus `xl:grid-cols-1`, so it
    shows two columns on its own row and one column beside PROJECTS.
  - At 208px (`w-52`) the hint wraps onto two lines, not three.
- The rows are `Machines.known/0` in order, each `%{id:, on?:
  {:machine, id} in Skills.scopes(skill.id)}`. `load_scopes/1` builds
  them with the projects', from the same `scopes/1` read. Offline
  machines get a switch like connected ones; the label doesn't change
  with online state.

Events:

- `handle_event("scope", %{"machine" => id, "on" => on}, socket)`,
  before today's `"scope"` clause: `Skills.enable(skill_id, {:machine,
  id})` or `disable/2`. `:ok` reloads the switches; `{:error,
  :not_found}` is the deleted-skill path; `{:error, message}` is a flash
  and a reload (30 on already, or a machine removed since the page
  loaded).
- `handle_info(:nodes_changed, ...)` and `handle_info({:node_keys_changed,
  _}, ...)`, which `PhotonWeb.Shell` already passes on, call
  `load_scopes/1` for an open skill, so a machine installed or removed
  while the page is open gains or loses its switch.
- `{:skills_changed, id}` already re-reads where the skill is on, which
  now covers machines.

The moduledoc's "Turned on for" paragraph and its list of followed
messages say this.

### 6.2 The Skills page (`PhotonWeb.SkillsLive`)

- Rows already show `SkillText.scopes/2`; with section 5's label they
  name machines.
- `handle_info({:node_keys_changed, _}, socket)` reloads the list, so a
  removed machine drops out of "On for ..." lines. Removals are rare, so
  it reloads on every one rather than checking which skills name it.
- No switch for machines here; Blip's switch stays the only one.
- The intro under the heading (`skills_live.ex`, the `:subtitle`) says
  where a skill can be turned on, and today names only Blip and
  projects. It becomes "Instructions an agent loads when a task calls
  for them. A new skill is off everywhere until you turn it on for Blip,
  a project or a machine." The moduledoc gets the same sentence.

## 7. The scripted models

### 7.1 Changes

`Photon.Skills.MockPhrases`, shared by Blip's and a thread's scripted
model:

- `skills` reads the system prompt in two parts: the text before
  `<machine_skills>` for the agent's own skills (today's regex), and each
  `<machine name="...">...</machine>` block after it.
  - no machine skills: today's replies, unchanged ("Skills turned on
    here: pdf-forms (version 2)." or "No skills are turned on here.")
  - with machine skills, one more sentence: "For machines: local:
    hosting-private-apps (version 1); mm1: ios-simulators (version 1)."
    So with none of its own: "No skills are turned on here. For
    machines: local: hosting-private-apps (version 1)."
- `load skill <name>` is unchanged; the tool now accepts a machine
  skill, and the scripts' usual relay prints the result.

`Photon.Assistant.MockScript` and `Photon.Threads.MockScript` change only
their help lines: "`skills` lists the skills turned on for me, and for
each machine" (Blip) and "... for this project, and for each machine"
(a thread). `machines` already calls `list_machines`, whose lines now
name each machine's skills.

### 7.2 Trying it

Run the hub with `PHOTON_MOCK_MODEL=1`. The built-in node is `local`.

1. In the sidebar, open Skills, then Write a skill. Name
   `hosting-private-apps`; Description "Serve a web app privately on the
   tailnet from this machine. Use when asked to host or share a web
   app."; Instructions "Run the app on a free port, then `tailscale
   serve` it." Save.
2. On its page, under "Turned on for", tap the `local` switch under
   MACHINES. Its row on the Skills page now says "On for machine
   local".
3. Open Blip's panel and send `skills`. Blip answers "No skills are
   turned on here. For machines: local: hosting-private-apps (version
   1)."
4. Send `load skill hosting-private-apps`. The tool line names the skill
   and Blip relays its instructions, ending "This skill is turned on for
   local: follow it when you work on local."
5. Send `machines`. local's line ends "; skills:
   hosting-private-apps".
6. Start a project from the "+" next to Projects (name "Garden",
   Purpose "Keep the garden watered."), then a thread in it with the
   message `skills`. It answers the same as Blip: Garden has no skills of
   its own. `load skill hosting-private-apps` loads it there too.
7. Back on the skill's page, tap `local` off. In the thread, `skills`
   says "No skills are turned on here.", and `load skill
   hosting-private-apps` answers "That didn't work: No skills are turned
   on here." (the tool's error, as the script relays every failed tool
   call).

Removing a machine can't be tried with `local`, which the hub can't
remove. The boundary and LiveView tests cover it with issued and revoked
node keys (section 9).

## 8. Events

No new topics or messages.

- Turning a skill on or off for a machine announces `{:skills_changed,
  skill_id}` on `"skills"` with `Tx.announce/3`, in the commit, as every
  toggle does.
- Machines installed or removed already announce `{:node_keys_changed,
  node_id}` (`Photon.NodeKeys`), and connects and disconnects
  `:nodes_changed` (`Photon.Machines`). `PhotonWeb.Shell` subscribes to
  both on every page and passes them on, so the two skill pages only add
  `handle_info` clauses.
- Prompts aren't pushed anywhere: each profile builds its prompt at each
  model request, so there is nothing to announce to agents.

## 9. Module plan

Layers per the brief. Every public function keeps or gets a `@spec`.
No new modules, processes or registered names.

### 9.1 apps/core and apps/node

No changes. Nothing about skills reaches a node.

### 9.2 apps/hub: machines

| Module | Layer | Boundary | Change |
|---|---|---|---|
| `Photon.Machines.Roster` | core | unchanged (`type: :strict, deps: []`) | `ids/3` (section 2.2). Moduledoc line. |
| `Photon.Machines` | boundary | unchanged | `known/0`. Moduledoc: the known IDs, and why their order ignores who is connected. |
| `Photon.MachineTools` | boundary | deps add `Photon.Skills` | Moduledoc: `list_machines` names each machine's skills. |
| `Photon.MachineTools.ListMachines` | boundary (durable tool) | inside `Photon.MachineTools` | The "; skills: ..." suffix (section 5). |

### 9.3 apps/hub: skills

| Module | Layer | Boundary | Change |
|---|---|---|---|
| `Photon.Skills` | boundary | deps add `Photon.Machines` | `scope` type, `enable_tx/3`'s machine check, `scopes/1` and `list/0` filtered to known machines, `machine_skills/0`, `offered/1`, `load_tx/3` (sections 2.3, 4). Moduledoc: replace "Room for machines" with the machine scope, its column string, what removal does, and the prompt bound of 30 × (machines with skills + 1) (section 3.3). |
| `Photon.Skills.Enablement` | data | unchanged | Moduledoc: `scope` may be `"machine:<id>"`. |
| `Photon.Skills.Rules` | core | unchanged | `by_machine/2`. |
| `Photon.Skills.Prompt` | core | unchanged | `offered` type, `section/1` over it, `loaded/2`, `not_loaded/3` (sections 3.1, 4). Moduledoc. |
| `Photon.Skills.MockPhrases` | core | unchanged | The `skills` reply (section 7.1). |
| `Photon.Threads.Prompt` | core | unchanged | `system_prompt/3` takes `offered`. |
| `Photon.Threads` | boundary | unchanged | `system_prompt/1` calls `Skills.offered/1`. |
| `Photon.Threads.Tools.LoadSkill` | boundary (durable tool) | unchanged | Moduledoc sentence. |
| `Photon.Threads.MockScript` | core | unchanged | Help line. |
| `Photon.Assistant.Prompt` | core | unchanged | `system_prompt/5` takes `offered`. |
| `Photon.Assistant` | boundary | unchanged | `system_prompt/1` calls `Skills.offered/1`. |
| `Photon.Assistant.Tools.LoadSkill` | boundary (durable tool) | unchanged | Moduledoc sentence. |
| `Photon.Assistant.Tools.ListSkills` | boundary (durable tool) | unchanged | Machine places (K2), description (K4) (section 5). |
| `Photon.Assistant.MockScript` | core | unchanged | Help line. |

### 9.4 apps/hub: web

| Module | Layer | Change |
|---|---|---|
| `PhotonWeb.SkillLive` | server (LiveView) | The MACHINES group, the machine `"scope"` event, reloads on `:nodes_changed` and `{:node_keys_changed, _}` (section 6.1). |
| `PhotonWeb.SkillsLive` | server | Reload on `{:node_keys_changed, _}`, the intro sentence (section 6.2). |
| `PhotonWeb.SkillText` | core (web formatting) | "machine <id>" label in `scopes/2`, `scope` type (section 5, in K2). |
| `PhotonWeb.ProjectLive` | server | The `#no-project-skills` sentence and the moduledoc (section 5). |

### 9.5 Credo, Boundary and deps

- `apps/hub/.credo.exs`: no change. Every module touched is already in
  the lists it belongs in (`Photon.Machines.Roster`,
  `Photon.Skills.Rules`, `Photon.Skills.Prompt`,
  `Photon.Skills.MockPhrases`, both prompts and both mock scripts,
  `PhotonWeb.SkillText` in `FunctionalCore`). No new process names, no
  `PreferCall`, `NoSleep` or `DiscardNeedsReason` entries.
- Boundary: the two dep additions above. `Photon` already exports
  `Machines` and `Skills` to the web layer.
- `Photon.Skills` stays well under `ModuleDependencies`' limit of 20.
- No Hex dependency; `mix.exs` and `mix.lock` don't change. No
  migration, so `test/support/data_case.ex`'s `@tables` doesn't change.

## 10. Test plan

As in the earlier steps: pure logic in `test/core` with plain inputs
(rule 52); boundary tests through the public API with `assert_receive`
and no sleeping (rule 55), without retesting the core (rule 53);
LiveView tests through element IDs, never raw HTML. Tests make a machine
known by issuing its key (`NodeKeys.issue("mm1")`) and remove it with
`NodeKeys.revoke/1` and `forget/1`; `config/test.exs` has `local_node:
false`, so `local` is known only in tests that register it.

### 10.1 Core

- `test/core/machines/roster_test.exs`, `ids/3`: `local` first then by
  ID; the same result whichever machines are connected; a connected
  machine without a key is included; duplicates collapse; `local` left
  out when the hub doesn't run its own node and it isn't connected.
- `test/core/skills/rules_test.exs`, `by_machine/2`: groups in `known`
  order with skills in input order; drops unknown IDs; leaves out known
  machines with no pairs; `[]` for no pairs.
- `test/core/skills/prompt_test.exs`:
  - `section/1` with `machines: []` equals the old text for the same
    skills (the existing cases, with their input wrapped in the map)
  - machines only: preamble, no `<available_skills>`, the machine part
  - both, in order; two machines; a machine name with `&` escaped
  - `nil` for both empty
  - `loaded/2` with one and with two machines: header attribute and
    line; with left-out files too, the machine line comes first;
    `loaded/1` unchanged
  - `not_loaded/3`: `machines == []` gives `not_loaded/2`'s texts; with
    machines and own; machines only
- `test/core/skills/mock_phrases_test.exs`: `skills` with own and
  machine skills; machine skills only; the old cases unchanged.
- `test/core/threads/prompt_test.exs` and
  `test/core/assistant/prompt_test.exs`: existing cases pass `%{own:
  skills, machines: []}`; one case each that the machine part appears
  before "## Now" (thread) and before "## Memory" (Blip).
- `test/core/threads/mock_script_test.exs` (line 96) and
  `test/core/assistant/mock_script_test.exs` (line 118) build a prompt
  with `SkillsPrompt.section([...])`. They wrap their input as `%{own:
  [...], machines: []}`, with no other change.
- `test/web/skill_text_test.exs`: "On for Blip, Garden and machine mm1";
  a machine alone, "On for machine mm1".

### 10.2 Boundary

`test/boundary/machines_test.exs`:

- `known/0` lists issued keys and `local` when configured, leaves out a
  revoked node, and keeps its order while a registered machine connects
  and disconnects.

`test/boundary/skills_test.exs`:

- enable and disable for a machine; `scopes/1` returns `{:machine,
  "mm1"}`; the toggle announces `{:skills_changed, id}`; enabling twice
  or disabling what's off announces nothing
- enabling for an unknown machine: `{:error, "There's no machine called
  mm9."}`
- the 31st skill on one machine is refused, while a second machine and
  Blip still take skills
- `machine_skills/0` and `offered/1`: grouped in `known/0` order, own set
  separate, a project's `offered/1` includes the machine skills though
  the project has none of its own
- removal hides: after `NodeKeys.revoke("mm1")`, `scopes/1`, `list/0`,
  `machine_skills/0` and `load_tx/3` leave mm1's skills out; after
  `forget/1` too; after `NodeKeys.issue("mm1")` again they are back
- `load_tx/3` (inside `Durable.commit/1`): a machine skill loads for
  `:blip` and for a project scope, with `"machines"` in the details; an
  own skill that's also on for a machine loads without them; a missing
  name names both lists
- deleting a skill removes its machine rows

`test/boundary/skill_tools_test.exs` (durable, scripted models):

- a thread in a project with no skills: `skills` reports the machine
  skill; `load skill <it>` returns its instructions and the machine line
- Blip: the same
- turned off between two messages: the next `skills` no longer lists it
  and `load skill` fails

`test/boundary/machine_tools_test.exs`:

- `list_machines` for an offline known mm1 with a skill on: "- mm1:
  offline; skills: ios-simulators"; a machine with none has no suffix

`test/boundary/assistant_tools_test.exs`, next to "list_skills shows every
skill and where it is on": a skill on for mm1 reads "On for: machine
mm1." This case lands in K2, with the clause it tests.

### 10.3 LiveView

`test/web/live/skill_live_test.exs`:

- `#skill-machine-scopes` has `#skill-scope-machine-mm1` and
  `#skill-scope-machine-mp1` for issued keys, and nothing for a revoked
  one; with no machines, `#skill-no-machines` shows
- clicking `#skill-scope-machine-mm1` turns it on (`Skills.scopes/1`)
  and again turns it off
- the 31st on mm1 shows the refusal as a flash
- `NodeKeys.revoke("mm1")` while the page is open removes
  `#skill-machine-row-mm1`; `NodeKeys.issue("mm2")` adds a row
- a machine skill turned on elsewhere (through `Skills.enable/2`) shows
  as on

`test/web/live/skills_live_test.exs`:

- a skill on for mm1 shows "On for machine mm1" in its row (this case
  lands in K2, so the page is shown not to crash once machine rows
  exist)
- after `NodeKeys.revoke("mm1")` the row says "Off everywhere"

### 10.4 End to end

No change to `test/integration/machine_tools_e2e_test.exs`. Nothing about
skills reaches a node, so a real node adds nothing the boundary tests
don't cover.

### 10.5 Checks

In `apps/hub`: `mix precommit`, `mix dialyzer` and `mix test --cover`
pass. `apps/core` and `apps/node` don't change.

## 11. TLA+: is a spec change needed?

No. `HubOps.tla`, `Executor.tla` and `Durable.tla` stay as they are and
no config is rerun.

- No new process, task kind, timer, signal or protocol message. Nodes
  don't change.
- Every write is one commit of a kind that already exists: a toggle
  inserts or deletes one `skill_enablements` row, as Blip and project
  toggles do.
- `load_tx/3` still reads inside the commit that records the tool's
  result, so a load is ordered against a toggle by the Store, as step 3
  argued. The one new read that isn't serialized, which machines are
  known, comes from `node_keys` (written outside the Store). Its worst
  case is a skill loaded while its machine is being removed, which costs
  nothing (section 4).
- Prompts are rebuilt from rows at each request, which is how
  `Durable.tla` already models them: they aren't modelled at all.

What would change this: a tool that turns machine skills on from inside
a run, or anything that sends skills to nodes. Neither is in this plan.

K6 records this in `docs/verification.md`.

## 12. Ordered tasks

Each task is small enough for one agent, names its files, and ends with
`mix precommit` passing in `apps/hub`. "After" lists what must be merged
first. K1 can start at once. There are no new routes, so no task links
to a page before it exists.

K1. Known machines. No dependencies.
- `apps/hub/lib/photon/machines/roster.ex` (`ids/3`, moduledoc).
- `apps/hub/lib/photon/machines.ex` (`known/0`, moduledoc).
- Tests: `ids/3` in `test/core/machines/roster_test.exs`; `known/0` in
  `test/boundary/machines_test.exs`.

K2. The machine scope in the Skills context. After K1.
- `apps/hub/lib/photon/skills.ex`: scope type, column string and its
  parse, `enable_tx/3`'s machine check, `scopes/1` and `list/0` filtered,
  `machine_skills/0`, `offered/1`, `load_tx/3`; Boundary deps add
  `Photon.Machines`; moduledoc (sections 2.1 to 2.4, 4).
- `apps/hub/lib/photon/skills/rules.ex` (`by_machine/2`).
- `apps/hub/lib/photon/skills/prompt.ex`: the `offered` type,
  `loaded/2`, `not_loaded/3` (keep `loaded/1` and `not_loaded/2`
  delegating, as callers and tests use them). `section/1` stays on a
  list until K3.
- `apps/hub/lib/photon/skills/enablement.ex` (moduledoc).
- `apps/hub/lib/photon/assistant/tools/load_skill.ex` and
  `threads/tools/load_skill.ex` (moduledoc sentences).
- The two readers that match scopes with closed clauses, so no machine
  row can crash them once `scopes/1` and `list/0` return one (section
  5): `apps/hub/lib/photon_web/skill_text.ex` (`{:machine, id} ->
  ["machine " <> id]` in `scopes/2`, the `scope` type, the moduledoc
  example) and `apps/hub/lib/photon/assistant/tools/list_skills.ex`
  (`place({:machine, id}, _)` only; its description waits for K4).
- Tests: `test/core/skills/rules_test.exs`, the `loaded/2` and
  `not_loaded/3` cases of `test/core/skills/prompt_test.exs`,
  `test/boundary/skills_test.exs` (section 10.2),
  `test/web/skill_text_test.exs` (section 10.1), the `list_skills` case
  in `test/boundary/assistant_tools_test.exs` (section 10.2), and the
  "On for machine mm1" case in `test/web/live/skills_live_test.exs`
  (section 10.3).
- Tryable afterwards only through tests; K3 and K5 make it visible.

K3. Machine skills in prompts and the scripted `skills` reply. After K2.
- `apps/hub/lib/photon/skills/prompt.ex`: `section/1` over `offered`
  (section 3.1).
- `apps/hub/lib/photon/threads/prompt.ex`,
  `apps/hub/lib/photon/assistant/prompt.ex` (signatures, moduledocs).
- `apps/hub/lib/photon/threads.ex` and `apps/hub/lib/photon/assistant.ex`
  (`system_prompt/1` calls `Skills.offered/1`).
- `apps/hub/lib/photon/skills/mock_phrases.ex`;
  `assistant/mock_script.ex` and `threads/mock_script.ex` (help lines).
- Tests: the `section/1` cases of `test/core/skills/prompt_test.exs`;
  `test/core/skills/mock_phrases_test.exs`;
  `test/core/threads/prompt_test.exs`,
  `test/core/assistant/prompt_test.exs`;
  `test/core/threads/mock_script_test.exs` and
  `test/core/assistant/mock_script_test.exs` (input wrapped as `%{own:
  [...], machines: []}`, section 10.1);
  `test/boundary/skill_tools_test.exs` (section 10.2).
- With `PHOTON_MOCK_MODEL=1`, `Skills.enable(id, {:machine, "local"})`
  from `iex -S mix phx.server` then `skills` in Blip's panel shows it.
  The row this leaves is safe: the Skills page and `list_skills` read it
  since K2.

K4. Machine skills in `list_machines` and `list_skills`. After K2. Can
run alongside K3 and K5.
- `apps/hub/lib/photon/machine_tools/list_machines.ex`;
  `apps/hub/lib/photon/machine_tools.ex` (Boundary deps add
  `Photon.Skills`, moduledoc).
- `apps/hub/lib/photon/assistant/tools/list_skills.ex`: the description
  only (section 5); its machine clause came with K2.
- Tests: `test/boundary/machine_tools_test.exs` (section 10.2).

K5. The MACHINES group on the skill page, and the copy on the Skills
and project pages. After K1 and K2. Can run
alongside K3 and K4.
- `apps/hub/lib/photon_web/live/skill_live.ex` (section 6.1, moduledoc).
- `apps/hub/lib/photon_web/live/skills_live.ex`: the reload, the intro
  sentence and the moduledoc (section 6.2).
- `apps/hub/lib/photon_web/live/project_live.ex`: the
  `#no-project-skills` sentence and the moduledoc (section 5). Copy
  only.
- Tests: `test/web/live/skill_live_test.exs`, and the revoke case in
  `test/web/live/skills_live_test.exs` (section 10.3).
- After K3 and K5 both land, section 7.2's walk-through works.

K6. Docs. After K1 to K5.
- `docs/architecture.md`: the rows for `Photon.Machines`, `Roster`,
  `Photon.Skills` (scopes now include machines; `machine_skills/0`,
  `offered/1`), `Skills.Rules`, `Skills.Prompt`, `Skills.MockPhrases`,
  `ListMachines`, `ListSkills`, both `LoadSkill` tools, both prompts,
  `Photon.Threads` and `Photon.Assistant` (`offered/1` for the prompt),
  `SkillLive`, `SkillsLive`, `SkillText`; the paragraph on skills near
  the top.
- `docs/projects-and-blip.md`: a status note under **Skill** in
  Concepts; in "Left for later", the bullet becomes "skills with
  scripts"; the step 3 note's "skills scoped to machines" is marked as
  built by this plan.
- `docs/verification.md`: an entry for this follow-up saying no spec
  changed and why (section 11), and which tests cover the new claims
  (section 10.2's removal and load cases).
- Run section 7.2 by hand with `PHOTON_MOCK_MODEL=1` and fix anything it
  finds.

## 13. Decisions made in this plan

- **A scope string, not a column.** `"machine:<id>"` in the existing
  `scope` column. Step 3's idea of a `machines` column was for narrowing
  Blip or project skills, which the owner ruled out. No migration, and
  the live hub's rows are untouched.
- **Where the machine list is.** The owner's example puts a machine's
  skills on its line in "the machine list". The prompt has no machine
  list (online state would break caching), so the prompt groups machine
  skills under each machine in the Skills section, and `list_machines`,
  the machine list the agent reads, names them on each line.
- **Removal hides, Forget keeps.** Rows outlive Remove and Forget and
  come back with a machine reinstalled under the same name. They are
  hidden by reading, not deleted, so nothing has to run when a node is
  removed, and `Photon.NodeKeys` stays unaware of skills.
- **Known machines ignore connection state.** `Machines.known/0`
  orders `local` first then by ID, so a machine connecting or
  disconnecting never changes a prompt.
- **No machine tool for Blip.** Turning a machine skill on changes what
  every agent is offered, so it stays the owner's, like Blip's own set.
  `list_skills` reports machine scopes so Blip can answer "where is this
  on?".
- **A hub with no machine skills sends today's prompt.** `section/1`
  and `not_loaded/3` produce exactly the old text when there are none,
  so deploying this doesn't change any cached prompt or any scripted
  reply.
- **A machine's label says it is a machine.** The Skills page, like
  `list_skills`, reads "machine mm1", so "On for machine local" doesn't
  read as an adjective and a machine can't be mistaken for a project.
- **Machine skills beside projects only on wide screens.** MACHINES
  joins the ASSISTANT and PROJECTS row from `xl:`; below that it has its
  own row, so the projects grid keeps today's width.
- **No hub-wide cap.** The 30 limit is per machine, as the owner set it.
  A prompt can carry 30 × (machines with skills + 1) descriptions, and
  the plan says so rather than adding a second limit.
- **Own set first on load.** A skill in the agent's own set and on for a
  machine loads as an own skill, without the machine line, since it
  applies everywhere for that agent.

## Review

A review of this plan raised eight findings. Each was checked against
the code at `12ea46e` and the design.

Applied:

- Skills page intro. `skills_live.ex` line 100 reads "...until you turn
  it on for Blip or a project." Section 6.2 and K5 now change it to
  "...for Blip, a project or a machine." in the page and the moduledoc.
- Machine label. `SkillText.scopes/2` now labels a machine "machine
  mm1", as `list_skills` does (section 5). Sections 7.2 step 2, 10.1 and
  10.3 say "On for machine local" and "On for machine mm1".
- Crowded "Turned on for" row. The widths check out: at `sm:` the
  section has about 550px inside its padding, and PROJECTS would get
  about 250px for two columns. MACHINES now shares the row only from
  `xl:` and has its own row below that, with ASSISTANT and PROJECTS kept
  exactly as they are today (section 6.1).
- Project page copy. `#no-project-skills` and the `ProjectLive`
  moduledoc said the project's threads have no skills while they could
  load machine ones. Both now mention machine skills (section 5, K5).
  `ReadProject` and the list itself don't change.
- Machine scopes reaching readers too early. `SkillText.scopes/2` and
  `ListSkills.place/2` match only `:blip` and `{:project, _}`, so a
  machine row left by K3's iex check or K5's switch would crash the
  Skills page and `list_skills` until K4 and K5 both landed. Their
  machine clauses and the tests for them now land in K2, the task that
  starts returning `{:machine, id}`. K4 keeps the `ListSkills`
  description and the `list_machines` suffix.
- Two tests calling `section/1` with a list.
  `test/core/threads/mock_script_test.exs:96` and
  `test/core/assistant/mock_script_test.exs:118` are now in K3 and
  section 10.1.
- Walk-through step 7. A failed tool call reaches the script as
  "Error: ..." and `MachineTools.MockPhrases.relay_result/1` relays it as
  "That didn't work: ...". Step 7 now expects "That didn't work: No
  skills are turned on here." for `load skill` and keeps "No skills are
  turned on here." for `skills`.

Applied in part:

- The 30 limit and one prompt's size. True that the per-set limit no
  longer bounds a prompt: it is 30 × (machines with skills + 1). Section
  3.3, section 1 and the `Photon.Skills` moduledoc now say so, and the
  plan drops its citation of rule 73, which is about mailboxes, not
  prompt size. No hub-wide cap is added: the owner set the limit per
  machine, and a second limit would be a rule they didn't ask for. The
  refusal text stays. It says agents read every enabled skill's
  description on every request, which is as true for a machine scope as
  for a project.

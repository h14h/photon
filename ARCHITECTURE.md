# How Photon works

```
browser ──▶ hub: web UI, Blip, threads, schedules ◀──websocket── node ──▶ commands on that machine
             (everything saved in SQLite)          ◀──websocket── node ──▶ commands on that machine
                       │
                       └──▶ ChatGPT (your plan)
```

- **The hub** is a Phoenix LiveView app. It holds everything: the
  conversations, projects, skills, schedules and memory, all in one SQLite
  database. It's the only part that talks to the model, and it decides
  every tool call.
- **Nodes** are small, self-contained binaries, one per machine. They have
  no model and no state beyond a journal of the commands they're running.
  They carry out the operations the hub sends them (run a shell command,
  read an image) and report back.
- **The model** is ChatGPT, through your plan, signed in once on the hub
  with OpenAI's Sign in with ChatGPT. The hub calls it through the Responses
  API, with OpenAI's hosted web search turned on.

Everything is Elixir, in three Mix projects (see [The code](#the-code)).

## Agents

There are two kinds of agent, and both run on the hub.

**Blip** is one long conversation, the owner's assistant. It sees every
project and thread and can start, message and stop threads, read their
transcripts, start projects, turn a project's skills on, schedule prompts,
and keep a memory of what you tell it (shown and editable in Settings).
Threads ask Blip questions (`ask_blip`). Blip answers the ones it can
(`answer_question`) and brings the rest to you (`ask_owner`). When a thread
Blip cares about finishes, fails or gets stuck, the hub posts a signal into
Blip's conversation so it can follow up. Everything Blip does goes in the
activity log.

**Threads** are conversations inside a project. A thread's prompt holds the
project's name and purpose, and its tools read and write the project's
context files: Markdown notes kept on the hub. A thread's commands run in the
project's folder on whichever machine it picks
(`<workspace>/<project slug>`). Threads can't start threads or make
schedules. When one needs the owner's judgement, it asks Blip and waits.

Both kinds get the machine tools:

| Tool | What it does |
| --- | --- |
| `list_machines` | The machines, whether each is connected, and the skills turned on for each |
| `shell` | Runs a command on a machine, streaming its output |
| `view_image` | Reads an image file on a machine, so the model can see it |
| web search | OpenAI's hosted search |
| `load_skill` | Puts a skill's instructions into the conversation |

A thread's state (running, waiting on you, asking Blip, failed, unread,
quiet or idle) isn't stored. It's worked out from the thread's record
whenever it's read.

**Skills** are instructions (a name, a description, and Markdown), written
in the hub or installed from a SKILL.md or a GitHub link. A new skill is
off everywhere. It can be turned on for Blip, for a project (its threads),
or for a machine. A machine's skills are offered to every agent and listed
under that machine, so an agent about to work on a machine sees its skills
whatever the agent's own set holds.

**Schedules** are prompts that fire once or every so often. A project's
schedule starts a new thread or wakes an existing one. Blip's schedules post
into its own conversation. A firing that would pile up is skipped, and
schedules only use your plan while you're away if Settings allows it.

**Ambient mode** (Settings) gives Blip a digest of what changed every few
hours and a daily review of threads left alone. Those runs can only report;
they can't start new work.

## Nothing is lost on a restart

The hub's agent harness (`Photon.Durable`) saves before it shows. Every
message, model turn, tool call and result is committed to SQLite through one
line of atomic commits, and the work itself runs as durable tasks: small
state machines that checkpoint at every step. If the hub stops mid-turn, the
next boot carries on from the last checkpoint. A tool call waiting on a
machine, a question waiting for Blip, and a schedule waiting for its next
time are all durable tasks, so none of them hold a process while they wait.

One answered message:

```
submit(message) -> "user" entry
  generation task -> "assistant" entry, with tool calls
    tool task × n -> "tool_result" entry × n   (the generation waits for them)
  generation task -> "assistant" entry, the answer
```

A message sent while a conversation is busy waits its turn by default, or,
with **Steer**, joins the run after the current round of tool calls. **Stop**
cancels the run and its tool calls.

## Commands on nodes

Each command is an **operation** with an ID the hub chooses. The node's
executor writes an operation to its journal before running it, and writes
each snapshot (status, output so far, exit code) before sending it. So:

- a repeated request never runs a command twice;
- a command keeps running while the hub is unreachable;
- after every reconnect the node resends what it has, and the hub re-sends
  what it's still waiting on, so a lost message is never lost for good;
- the node forgets an operation only once the hub confirms it has stored
  the result.

Each command runs in its own process group, so Stop ends everything it
started. Live output streams to the browser as it arrives but isn't stored;
the result keeps bounded output. Nodes dial out to the hub, so they work
behind NAT. Either side ignores fields and messages it doesn't know, so the
hub and nodes can be updated in either order.

## Who can do what

- **Opening the hub:** a password, your own Tailscale devices, or either
  (`PHOTON_AUTH`). With Tailscale, the hub asks Tailscale which device each
  request comes from, and lets in only devices that belong to you (or to
  `PHOTON_TAILSCALE_USERS`) and aren't tagged.
- **Machines that run a node can't open the hub.** An agent's command
  there could otherwise drive the hub as you. A removed node's machine stays
  locked out until you choose **Let it open the hub** under Removed on the
  Nodes page.
- **Node keys:** each node has its own key, made by the hub, which keeps
  only its hash. Every install or update makes a fresh key and drops
  connections using the old one. On a tailnet a key is tied to its machine,
  so a copied key works nowhere else.
- **The ChatGPT sign-in** is kept in the hub's data directory
  (`chatgpt.json`, readable by the hub only) and refreshed by the hub.
  Nodes never see it. Usage counts against your plan, which you can see at
  [chatgpt.com/settings/usage](https://chatgpt.com/settings/usage).
- **No sandbox:** commands run as the node's user, with that user's access.

## Running a hub

**Fly.io**: `fly launch --copy-config` from the repo root builds the image
(including node binaries for every platform) and starts one always-on
machine with a volume at `/data`. The password is in `/data/password`, or
set your own with `fly secrets set PHOTON_PASSWORD=...`.

With a Tailscale auth key (`TS_AUTHKEY`), the hub joins your tailnet, lists
your machines for one-click installs (with `PHOTON_SSH_USER` as the login),
and lets your own devices skip the password. To keep a Fly hub off the
internet entirely, deploy it with `--no-public-ips`, set
`PHOTON_AUTH=tailscale` and `PHOTON_TAILSCALE_SERVE=1`, and set
`PHOTON_PUBLIC_URL` to `https://<TS_HOSTNAME>.<tailnet>.ts.net`. It then
answers only on your tailnet, over HTTPS, to your own devices.

**Docker**, for example on a machine already on your tailnet, behind
Tailscale Serve (or another TLS proxy on the same machine):

```sh
docker build -t photon .
docker run -d --name photon --restart unless-stopped --network host \
  -v "$HOME/photon-data:/data" -v /var/run/tailscale:/var/run/tailscale \
  -e PORT=8000 -e PHOTON_BIND=127.0.0.1 -e PHOTON_AUTH=tailscale \
  -e PHOTON_PUBLIC_URL=https://<hub>.<tailnet>.ts.net -e PHX_HOST=<hub>.<tailnet>.ts.net \
  photon
sudo tailscale serve --bg 8000
```

**Nodes**: the Nodes page installs a node over SSH (the tailnet's SSH policy
must let the hub log in) as a systemd (Linux) or launchd (macOS) user
service, and has **Update**, **Update all** and **Uninstall**. For any other
machine it makes a one-liner with a key for that node alone:

```sh
curl -fsSL https://<hub>/node/install.sh | PHOTON_NODE_ID=<name> PHOTON_NODE_TOKEN=<key> sh
```

The same script uninstalls (`PHOTON_ACTION=uninstall`, plus `PHOTON_PURGE=1`
to delete the node's data and workspace).

### Settings

Hub:

| Variable | Purpose |
| --- | --- |
| `PHOTON_AUTH` | Who may open the hub: `password` (production default), `tailscale` (only your devices on the tailnet), `tailscale,password` (those, else the password), or `off` |
| `PHOTON_PASSWORD` | The password (generated if unset) |
| `PHOTON_TAILSCALE_USERS` | Tailscale logins let in (default: whoever owns the hub machine) |
| `TS_AUTHKEY`, `TS_HOSTNAME`, `TS_EXTRA_ARGS` | Put the hub's container on a tailnet |
| `PHOTON_TAILSCALE_SERVE` | `1` serves the hub over HTTPS on its tailnet name |
| `PHOTON_SSH_USER` | Login for installing nodes over SSH |
| `PHOTON_PUBLIC_URL` | URL nodes use to reach the hub, if not detected |
| `PHOTON_BIND` | Address the hub listens on |
| `PHOTON_LOCAL_NODE` | Run a node inside the hub (default on in development, off in the image) |
| `PHOTON_DATA_DIR` | Where data lives (`.photon/`, or `/data` in the image) |
| `PHOTON_MOCK_MODEL` | `1` answers with scripted models instead of ChatGPT (development only) |

Node (written by the installer to `~/.config/photon-node/env`):

| Variable | Purpose |
| --- | --- |
| `PHOTON_SERVER` | The hub's websocket, e.g. `wss://hub.example.ts.net/node/websocket` |
| `PHOTON_NODE_TOKEN` | The node's own key, made by the hub (required) |
| `PHOTON_NODE_ID` | Node name (default: hostname) |
| `PHOTON_NODE_WORKSPACE` | Where commands run (default: `~/.photon-node/workspace`) |

## The code

| Path | What |
| --- | --- |
| `apps/core` | Shared by hub and node: the streaming model client, the message format, the operation protocol, and the scripted models tests use |
| `apps/node` | The node: the executor and its journal, the hub connection, packaged as one self-contained binary |
| `apps/hub` | The hub: the durable harness, Blip, threads, projects, skills, schedules, the node installer and the web UI |

Each app is its own Mix project, linked by path dependencies, so run Mix in
the app's directory:

```sh
(cd apps/core && mix test)
(cd apps/node && mix test)
(cd apps/hub && mix test)
(cd apps/hub && mix precommit)         # compiler and types, Boundary, format, Credo, tests
(cd apps/node && mix photon.package)   # node binaries, into apps/node/dist/
```

The code follows a strict split between pure decisions and the processes
and I/O around them, and tools enforce it. [AGENTS.md](AGENTS.md) lists the
checks, and [docs/otp-design-guide.md](docs/otp-design-guide.md) has the
rules they enforce.

Packaging uses [Burrito](https://github.com/burrito-elixir/burrito) and needs
`xz`, Zig 0.16.0 and an Erlang/OTP release Burrito publishes runtimes for,
e.g. `mise exec erlang@29.1 zig@0.16.0 -- mix photon.package`. A node can
also run from source with a key from the Nodes page:
`cd apps/node && PHOTON_SERVER=... PHOTON_NODE_ID=... PHOTON_NODE_TOKEN=... mix run --no-halt`.

Going deeper:

- [docs/architecture.md](docs/architecture.md): the code by layer, the
  commit line, and the supervision trees
- [docs/operations.md](docs/operations.md): the hub–node operation
  protocol and its rules
- [docs/decisions.md](docs/decisions.md): design choices and their reasons,
  and what isn't built yet
- [docs/verification.md](docs/verification.md): how Photon is tested
- `apps/hub/lib/photon/durable.ex`, `apps/node/lib/photon_node.ex` and
  `apps/core/lib/photon_core/operation/wire.ex`: the harness and the
  hub–node protocol, in their module docs

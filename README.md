# Photon

A personal assistant that lives on an always-on hub and gets real work done on
your machines. Everything is Elixir.

```
browser ──▶ hub: assistant + web UI ◀──websocket── node ──▶ agent harness on that machine
              (durable harness)     ◀──websocket── node ──▶ agent harness on that machine
```

- **The hub** runs one assistant you talk to in the web UI. It doesn't run
  commands itself: it hands work to your machines, keeps a memory, runs
  schedules, and tells you when work finishes. Its harness is durable, after
  Earendil's [pi-durable](https://github.com/earendil-works/pi/tree/main/packages/durable):
  every turn, tool call and schedule is committed to SQLite before it's shown,
  so if the hub restarts mid-turn it picks up where it stopped.
- **Nodes** run an agent on each machine, with a shell and the files there.
  Its harness is an Elixir port of Unreal Labs'
  [unreal-agent](https://github.com/unreallabsai/unreal-agent): asynchronous
  tool calls, an append-only session log, crash recovery, and each command in
  its own process group. Nodes dial the hub, so they work behind NAT, keep
  working while the hub is away, and catch up when it's back.
- **Models** are configured once, on the hub. Nodes reach the model through
  the hub, so they never hold an API key.

> [!WARNING]
> Node agents run shell commands **without a sandbox**, as the node's user.
> Install nodes on machines, VMs or containers you're happy for an agent to use.

## The code

| Path | What |
| --- | --- |
| `apps/core` | Shared: the streaming model client (any OpenAI-compatible API), the message format, the mock models |
| `apps/node` | The node: the agent harness (`PhotonNode.Harness`) and the hub connection, packaged as one self-contained binary |
| `apps/hub` | The hub: the durable harness (`Photon.Durable`), the assistant (`Photon.Assistant`), node sessions, installer, web UI |
| `docs/unreal-agent-port-spec.md` | What the node harness ports from unreal-agent, and where it differs |

## Try it locally

Needs Elixir 1.20+ with Erlang/OTP 28+.

```sh
git clone https://github.com/h14h/photon && cd photon/apps/hub
mix setup
mix phx.server
```

Open http://localhost:4000. The hub starts a built-in node called `local`, and
uses the **mock model** until you add an API key, so you can try everything
right away: type `help`, or `on local: $ uname -a`.

To use a real model, open Settings and pick a provider. The default is
Fireworks with DeepSeek V4.1 Flash (`accounts/fireworks/models/deepseek-v4p1-flash`);
OpenAI, OpenRouter, Ollama and any OpenAI-compatible endpoint work too.

## Deploy the hub to Fly.io

With [flyctl](https://fly.io/docs/flyctl/install/) (no Elixir needed):

```sh
git clone https://github.com/h14h/photon && cd photon
fly launch --copy-config
```

The first build takes several minutes, since it also builds node binaries for
every platform. You get one always-on machine with a volume for your data.

- **Sign in** with any username and the generated password:
  `fly ssh console -C "cat /data/password"`. Set your own with
  `fly secrets set PHOTON_PASSWORD=...`.
- **Optional: join your tailnet** with a Tailscale
  [auth key](https://login.tailscale.com/admin/settings/keys):
  `fly secrets set TS_AUTHKEY=tskey-auth-... PHOTON_SSH_USER=<you>`. The hub
  then lists your machines for one-click installs and lets tailnet devices in
  without the password.

The image runs anywhere Docker does, for example on a VM that's already on
your tailnet, behind Tailscale Serve:

```sh
docker build -t photon .
docker run -d --name photon --restart unless-stopped --network host \
  -v "$HOME/photon-data:/data" -v /var/run/tailscale:/var/run/tailscale \
  -e PORT=8000 -e PHOTON_BIND=127.0.0.1 -e PHOTON_AUTH=off \
  -e PHOTON_PUBLIC_URL=https://<hub>.<tailnet>.ts.net -e PHX_HOST=<hub>.<tailnet>.ts.net \
  photon
sudo tailscale serve --bg 8000
```

## Add nodes

Open **Nodes**:

- **On your tailnet:** click **Install** next to a machine. The hub connects over
  SSH, uploads the right binary, sets up a systemd (Linux) or launchd (macOS)
  user service, and waits for the node to connect. Your tailnet's SSH policy
  must let the hub log in to the machine. **Update** and **Uninstall** live
  there too.
- **Anywhere else:** run the one-liner the page shows, which includes your hub's
  URL and node token:

  ```sh
  curl -fsSL https://<hub>/node/install.sh | PHOTON_NODE_TOKEN=<token> sh
  ```

Nodes need no root and nothing else installed.

## Using the assistant

Ask in plain language. The assistant picks a machine (or uses the one you
name), writes the node's agent a self-contained task, and waits briefly for a
quick answer. Longer work keeps running and reports back into the
conversation when it's done. You can keep talking meanwhile: by default a new
message waits for the current answer, or choose **Steer** to fold it into the
work in progress. **Stop** cancels the run and its tools.

It also keeps a **memory** (shown and editable on the right) and runs
**schedules** ("every morning at 8, check my disks"). Each piece of node work
has its own page with every command and its output, where you can message
that agent directly.

## Configuration

Hub:

| Variable | Purpose |
| --- | --- |
| `PHOTON_PASSWORD` | GUI password (production; generated if unset) |
| `PHOTON_AUTH` | `off` drops the password, for a hub only reachable through the tailnet |
| `TS_AUTHKEY`, `TS_HOSTNAME`, `TS_EXTRA_ARGS` | Put the hub's container on a tailnet |
| `PHOTON_TRUST_TAILNET` | Let tailnet peers skip the password (default on, on a tailnet) |
| `PHOTON_SSH_USER` | Remote user for installing nodes over SSH |
| `PHOTON_PUBLIC_URL` | URL nodes use to reach the hub, if not detected |
| `PHOTON_BIND` | Address the hub listens on |
| `PHOTON_LOCAL_NODE` | Run the built-in node (default on in development, off in the image) |
| `PHOTON_DATA_DIR` | Where data lives (`.photon/`, or `/data` in the image) |
| `FIREWORKS_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY` | Model keys, if not set in Settings |

Node (set by the installer in `~/.config/photon-node/env`):

| Variable | Purpose |
| --- | --- |
| `PHOTON_SERVER` | The hub's websocket, e.g. `wss://hub.example.ts.net/node/websocket` |
| `PHOTON_NODE_TOKEN` | The hub's node token (required) |
| `PHOTON_NODE_ID` | Node name (default: hostname) |
| `PHOTON_NODE_WORKSPACE` | Where agents work (default: `~/.photon-node/workspace`) |

## Development

```sh
(cd apps/core && mix test)
(cd apps/node && mix test)
(cd apps/hub && mix test)
(cd apps/hub && mix precommit)         # every check: compiler and types, Boundary, format, Credo, tests
(cd apps/node && mix photon.package)   # node binaries, into apps/node/dist/
```

Each app has `mix precommit` and `mix dialyzer`; `AGENTS.md` lists the checks
and `docs/otp-design-guide.md` the design rules they enforce.

Packaging uses [Burrito](https://github.com/burrito-elixir/burrito) and needs
`xz`, Zig 0.16.0 and an Erlang/OTP release Burrito publishes runtimes for, e.g.
`mise exec erlang@29.1 zig@0.16.0 -- mix photon.package`. Nodes can also run
from source: `cd apps/node && PHOTON_SERVER=... PHOTON_NODE_TOKEN=... mix run --no-halt`.

The hub–node protocol, including how sessions survive reconnects, is documented
in `apps/node/lib/photon_node.ex`; the durable harness in
`apps/hub/lib/photon/durable.ex`.

<p align="center">
  <img src="docs/images/blip.svg" width="140" height="140" alt="Blip, Photon's assistant: an amber dot with two eyes, thinking, working and finishing a task">
</p>

# Photon

A personal assistant that lives on an always-on hub and gets real work done on
your machines. Everything is Elixir.

```
browser ──▶ hub: assistant + web UI ◀──websocket── node ──▶ commands on that machine
              (durable harness)     ◀──websocket── node ──▶ commands on that machine
```

- **The hub** runs one assistant you talk to in the web UI. It runs
  commands and reads images on your machines through their nodes, keeps a
  memory, runs schedules, and tells you when work finishes. Its harness is
  durable, after
  Earendil's [pi-durable](https://github.com/earendil-works/pi/tree/main/packages/durable):
  every turn, tool call and schedule is committed to SQLite before it's shown,
  so if the hub restarts mid-turn it picks up where it stopped.
- **Nodes** run the assistant's commands on each machine, each in its own
  process group, and journal every operation, so a command runs at most
  once and its result survives a dropped connection or a restart. The
  operation layer comes from an Elixir port of Unreal Labs'
  [unreal-agent](https://github.com/unreallabsai/unreal-agent). Nodes dial
  the hub, so they work behind NAT, keep running commands while the hub is
  away, and report back when it's back.
- **The model** is your ChatGPT plan: you sign in with ChatGPT once, on the
  hub. Only the hub talks to the model; nodes never hold the sign-in.

> [!WARNING]
> Nodes run the assistant's shell commands **without a sandbox**, as the
> node's user. Install nodes on machines, VMs or containers you're happy for
> an agent to use.

## The code

| Path | What |
| --- | --- |
| `apps/core` | Shared: the streaming model client (ChatGPT through the Responses API), the message format, the scripted models tests use |
| `apps/node` | The node: the executor that runs the hub's operations (`PhotonNode.Executor`) and the hub connection, packaged as one self-contained binary |
| `apps/hub` | The hub: the durable harness (`Photon.Durable`), the assistant (`Photon.Assistant`), its machine tools (`Photon.MachineTools`), installer, web UI |
| `docs/unreal-agent-port-spec.md` | What the node's operation layer ports from unreal-agent, and where it differs |

## Try it locally

Needs Elixir 1.20+ with Erlang/OTP 28+.

```sh
git clone https://github.com/h14h/photon && cd photon/apps/hub
mix setup
mix phx.server
```

Open http://localhost:4000, then Settings, and sign in with ChatGPT (see
below). The hub starts a built-in node called `local`, so you can try
`on local, what's my uptime?` right away.

To work on the hub without signing in, start it with
`PHOTON_MOCK_MODEL=1 mix phx.server`: Blip then answers with a scripted model
(type `help`, or `on local: $ uname -a`). That's for development only.

## Sign in with ChatGPT

Photon runs on your ChatGPT plan, through OpenAI's
[Sign in with ChatGPT](https://developers.openai.com/siwc/quickstart) for
open-source apps. It's the only way to give it a model.

1. In the hub, open Settings and choose **Sign in with ChatGPT**, then
   **Open ChatGPT**, and approve Photon.
2. ChatGPT sends your browser to a `http://127.0.0.1:…/auth/callback` page
   that won't load. That's expected: OpenAI only lets open-source apps
   return to the computer you're on, and the hub isn't it. Copy that page's
   whole address and paste it into Settings.

The hub keeps the tokens in its data directory (`chatgpt.json`, readable by
the hub only) and refreshes them itself. Nodes never see them, since only
the hub calls the model. Usage counts against your plan and Photon's
share of it, which you can see and limit at
[chatgpt.com/settings/usage](https://chatgpt.com/settings/usage).
Schedules run while you're away, so they only use your plan once you allow
it in Settings.

Sign in with ChatGPT is for your own use: one hub, run by you, for you.

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
  then lists your machines for one-click installs, and your own devices on
  the tailnet skip the password (`PHOTON_AUTH=tailscale,password`).

To keep a Fly hub off the internet entirely, deploy it with
`--no-public-ips`, set `PHOTON_AUTH=tailscale` and `PHOTON_TAILSCALE_SERVE=1`,
and `PHOTON_PUBLIC_URL` to `https://<TS_HOSTNAME>.<tailnet>.ts.net`: it then
answers only on your tailnet, over HTTPS, to your own devices.

The image runs anywhere Docker does, for example on a VM that's already on
your tailnet, where it can open for your devices on the tailnet and nobody
else, behind Tailscale Serve (or another TLS proxy on the same machine):

```sh
docker build -t photon .
docker run -d --name photon --restart unless-stopped --network host \
  -v "$HOME/photon-data:/data" -v /var/run/tailscale:/var/run/tailscale \
  -e PORT=8000 -e PHOTON_BIND=127.0.0.1 -e PHOTON_AUTH=tailscale \
  -e PHOTON_PUBLIC_URL=https://<hub>.<tailnet>.ts.net -e PHX_HOST=<hub>.<tailnet>.ts.net \
  photon
sudo tailscale serve --bg 8000
```

With `PHOTON_AUTH=tailscale` the hub asks Tailscale which device each
request comes from (the address the proxy forwards) and lets in only your
own devices: ones that belong to you (or to `PHOTON_TAILSCALE_USERS`),
aren't tagged, and don't run a node, so a command run on a node can't drive
the hub as you.

## Add nodes

Open **Nodes**:

- **On your tailnet:** click **Install** next to a machine. The hub connects over
  SSH, uploads the right binary, sets up a systemd (Linux) or launchd (macOS)
  user service, and waits for the node to connect. Your tailnet's SSH policy
  must let the hub log in to the machine. **Update** and **Uninstall** live
  there too.
- **Anywhere else:** name the node, and the page makes its one-liner, with
  your hub's URL and a key for that node alone:

  ```sh
  curl -fsSL https://<hub>/node/install.sh | PHOTON_NODE_ID=<name> PHOTON_NODE_TOKEN=<key> sh
  ```

Nodes need no root and nothing else installed. Each node has its own key: the
hub keeps only its hash and makes a fresh one with every install or update,
dropping any connection still using the old one. On a tailnet the key is
tied to its machine (up front when installed over SSH; otherwise to the
first machine that uses it within an hour), so a copied key works nowhere
else, and that machine stays kept out of the hub's GUI through every update.
Removing a node keeps its machine out too, until you choose **Let it open the
hub** under Removed on the Nodes page. **Update all** updates every node
running an older build at once.

## Using the assistant

Ask in plain language. The assistant picks a machine (or uses the one you
name) and runs commands there itself, showing each command and its output as
it runs. A command keeps running while the machine is briefly offline, and
its result comes back into the conversation when it's done. You can keep talking meanwhile: by default a new
message waits for the current answer, or choose **Steer** to fold it into the
work in progress. **Stop** cancels the run and its tools.

It also keeps a **memory** (shown and editable on the right) and runs
**schedules** ("every morning at 8, check my disks").

## Configuration

Hub:

| Variable | Purpose |
| --- | --- |
| `PHOTON_AUTH` | Who may open the GUI: `password` (production default), `tailscale` (only your devices on the tailnet), `tailscale,password` (those, else the password), or `off` |
| `PHOTON_PASSWORD` | GUI password (generated if unset) |
| `PHOTON_TAILSCALE_USERS` | Tailscale logins let in (default: whoever owns the hub machine) |
| `TS_AUTHKEY`, `TS_HOSTNAME`, `TS_EXTRA_ARGS` | Put the hub's container on a tailnet |
| `PHOTON_SSH_USER` | Remote user for installing nodes over SSH |
| `PHOTON_PUBLIC_URL` | URL nodes use to reach the hub, if not detected |
| `PHOTON_BIND` | Address the hub listens on |
| `PHOTON_LOCAL_NODE` | Run the built-in node (default on in development, off in the image) |
| `PHOTON_DATA_DIR` | Where data lives (`.photon/`, or `/data` in the image) |
| `PHOTON_MOCK_MODEL` | `1` answers with scripted models instead of ChatGPT (development only) |

Node (set by the installer in `~/.config/photon-node/env`):

| Variable | Purpose |
| --- | --- |
| `PHOTON_SERVER` | The hub's websocket, e.g. `wss://hub.example.ts.net/node/websocket` |
| `PHOTON_NODE_TOKEN` | The node's own key, made by the hub (required) |
| `PHOTON_NODE_ID` | Node name (default: hostname) |
| `PHOTON_NODE_WORKSPACE` | Where commands run (default: `~/.photon-node/workspace`) |

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
from source with a key from the Nodes page:
`cd apps/node && PHOTON_SERVER=... PHOTON_NODE_ID=... PHOTON_NODE_TOKEN=... mix run --no-halt`.

The hub–node protocol, including how operations survive reconnects, is
documented in `apps/node/lib/photon_node.ex` and
`apps/core/lib/photon_core/operation/wire.ex`; the durable harness in
`apps/hub/lib/photon/durable.ex`.

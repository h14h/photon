# Photon

A web GUI for [unreal-agent](https://github.com/unreallabsai/unreal-agent), Unreal
Labs' async-first agent harness, that runs agents across as many machines as you
like. Written in Elixir with Phoenix LiveView.

```
browser ──▶ hub (GUI, history) ◀──websocket── node ──▶ unreal-agent-runner
                              ◀──websocket── node ──▶ unreal-agent-runner
```

- **The hub** is the web app: sessions, settings, and the list of nodes. Run it
  on your laptop or deploy it to [Fly.io](https://fly.io) so it's always up.
- **Nodes** run the harness on each machine. They dial the hub over a websocket,
  so they work behind NAT, and a run keeps going if the hub restarts or the
  network drops, catching up when it reconnects.
- A node is a single self-contained binary for Linux or macOS (x86_64 and
  ARM64), installed as a user service. The hub can install it for you over
  Tailscale SSH, or with a `curl` one-liner.

Features: streaming transcripts with tool output and images, image attachments
(paste, drop or pick), Markdown, a built-in mock model to try it without an API
key, and OpenAI, OpenAI Codex, OpenRouter, Fireworks and Ollama providers.

> [!WARNING]
> Agents run shell commands on nodes **without a sandbox**, as the node's user.
> Run nodes on machines, VMs or containers you're happy for an agent to use.

## Try it locally

Needs Elixir 1.20+ (with Erlang/OTP) and Go 1.27+.

```sh
git clone https://github.com/h14h/photon && cd photon
mix setup
mix photon.build_runner   # builds unreal-agent-runner (needs Go)
mix phx.server
```

Open http://localhost:4000. The hub starts a built-in node called `local`, and
the default provider is the **mock model**, so you can send messages right away:
try `help`, `$ uname -a`, `sleep 5`, or attach an image. Choose a real provider in
Settings; leave the API key blank to use the provider's environment variable
(`OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `FIREWORKS_API_KEY`) on the node.

## Deploy the hub to Fly.io

With [flyctl](https://fly.io/docs/flyctl/install/) (no Elixir or Go needed):

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
  [auth key](https://login.tailscale.com/admin/settings/keys) (not reusable, not
  ephemeral): `fly secrets set TS_AUTHKEY=tskey-auth-... PHOTON_SSH_USER=<you>`.
  The hub then appears as `photon-hub`, lists your machines for one-click
  installs, and lets tailnet devices in without the password.

Update later with `git pull && fly deploy`. The image also runs anywhere:
`docker build -t photon . && docker run -p 8080:8080 -v photon-data:/data photon`.

## Add nodes

Open **Add a node** (the **+** next to *Nodes*):

- **On your tailnet:** click **Install** next to a machine. The hub connects over
  SSH, uploads the right binary, sets up a systemd (Linux) or launchd (macOS) user
  service, and waits for the node to connect. **Update** and **Uninstall** live
  there too, and the hub flags nodes that are out of date. Your tailnet's SSH
  policy must let the hub log in to the machine.
- **Anywhere else** (a VPS, cloud-init, a container): run the one-liner the panel
  shows, which includes your hub's URL and node token:

  ```sh
  curl -fsSL https://<hub>/node/install.sh | PHOTON_NODE_TOKEN=<token> sh
  ```

Nodes need no root and nothing else installed. A local hub must listen beyond
localhost for other machines to reach it: `PHOTON_BIND=<its tailnet IP>
mix phx.server`.

## Configuration

Hub:

| Variable | Purpose |
| --- | --- |
| `PHOTON_PASSWORD` | GUI password (production; generated if unset) |
| `TS_AUTHKEY`, `TS_HOSTNAME`, `TS_EXTRA_ARGS` | Put the hub's container on a tailnet |
| `PHOTON_TRUST_TAILNET` | Let tailnet peers skip the password (default on, on a tailnet) |
| `PHOTON_SSH_USER` | Remote user for installing nodes over SSH |
| `PHOTON_PUBLIC_URL` | URL nodes use to reach the hub, if not detected |
| `PHOTON_BIND` | Address the dev server listens on |
| `PHOTON_LOCAL_NODE` | Run the built-in node (default on; off on Fly) |
| `PHOTON_DATA_DIR` | Where data lives (`.photon/`, or `/data` in the image) |

Node (set by the installer in `~/.config/photon-node/env`):

| Variable | Purpose |
| --- | --- |
| `PHOTON_SERVER` | The hub's websocket, e.g. `wss://hub.fly.dev/node/websocket` |
| `PHOTON_NODE_TOKEN` | The hub's node token (required) |
| `PHOTON_NODE_ID` | Node name (default: hostname) |
| `PHOTON_NODE_WORKSPACE` | Where agents work (default: `~/.photon-node/workspace`) |

## Development

```sh
mix test                       # hub
(cd node && mix test)          # node
mix photon.package             # node binaries, into node/dist/
```

Packaging uses [Burrito](https://github.com/burrito-elixir/burrito) and needs Go,
`xz`, Zig 0.16.0 and an Erlang/OTP release Burrito publishes runtimes for, e.g.
`mise exec erlang@29.1 zig@0.16.0 -- mix photon.package`. Nodes can also run from
source: `cd node && PHOTON_SERVER=... PHOTON_NODE_TOKEN=... mix run --no-halt`.

The code is split into `lib/` (the hub) and `node/` (the node). The node's
protocol, including how runs survive reconnects, is documented in
`node/lib/photon_node.ex`.

# Distributed drives (layer 4)

The podman (or Docker) scenarios that make a TLC failure mode happen to a
real hub process and a real node process. This page is scaffolding. Nothing
here is wired into CI, nothing here is run by `mix precommit`, and
`verify-photon` is the wrong tool for it: that skill starts its own hub on
`127.0.0.1` and will not attach to a container you launched.

v1 is a compose sketch plus the manual steps under each scenario. Follow
them when you want a witness for an invariant in
[`tla/`](tla/README.md). Until someone automates the oracle, a passing
reading of this file is not a test result.

## What the two containers are

| Container | Process | Durable state |
| --- | --- | --- |
| `hub` | Photon release (`docker build -t photon .`, or `mix phx.server` with `PHOTON_BIND=0.0.0.0`) | Volume mounted at `PHOTON_DATA_DIR` (`/data` in the image). Holds `node-token`, `password`, and `sessions/<id>/events.jsonl`. |
| `node` | `photon-node`, or `cd node && mix run --no-halt` when you do not have a packaged binary | `PHOTON_NODE_DATA` (default `~/.photon-node`), including `node-events/<id>.jsonl`. This must survive a hub restart. It should not live only in the hub volume. |

The image listens on 8080 (`ENV PORT=8080` in the `Dockerfile`). A dev server
uses `PORT` or 4000. Pick one and use it in every URL below. Examples use
8080 and a user-defined network named `photon-net`.

`PHOTON_LOCAL_NODE=false` so the built-in `local` node is not a second
registration next to the container you are watching. The image already
leaves the local node off unless you set it true.

### Env vars

These are the ones the product already documents (root `README.md`,
`Photon.Hub`, `PhotonNode.Config`, `priv/node/install.sh.eex`).

| Variable | Where | Role in these scenarios |
| --- | --- | --- |
| `PHOTON_PUBLIC_URL` | hub | Base URL nodes use to reach the hub, for example `http://hub:8080`. Required when the hub is not on a tailnet and you do not want `Photon.Hub.public_url/1` to return `{:error, :loopback}`. No trailing path. |
| `PHOTON_BIND` | hub dev server | `0.0.0.0` so the node container is not talking to a loopback-only socket. The release image already binds the port it exposes. |
| `PHOTON_SERVER` | node | Websocket, `Photon.Hub.node_socket_url/1` of the public URL. For the example, `ws://hub:8080/node/websocket`. |
| `PHOTON_NODE_TOKEN` | node | Must equal the hub's token. The hub writes it to `$PHOTON_DATA_DIR/node-token` on first boot (`Photon.NodeAuth`), unless `PHOTON_NODE_TOKEN` is set on the hub too. |
| `PHOTON_NODE_ID` | node | Optional. Default is the container hostname. Set `box` so sidebar oracles have a stable id. |
| `PHOTON_DATA_DIR` | hub | `/data` in the image. This is the volume you keep across `podman kill`. |
| `PHOTON_NODE_DATA` | node | Where the node log lives. Keep this volume across the hub kill in Spec B. |
| `PHX_SERVER` | hub release | `true`, or the image's entrypoint will not boot the server. |

GUI login on a release is the generated password in `/data/password` (or
`PHOTON_PASSWORD` if you set one). Dev mode (`mix phx.server`) leaves auth
open unless `PHOTON_PASSWORD` is set.

## Compose sketch (not a working app)

Do not commit this as `compose.yaml` and do not treat `podman compose config`
as a green test. The node service cannot start until the hub has created
`node-token`, and a stock Elixir image does not have this repo's deps
compiled. The block records the intended shape.

```yaml
# UNIMPLEMENTED. Sketch only. See the manual steps.
name: photon-verify

services:
  hub:
    image: photon:local
    environment:
      PHOTON_PUBLIC_URL: http://hub:8080
      PHOTON_LOCAL_NODE: "false"
      PHX_SERVER: "true"
    volumes:
      - hub-data:/data
    ports:
      - "8080:8080"
    networks: [photon-net]

  node:
    image: photon-node:local   # does not exist yet; see "Start the node"
    environment:
      PHOTON_SERVER: ws://hub:8080/node/websocket
      PHOTON_NODE_TOKEN: REPLACE_AFTER_HUB_BOOT
      PHOTON_NODE_ID: box
      PHOTON_NODE_DATA: /var/lib/photon-node
    volumes:
      - node-data:/var/lib/photon-node
    networks: [photon-net]
    # depends_on is not enough: the token file appears after the hub's
    # first boot, not when the container has started.

networks:
  photon-net:

volumes:
  hub-data:
  node-data:
```

`docker` works wherever this page says `podman`, with the same flags.

## Shared setup

```sh
podman network create photon-net

podman volume create photon-hub-data
podman volume create photon-node-data

# The repo Dockerfile. The build also produces node binaries; it is slow.
podman build -t photon:local .

podman run -d --name photon-hub --network photon-net \
  -p 8080:8080 \
  -v photon-hub-data:/data \
  -e PHOTON_PUBLIC_URL=http://photon-hub:8080 \
  -e PHOTON_LOCAL_NODE=false \
  -e PHX_SERVER=true \
  photon:local

# Token the node must present. Do not paste this into a recording.
podman exec photon-hub cat /data/node-token
```

From a dev checkout, the same hub is:

```sh
PHOTON_BIND=0.0.0.0 \
PHOTON_PUBLIC_URL=http://127.0.0.1:4000 \
PHOTON_LOCAL_NODE=false \
PHOTON_DATA_DIR=/tmp/photon-hub-data \
PORT=4000 \
mix phx.server
```

Use `ws://127.0.0.1:4000/node/websocket` as `PHOTON_SERVER` in that case, and
read the token from `/tmp/photon-hub-data/node-token`. A node in another
network namespace cannot use `127.0.0.1`.

### Start the node

There is no published node image. Either of these is the node container:

- Source, on an Elixir 1.20+ image with this repo mounted and `mix deps.get`
  already run in `node/`:

  ```sh
  cd node && \
  PHOTON_SERVER=ws://photon-hub:8080/node/websocket \
  PHOTON_NODE_TOKEN="$(podman exec photon-hub cat /data/node-token)" \
  PHOTON_NODE_ID=box \
  PHOTON_NODE_DATA=/var/lib/photon-node \
  mix run --no-halt
  ```

- The installer the hub would show under Add a node, inside a container that
  can reach `http://photon-hub:8080`, with `PHOTON_NODE_TOKEN` set. That is
  the path Spec A is about. The install script also wants a downloaded
  binary from `/node/download/...`, which means the image was built with
  `node/dist` populated (`mix photon.package`). A dev checkout that only ran
  `mix photon.build_runner` does not have those binaries; use `mix run` for
  Spec B and do not pretend the installer ran.

## Scenario `clean-machine-install` (Spec A)

Maps to `install_clean_machine.tla`. One new `PHOTON_NODE_ID`. No session yet.

Happy path (`IssueToken` through `Join`):

1. Hub is up. Token file exists. Sidebar does not show `box`.
2. Run the installer (or `mix run`) with that token and `PHOTON_SERVER`.
3. Oracle, pass: the sidebar's Nodes section shows `box` with a green dot
   (`bg-success` on the row). It does not show a second row for the same id.
   `podman logs` / the node log contains a connected line. The hub log
   contains the join, one live channel.

Failure TLC calls `FailMidInstall` (kill before dial):

1. Start the installer and stop the container after the binary is placed, or
   before `PHOTON_SERVER` is reachable (`podman kill` on the node, or point
   `PHOTON_SERVER` at a closed port).
2. Oracle, pass: the sidebar has no green dot for `box`. A node that never
   joined does not appear as "offline" either, unless a session already
   names that id. The property is "the hub does not believe it is online",
   which is `registered = 0` in the spec and "no registry entry" in
   `Photon.NodeRegistry`.
3. Oracle, fail: a green dot, or a Provision job that reported the node
   connected, while the node process is dead and never completed a join.

`RejectBadToken`: start the node with `PHOTON_NODE_TOKEN=nope`. The socket
refuses the connection (`PhotonWeb.NodeSocket`). Same sidebar oracle.

## Scenario `hub-restart-catchup` (Spec B)

Maps to `hub_restart_catchup.tla`. The node stays up. The hub process dies.
The hub volume stays.

1. Shared setup, node id `box` joined (green dot).
2. Open a session on `box` and start a run that will finish (the mock
   provider and a short prompt are enough). Confirm the node is appending:
   `node-events/<session-id>.jsonl` under `PHOTON_NODE_DATA` grows.
3. While the run is in progress, or immediately after the node has written
   the exit line and before you care whether the hub saw it:

   ```sh
   podman kill photon-hub
   ```

   Do not remove the volume. `photon-hub-data` still has
   `sessions/<id>/events.jsonl` and `node-token`.
4. Leave the node running. Spec action `CommitDone` is legal while the link
   is down. If the run was still going, let it reach the exit event in
   `node-events/<id>.jsonl` (`"type":"exit"`). That line is the durable
   stand-in for `run_finished` (see the spec header).
5. Start the hub again on the same volume and the same network name:

   ```sh
   podman start photon-hub
   ```

   If `podman start` will not reuse the dead container, `podman rm` the
   container only (not the volume) and `podman run` it again with the same
   `-v photon-hub-data:/data` and the same `PHOTON_PUBLIC_URL`.
6. The node dials again (`reconnect_after_msec` in `PhotonNode.Connection`).
   Join reply `sync` is the hub's line count. The node replays.

Oracle, pass, once the green dot for `box` is back:

- Sidebar shows `box` once, with a green dot, not two rows and not a stuck
  "running" count for a run whose exit is already in the node log.
- Hub file `/data/sessions/<id>/events.jsonl` and node file
  `node-events/<id>.jsonl` have the same number of non-empty lines
  (`event_base` is 0 for a session created on this hub).
- The exit object appears once in the hub file. A second copy of the same
  offset is a failed `ExactlyOnce`. A missing exit, while the node file has
  it, is a failed catch-up (`DoneSurvives` / the liveness sketch).
- Offsets are the line index. Line `n` (from zero) on the hub is the same
  JSON as line `n` on the node. A hole or a swap is a failed `HubIsPrefix`.

Oracle, fail: hub high-water past the node log, a green dot that never
returns after the node has logged a successful reconnect, or an events file
that shrank across the restart (the volume was not actually kept).

```sh
# illustrative; session id comes from the sidebar URL /s/<uuid>
podman exec photon-hub wc -l "/data/sessions/${SID}/events.jsonl"
# on the node container, or the host path of photon-node-data:
wc -l "/var/lib/photon-node/node-events/${SID}.jsonl"
```

## What is still unimplemented

- No `podman compose up` target, no Mix alias, no script that fetches the
  token and starts the node.
- No node image. `mix photon.package` binaries are a manual prerequisite
  for the installer path.
- No automatic oracle. The comparisons above are for a person (or a later
  script) to run.
- verify-photon evidence directories are not the artifact of these
  scenarios. If you record a demo, follow [`demos.md`](demos.md) and keep
  the token out of the frame.

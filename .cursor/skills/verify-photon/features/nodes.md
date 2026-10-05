# Nodes

Nodes are the machines that run the agent. A local hub starts a built-in node named `local`. The Nodes page lists it, explains the tailnet, and can mint a one-line install command for some other machine. This map stops before any install or uninstall.

## Sub-features

- `nodes-local` shows the connected built-in node.
- `nodes-tailnet` explains why one-click install is or is not available.
- `nodes-manual` reveals the curl install command for a named machine.
- `nodes-leave` returns to Overview without changing nodes.

## How to get to it (user POV)

- Click **Nodes** in the sidebar, or the **+** next to **Machines** (tooltip **Add a node**). Both open `/nodes`.
- Under **Connected**, a green dot and the name `local` mean the built-in node is connected. The card shows platform, workspace, version, and how many sessions it has.
- Read **Add a node from your tailnet**. If tailscale is missing, the page says so and still offers the command below.
- Under **Any other machine**, type a name and click **Make its command**. The command appears once and includes a key for that node alone.
- Click **Overview** to leave. There is no dialog to close.

## Driving it with verify-photon

Preconditions:

- `verify-photon doctor` prints `node=local` and a data dir under `$PHOTON_VERIFY_ROOT/run/data`.
- Do not click **Install**, **Update**, **Uninstall**, or **Update all**. Those call `phx-click="provision"` or `update_all` and SSH to another machine.
- Do not put a screenshot of `#install-command` in evidence. It includes a node key. Do not write that key into `summary.txt`.

- **Open the page.** If Blip is open, run `.cursor/skills/verify-photon/verify-photon browser click --selector '#blip-close'` first. Then `.cursor/skills/verify-photon/verify-photon browser click --selector '#nav-nodes'`, then `.cursor/skills/verify-photon/verify-photon browser wait-selector --selector '#node-local'`. The card contains `local`. `#sidebar` contains `local` and does not contain `No machines yet`.
- **Workspace.** Run `.cursor/skills/verify-photon/verify-photon browser text --selector '#node-local'`. The text contains the doctor `data_dir` (the workspace is `<data>/local-node/workspace`).
- **Capture the page before any key exists.** Run `.cursor/skills/verify-photon/verify-photon browser screenshot --path "$PHOTON_VERIFY_ROOT/evidence/nodes/page.png"`. The image shows **Nodes**, the `local` card, and the Photon sidebar. It must not contain `PHOTON_NODE_TOKEN=`.
- **Tailnet branch.** Run `.cursor/skills/verify-photon/verify-photon browser text --selector '#add-node'`. On a hub without the `tailscale` binary, the text contains `tailscale isn't installed on the hub machine`. On a hub that is on a tailnet, it lists machine rows instead; leave **Install** alone. A dev server bound to `127.0.0.1` also shows `The hub only listens on this machine` and a `PHOTON_BIND=` hint. With nothing in `apps/node/dist`, the page contains `No node builds are on this hub yet`. None of those warnings mean `local` is down.
- **Manual command, redacted.** Run `.cursor/skills/verify-photon/verify-photon browser fill --selector '#manual-node-id' --value 'vps-1'`, then `.cursor/skills/verify-photon/verify-photon browser click --selector '#make-install-command'`, then `.cursor/skills/verify-photon/verify-photon browser wait-selector --selector '#install-command'`. Read the text and assert it contains `/node/install.sh` and `PHOTON_NODE_TOKEN=`. In `summary.txt` record only that both substrings were present, plus `token_recorded=no`. Do not copy the token value and do not screenshot this state.
- **Leave.** Run `.cursor/skills/verify-photon/verify-photon browser click --selector '#nav-overview'`. The overview heading is back and `#side-node-local` is still listed.
- **Proof.** `page.png` plus `summary.txt` with `feature=nodes`, `entry=nav-nodes`, and `token_recorded=no`. Doctor still prints `node=local`.

## Gotchas

- Close Blip with `#blip-close` before `#nav-nodes`. An outside click closes the panel and does not follow the link.
- The **+** next to **Machines** is a link to `/nodes`, not a dialog. The words **Add a node** are that tooltip and the tailnet section heading. `browser text` prints the heading as `ADD A NODE FROM YOUR TAILNET` because it is Tailwind `uppercase`. `wait-text` ignores case.
- The built-in node id is `local`. Assert `#node-local` and `#side-node-local`, not the hostname.
- Naming the manual node `local` is rejected: `local is the built-in node's name.` Use a different name, such as `vps-1`.
- The install command is filled by a browser hook (`phx-update="ignore"`). It is empty in the HTML until **Make its command** returns. The key is not in the LiveView assigns.
- The command uses the origin of the page you opened (`http://127.0.0.1:4010` when the harness did) plus `/node/install.sh`, and `PHOTON_NODE_ID=` plus `PHOTON_NODE_TOKEN=`. Do not expect the README's port 4000 in that command during verification.
- Making another command for the same name replaces the key. Verification mints one key in the disposable data dir and never reuses it.
- `mix photon.package` is what fills `apps/node/dist`. The embedded `local` node does not need those binaries. `No node builds are on this hub yet` is expected on a dev checkout that only ran `mix setup`.
- **Removed** and **Let it open the hub** appear only after a node was removed. This map does not install or remove a remote node, so that section stays absent.
- Opening the page shells out to `tailscale status` when that binary exists. Verification must not require a tailnet.

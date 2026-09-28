# Nodes

Nodes are the machines that run the agent. A local hub starts a built-in node named `local`. Add a node opens the panel that lists tailnet machines and the manual install command. This map stops before any install or uninstall.

## Sub-features

- `nodes-local` shows the connected built-in node in the sidebar.
- `nodes-panel` opens Add a node from the plus button.
- `nodes-tailnet` explains why one-click install is or is not available.
- `nodes-manual` reveals the curl install command for any other machine.
- `nodes-close` dismisses the panel without changing nodes.

## How to get to it (user POV)

- Look under **Nodes** in the sidebar. A green dot and the name `local` mean the built-in node is connected. Hovering the row shows hostname, platform, version, workspace, and runner.
- Click the **+** button (tooltip **Connect a node**) next to **Nodes**.
- If no node were connected, a banner **No nodes are connected yet** would offer a button labeled **Add a node**. That banner is not the local-hub baseline.
- In the panel, read **Your tailnet**, then open **Any other machine** for the curl command. **Install** on a tailnet row is a real SSH install. Do not click it during verification.

## Driving it with verify-photon

Preconditions:

- `verify-photon doctor` prints `node=local` and a data dir under `$PHOTON_VERIFY_ROOT/run/data`.
- Do not click **Install**, **Update**, or **Uninstall**. Those call `phx-click="provision"` and SSH to another machine.
- Do not put a screenshot of the expanded install command in evidence. It includes the node token from `<data>/node-token`.

- **Sidebar node.** Run `.cursor/skills/verify-photon/verify-photon browser start` and `.cursor/skills/verify-photon/verify-photon browser text --selector 'aside'`. The text contains `Nodes` and `local`, and does not contain `No nodes connected`. The workspace path in the row tooltip contains the doctor `data_dir` (the HTML `title` attribute includes `workspace <data>/workspace`).
- **Open the panel.** Run `.cursor/skills/verify-photon/verify-photon browser click --selector 'button[title="Connect a node"]'`, then `.cursor/skills/verify-photon/verify-photon browser wait-text --text 'Add a node'`. The dialog also contains `Your tailnet`.
- **Capture the panel before the token is visible.** Run `.cursor/skills/verify-photon/verify-photon browser screenshot --path "$PHOTON_VERIFY_ROOT/evidence/nodes/panel.png"` while **Any other machine** is still collapsed. The image shows **Add a node** and the Photon page behind the scrim. It must not contain `PHOTON_NODE_TOKEN=`.
- **Tailnet branch.** Run `.cursor/skills/verify-photon/verify-photon browser text --selector 'div.fixed'`. On a hub without the `tailscale` binary, the text contains `tailscale isn't installed on the hub machine`. On a hub that is on a tailnet, it lists machine rows instead; leave **Install** alone. A dev server bound to `127.0.0.1` also shows `The hub only listens on this machine` and a `PHOTON_BIND=` hint. With no files in `node/dist`, the panel contains `No node binaries are built yet`. None of those warnings mean `local` is down.
- **Manual command, redacted.** Run `.cursor/skills/verify-photon/verify-photon browser click --selector 'summary:has-text("Any other machine")'`, then `.cursor/skills/verify-photon/verify-photon browser text --selector 'div.fixed'`. The text contains `/node/install.sh` and `PHOTON_NODE_TOKEN=`. In `summary.txt` record only that both substrings were present. Do not copy the token value and do not screenshot this state.
- **Close.** Run `.cursor/skills/verify-photon/verify-photon browser click --selector 'div.fixed button[phx-click="toggle_connect"]'`. The heading `Add a node` is gone and the sidebar still shows `local`.
- **Proof.** `panel.png` plus `summary.txt` with `feature=nodes`, `entry=sidebar-plus`, and `token_recorded=no`. Doctor still prints `node=local`.

## Gotchas

- The built-in node id is `local`. Its hostname is the machine's hostname and can differ (`cursor`, `localhost`, a laptop name). Assert the id `local`, not the hostname.
- The **+** control is `button[title="Connect a node"]`. The words **Add a node** are the dialog heading, and also a banner button that exists only when the node list is empty.
- `#node-picker` (label **Run on**) is on the new-session composer, and only when at least one node is connected. It is not inside the Add a node dialog, and it disappears once a session is open.
- Opening the panel shells out to `tailscale status` when that binary exists (`PHOTON_TAILSCALE` overrides the path). Verification must not require a tailnet.
- `mix photon.package` is what fills `node/dist`. The embedded `local` node does not need those binaries. The warning `No node binaries are built yet` is expected on a dev checkout that only ran `mix photon.build_runner`.
- The install one-liner uses the origin of the page you opened (`http://127.0.0.1:4010` when the harness did) plus `/node/install.sh`. Do not expect the README's port 4000 in that command during verification.
- Clicking the dark backdrop also closes the panel (`phx-click` on the full-screen scrim). Use the X button selector so the click is not ambiguous.
- An out-of-date node shows an **update** chip and a banner. The embedded node reports version `0.1.0` without a build stamp, and `node/dist/VERSION` is absent, so `local` is not marked out of date.

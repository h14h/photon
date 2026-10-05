# Sessions

Sessions are the hub's record of work on a node. The sidebar lists the latest few under each machine, Overview lists what is running and what finished, and opening one shows that agent's transcript. Delete removes it from the hub.

## Sub-features

- `sessions-empty` shows no session rows before any node work.
- `sessions-create` adds a row when Blip hands a task to `local`.
- `sessions-open` loads that session from its sidebar link.
- `sessions-overview` shows the same work on Overview.
- `sessions-delete` removes the session after confirmation.

## How to get to it (user POV)

- Look at **Overview**. Before any node work the local machine card says **No work yet**, **Running now** says **Nothing running on your machines.**, and **Recent work** says **Nothing has finished yet.** The sidebar lists `local` and no session under it.
- Ask Blip to run something on `local`. A row titled with that task appears under `local`, and under Recent work once it finishes.
- Click the row. The address becomes `/sessions/<id>` and the heading is the task.
- Click **Overview** to leave the page without deleting the session.
- On the session page, click the trash (tooltip **Delete**) and confirm **Delete this session here and on the node?**

## Driving it with verify-photon

Preconditions:

- `verify-photon doctor` prints `ok`.
- Start from a fresh launch for the empty checks. Create the session this recipe deletes with the shell step in `send-message.md` (`on local: $ echo photon-verify`).

- **Empty list.** After launch, run `.cursor/skills/verify-photon/verify-photon browser start`, then `.cursor/skills/verify-photon/verify-photon browser click --selector '#blip-close'`, then `.cursor/skills/verify-photon/verify-photon browser wait-text --text 'Nothing has finished yet'`. `#side-node-local` is present and `#sidebar a[href^="/sessions/"]` is not. The machine card `#machine-local` contains `No work yet`. Screenshot `$PHOTON_VERIFY_ROOT/evidence/sessions/empty.png` with the Photon sidebar visible.
- **Create by handing off work.** Run the shell step in `send-message.md`. Wait until `#sidebar a[href^="/sessions/"]` exists. Its text is the title `$ echo photon-verify`. In `photon.db`, `node_sessions.title` is that string and `node_id` is `local`.
- **Reopen.** Run `.cursor/skills/verify-photon/verify-photon browser click --selector '#sidebar a[href^="/sessions/"]'`, then `.cursor/skills/verify-photon/verify-photon browser wait-url --includes '/sessions/'`. The heading is `$ echo photon-verify` and `#items` contains `photon-verify`. The URL's id matches the `node_sessions` row.
- **Overview.** Run `.cursor/skills/verify-photon/verify-photon browser click --selector '#nav-overview'`. The URL is the hub root, `#side-session-<id>` is still present, and **Recent work** links to the same `/sessions/<id>`. The `node_sessions` row still exists.
- **Delete.** Open the session again and run `.cursor/skills/verify-photon/verify-photon browser click --confirm --selector '#delete-session'`. The URL returns to `/`, the flash says `Deleted the session.`, the sidebar has no `#side-session-<id>`, and that id is gone from `node_sessions`.
- **Proof.** Screenshot the sidebar after create (`$PHOTON_VERIFY_ROOT/evidence/sessions/created.png`) and after delete (`deleted.png`). Record the id in `summary.txt`. The deleted id must be absent from `node_sessions`.

## Gotchas

- Nothing in the shell creates a stored node session by itself. A row appears when Blip hands work to a node, or when a message is sent on a session page that already exists. There is no **New session** control.
- The sidebar shows the title only. The machine name is the parent row (`local`), not a subtitle on the session. Overview's work row reads `local · by Blip` when Blip started it.
- The trash control is `#delete-session` on the session page, always in the header. It is not a hover-only sibling of the sidebar link.
- Delete uses `window.confirm` with the text `Delete this session here and on the node?`. Omit `--confirm` and the harness dismisses the dialog, leaving the session in place.
- Deleting also tells the node to drop its copy. The proof that matters here is the hub row disappearing and the sidebar updating.
- Session ids are `ns_` plus 26 characters. A selector written for a UUID will not match.
- Closing Blip before the empty screenshot keeps the overview text in view. The panel covers the bottom of the page while it is open.

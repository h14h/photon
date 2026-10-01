# Sessions

Sessions are the hub's history of each conversation. The sidebar lists them, opening one shows its transcript, New session returns to a blank composer, and delete removes that history from the hub.

## Sub-features

- `sessions-empty` shows an empty sidebar before any message.
- `sessions-create` adds a row when a message is sent.
- `sessions-open` loads a saved session from its sidebar link.
- `sessions-new` leaves the saved session and shows a blank composer.
- `sessions-delete` removes the session after confirmation.

## How to get to it (user POV)

- Look at the left sidebar under **New session**. Before any message it says **No sessions yet**.
- Send a message. The row title is that prompt, and the address becomes `/s/<id>`.
- Click the row to reopen it later.
- Click **New session** to start another prompt without deleting the one you were reading.
- Hover a row and click the trash icon (tooltip **Delete session**). Confirm **Delete this session and its history?**

## Driving it with verify-photon

Preconditions:

- `verify-photon doctor` prints `ok`.
- Start from a fresh launch so the sidebar is empty. Create the session this recipe deletes by driving `send-message` first (`help` is enough).

- **Empty list.** After launch, run `.cursor/skills/verify-photon/verify-photon browser start` and `.cursor/skills/verify-photon/verify-photon browser wait-text --text 'No sessions yet'`. The sidebar contains that sentence and no `a[href^="/s/"]` link.
- **Create by sending.** Run the composer steps in `send-message.md` (or `verify-photon drive send-message`). The sidebar link `aside a[href="/s/<id>"]` shows the title `help` on its first line, matching `meta.json` `"title": "help"`. `browser text` on that link also includes the relative-time subtitle (`just now` on a fresh row). With only the `local` node connected, that subtitle does not include `local`.
- **Reopen.** Run `.cursor/skills/verify-photon/verify-photon browser click --selector 'aside a[href="/"]'`, wait until the URL has no `/s/`, then `.cursor/skills/verify-photon/verify-photon browser click --selector 'aside a[href="/s/<id>"]'` with that same id. The heading is `help` and the transcript still contains `I'm the built-in mock model`.
- **New session.** From that open session, run `.cursor/skills/verify-photon/verify-photon browser click --selector 'aside a[href="/"]'`. The URL is the hub root, the heading is `New session`, and `aside a[href="/s/<id>"]` is still present. `<data>/sessions/<id>/meta.json` still exists.
- **Delete.** Hover the row, then click the trash button and accept the confirm:

  ```sh
  .cursor/skills/verify-photon/verify-photon browser hover --selector 'aside a[href="/s/<id>"]'
  .cursor/skills/verify-photon/verify-photon browser click --confirm --selector 'a[href="/s/<id>"] + button[title="Delete session"]'
  ```

  The sidebar says `No sessions yet`, the URL returns to `/` if that session was open, and `<data>/sessions/<id>` is gone.
- **Proof.** Screenshot the sidebar after create (`$PHOTON_VERIFY_ROOT/evidence/sessions/created.png`) and after delete (`deleted.png`). Record the id in `summary.txt`. The deleted id's directory must be absent, and the earlier `meta.json` copy in the evidence directory must still exist.

## Gotchas

- **New session** does not create a stored session. A row appears only when Send accepts a prompt or an image. The button patches to `/`.
- The trash button is `display: none` until the row is hovered (`group-hover`). Clicking it without `browser hover` on that row fails.
- Delete uses `window.confirm` with the text `Delete this session and its history?`. Omit `--confirm` and the harness dismisses the dialog, leaving the session in place.
- The delete control is the next sibling of the session link: `a[href="/s/<id>"] + button[title="Delete session"]`. A bare `button[title="Delete session"]` matches every row and Playwright will refuse the click.
- Deleting also asks the node to drop its copy. The proof that matters here is the hub directory under `<data>/sessions/<id>` disappearing and the sidebar updating.
- More than one connected node makes the row subtitle include the node name. With only `local`, the subtitle is the relative time and does not repeat `local`.

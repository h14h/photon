# Send a message

Sending a message talks to Blip, the assistant floating over every page. With `PHOTON_MOCK_MODEL=1` Blip answers from a fixed script. A phrasing it understands runs a machine tool on the built-in `local` node (`list_machines`, `shell`, or `view_image`) and the reply stays in this conversation. There is no session page.

## Sub-features

- `send-open` opens Blip from the face in the corner.
- `send-composer` types a prompt and clicks Send.
- `send-enter` submits the same form with Enter.
- `send-example` sends an empty-state example immediately. The prompt shows up in the transcript, not in the composer.
- `send-machines` asks `machines` and shows the local machine inside the collapsed action.
- `send-shell` runs `on local: $ echo photon-verify` and shows that output in Blip.
- `send-sleep` runs a shell sleep long enough to catch, then Stop ends the turn.
- `send-image` asks Blip to look at a PNG in the local workspace.
- `send-close` closes the panel.

## How to get to it (user POV)

- Open the hub root. The heading is **Overview**. Blip sits in the bottom-right corner.
- Click Blip (tooltip **Open Blip (Ctrl+J)**). The panel says **Hi. I'm Blip.** until the conversation has a message.
- Type in **Ask Blip anything...** and click the arrow (tooltip **Send**), or press Enter.
- On an empty transcript, click an example such as **Which of my machines are online?**. That click sends the label. It does not type it into the composer first.
- A machine command stays in this panel. The action line names the command and the machine (`Ran echo photon-verify on local`). Open the line to read the output.
- Close the panel with the X (tooltip **Close (Esc)**).

## Driving it with verify-photon

Preconditions:

- `verify-photon doctor` prints `ok` for this run's URL and data dir.
- `#side-node-local` is on the page.
- The example step needs an empty transcript (`#empty-state`). Do it before any other send. `launch` starts from an empty data dir.
- The bundled `help` proof can run after that. It does not need the empty state.
- The image step needs a PNG already in `<data>/local-node/workspace`. Write it from the shell before asking Blip to look at it. Do not send a file through the composer; there is no file input.

- **Open Blip.** Run `.cursor/skills/verify-photon/verify-photon browser start`. The document title is `Overview · Photon`, the sidebar shows **Photon**, and `#composer-input` is visible. On a fresh data dir the panel contains `Hi. I'm Blip.`
- **Example.** On that empty transcript, run `.cursor/skills/verify-photon/verify-photon browser click --selector 'button:has-text("Which of my machines are online?")'`. `#empty-state button` matches every example, and Playwright will refuse it. That click sends the label. `#composer-input` stays empty. The scripted model does not treat that sentence as a command, so the reply contains `I'm Blip, on the scripted model`. Screenshot `$PHOTON_VERIFY_ROOT/evidence/send-message/example.png`.
- **Type the prompt.** Run `.cursor/skills/verify-photon/verify-photon browser fill --selector '#composer-input' --value 'help'`. The composer shows `help`.
- **Capture the action.** Run `.cursor/skills/verify-photon/verify-photon browser screenshot --path "$PHOTON_VERIFY_ROOT/evidence/send-message/action.png"`. The PNG shows the Photon sidebar and the unsent `help` prompt.
- **Send.** Run `.cursor/skills/verify-photon/verify-photon browser click --selector '#send'`. The URL stays on `/`.
- **Wait for the reply.** Run `.cursor/skills/verify-photon/verify-photon browser wait-text --within '#conversation' --text "I'm Blip, on the scripted model"`. The transcript shows the user text `help` and that sentence.
- **Confirm the stored conversation.** Read the `data` column of `entries` in `<data>/photon.db`. It contains `help` and `I'm Blip, on the scripted model`.
- **Bundled proof.** Run `.cursor/skills/verify-photon/verify-photon drive send-message`. It performs the type, Send, and database steps and writes `$PHOTON_VERIFY_ROOT/evidence/send-message/`. Run the example step yourself first when you also need `send-example`.
- **Enter key.** Fill `#composer-input` with `machines` and run `.cursor/skills/verify-photon/verify-photon browser press --selector '#composer-input' --key Enter`. The transcript shows `machines` and `Checked your machines`. The machine line is inside that action's collapsed `<details>`, so open it with `summary:has-text("Checked your machines")`. The visible text then contains `local (this hub's own computer)` and `online`. Shift+Enter must not be used; it inserts a newline.
- **Shell command.** Click `#blip-face` if the composer is hidden. Fill `#composer-input` with `on local: $ echo photon-verify` and click `#send`. The transcript contains `Running that on local.` After the run the action summary contains `Ran echo photon-verify on local` and the conversation contains `photon-verify`. The URL stays on `/`. `.cursor/skills/verify-photon/verify-photon browser count --selector '#sidebar a[href^="/sessions/"]'` prints `0`. `<data>/photon.db` has a `machine_ops` row with `machine` `local`, `kind` `shell`, and `status` `closed`.
- **Short command, then Stop.** Fill `#composer-input` with `on local: $ sleep 8; echo photon-slept` and click `#send`. Run `.cursor/skills/verify-photon/verify-photon browser wait-selector --selector '#stop'`. `#mode-toggle` reads `Send after this answer`. Click `#mode-toggle`; it reads `Steer current work`. Then click `#stop`. `.cursor/skills/verify-photon/verify-photon browser count --selector '#stop'` prints `0`. Do not require `photon-slept` after Stop.
- **Image.** Write a one-pixel PNG named `dot.png` into `<data>/local-node/workspace` (any small PNG, JPEG, GIF, or WebP). Fill `#composer-input` with `on local: look at dot.png` and click `#send`. The transcript contains `Looking at it on local.` and then `Here it is.` `.cursor/skills/verify-photon/verify-photon browser count --selector 'img[src*="/blip/images/"]'` prints at least `1`.
- **Close.** Run `.cursor/skills/verify-photon/verify-photon browser click --selector '#blip-close'`. `#composer-input` is not visible. `#blip-face` still is.

## Gotchas

- Example buttons render only while Blip has nothing to show (`#empty-state`). After the first message they are gone. Fresh context keeps the history on screen, so it does not bring the examples back. The four labels are `Which of my machines are online?`, `How much disk space is free on local?`, `Check on local for anything using a lot of CPU`, and `Every morning at 8, check that my machines are healthy`. All four get the help reply.
- The scripted phrases are exact: `machines` (or `list machines`), `on <machine>: $ <command>`, `on <machine>: look at <path>`, `remember <fact>`, `in <n> minutes: <prompt>`, `every <n> minutes: <prompt>`, and `schedules` (or `list schedules`). Anything else, including the example labels and the word `nodes`, gets the help reply. `help` itself is not one of those phrases; the help reply is the fallback. The help text starts `I'm Blip, on the scripted model`.
- `on local: $ …` is one shell command in the machine's workspace (`<data>/local-node/workspace`). `look at` reads a PNG, JPEG, GIF, or WebP there, by a path relative to that workspace or an absolute path. The hub composer has no photo button and no file input.
- There is no session page and no `node_sessions` table. Blip stays on the page you already had open. Command output is the action's `<pre>` in `#conversation`, and the hub row is `machine_ops`.
- `#composer-input` is in the DOM when the mock model is on, and hidden while the panel is closed (`data-panel="closed"`). `browser fill` needs it visible. A click outside the panel closes it, and that same click does not follow a link under the cursor: the close animation takes the click. Close with `#blip-close`, then click the link. Clicking `#blip-face` while the panel is already open does not close it.
- The sidebar link **Sign in with ChatGPT** (`#sign-in-banner`) stays, because the mock model is not a ChatGPT account. The composer is still there. Doctor fails if launch did not set `PHOTON_MOCK_MODEL=1` and the page shows `#sign-in-to-talk` instead.
- The first real command can take longer than the reply itself. `wait-text` allows 60s. Do not treat a missing reply before that as a product failure without the server log (`$PHOTON_VERIFY_ROOT/run/server.log`).
- Stop (`#stop`) and the steer toggle (`#mode-toggle`) are absent while Blip is idle, and present while a turn is in progress. The `help` proof must not click Stop. A queued follow-up lands in `#queued` only while a turn is still running.
- Web search renders in this panel only when the model is ChatGPT. The scripted model has no search phrasing. Do not claim a search ran because the help text came back.

# Send a message

Sending a message talks to Blip, the assistant floating over every page. With `PHOTON_MOCK_MODEL=1` Blip answers from a fixed script. A phrasing it understands can hand work to the built-in `local` node, which runs that task with the node's own scripted model.

## Sub-features

- `send-open` opens Blip from the face in the corner.
- `send-composer` types a prompt and clicks Send.
- `send-enter` submits the same form with Enter.
- `send-example` sends an empty-state example immediately. The prompt shows up in the transcript, not in the composer.
- `send-nodes` asks `nodes` and shows the local machine.
- `send-shell` hands `$ echo` to `local` and shows the command output.
- `send-sleep` hands `sleep 1` to `local` and shows a tick.
- `send-close` closes the panel.

## How to get to it (user POV)

- Open the hub root. The heading is **Overview**. Blip sits in the bottom-right corner.
- Click Blip (tooltip **Open Blip (Ctrl+J)**). The panel says **Hi. I'm Blip.** until the conversation has a message.
- Type in **Ask Blip anything...** and click the arrow (tooltip **Send**), or press Enter.
- On an empty transcript, click an example such as **Which of my machines are online?**. That click sends the label. It does not type it into the composer first.
- Close the panel with the X (tooltip **Close (Esc)**).

## Driving it with verify-photon

Preconditions:

- `verify-photon doctor` prints `ok` for this run's URL and data dir.
- `#side-node-local` is on the page.
- The example step needs an empty transcript (`#empty-state`). Do it before any other send. `launch` starts from an empty data dir.
- The bundled `help` proof can run after that. It does not need the empty state.

- **Open Blip.** Run `.cursor/skills/verify-photon/verify-photon browser start`. The document title is `Overview · Photon`, the sidebar shows **Photon**, and `#composer-input` is visible. On a fresh data dir the panel contains `Hi. I'm Blip.`
- **Example.** On that empty transcript, run `.cursor/skills/verify-photon/verify-photon browser click --selector '#empty-state button'`. The first example is `Which of my machines are online?`. `#composer-input` stays empty. The scripted model does not treat that sentence as a command, so the reply contains `I'm Blip, on the scripted model`. Screenshot `$PHOTON_VERIFY_ROOT/evidence/send-message/example.png`.
- **Type the prompt.** Run `.cursor/skills/verify-photon/verify-photon browser fill --selector '#composer-input' --value 'help'`. The composer shows `help`.
- **Capture the action.** Run `.cursor/skills/verify-photon/verify-photon browser screenshot --path "$PHOTON_VERIFY_ROOT/evidence/send-message/action.png"`. The PNG shows the Photon sidebar and the unsent `help` prompt.
- **Send.** Run `.cursor/skills/verify-photon/verify-photon browser click --selector '#send'`. The URL stays on `/`.
- **Wait for the reply.** Run `.cursor/skills/verify-photon/verify-photon browser wait-text --within '#conversation' --text "I'm Blip, on the scripted model"`. The transcript shows the user text `help` and that sentence.
- **Confirm the stored conversation.** Read the `data` column of `entries` in `<data>/photon.db`. It contains `help` and `I'm Blip, on the scripted model`.
- **Bundled proof.** Run `.cursor/skills/verify-photon/verify-photon drive send-message`. It performs the type, Send, and database steps and writes `$PHOTON_VERIFY_ROOT/evidence/send-message/`. Run the example step yourself first when you also need `send-example`.
- **Enter key.** Fill `#composer-input` with `nodes` and run `.cursor/skills/verify-photon/verify-photon browser press --selector '#composer-input' --key Enter`. The transcript shows `nodes` and `Checked your machines`, and the machine line contains `local` and `online`. Shift+Enter must not be used; it inserts a newline.
- **Shell command.** Click `#blip-face` if the composer is hidden. Fill `#composer-input` with `on local: $ echo photon-verify` and click `#send`. The transcript contains `Handing that to local.` After the run it contains `photon-verify`. The sidebar gains `#side-session-<id>` and `<data>/photon.db` has a `node_sessions` row with `"node_id": "local"` and that title. Open it with the steps in `sessions.md`.
- **Async sleep.** Fill `#composer-input` with `on local: sleep 1` and click `#send`. The node's script really sleeps about one second. The session page for that row shows `tick` in the command output. Do not click `#stop` or `#stop-session`.
- **Close.** Run `.cursor/skills/verify-photon/verify-photon browser click --selector '#blip-close'`. `#composer-input` is not visible. `#blip-face` still is.

## Gotchas

- Example buttons render only while Blip has nothing to show (`#empty-state`). After the first message they are gone. Fresh context keeps the history on screen, so it does not bring the examples back.
- The scripted phrases are exact: `nodes`, `on <node>: <task>`, `check <session id>`, `remember <fact>`, `in <n> minutes: <prompt>`, `every <n> minutes: <prompt>`, and `schedules`. Anything else, including the example labels, gets the help reply. `help` itself is not one of those phrases; the help reply is the fallback.
- On the node, `$ <command>` runs Bash, `sleep <seconds>` runs a slow command (no number sleeps about three seconds), and `view <path>` opens an image. The hub composer has no photo button and no file input.
- There is no Raw events tab. The conversation is the `entries` table in `photon.db`, not `sessions/<id>/events.jsonl`.
- Session ids look like `ns_` plus 26 characters. They are not UUIDs. Blip stays on `/` while it works; the session page is `/sessions/<id>`.
- `#composer-input` is in the DOM when the mock model is on, and hidden while the panel is closed (`data-panel="closed"`). `browser fill` needs it visible. A click on the page outside the panel closes a floating panel, including clicks on `#nav-overview`, `#nav-nodes`, and `#nav-settings`.
- The sidebar link **Sign in with ChatGPT** stays, because the mock model is not a ChatGPT account. The composer is still there. Doctor fails if launch did not set `PHOTON_MOCK_MODEL=1` and the page shows `#sign-in-to-talk` instead.
- The first real node start can take longer than the reply itself. `wait-text` allows 60s. Do not treat a missing reply before that as a product failure without the server log (`$PHOTON_VERIFY_ROOT/run/server.log`).
- Stop (`#stop`) replaces nothing while Blip is idle, and appears while a turn is in progress. The `help` proof must not click it.
- Web search renders in this panel only when the model is ChatGPT (`hosted_tools` includes `web_search`). The scripted model has no search phrasing. Do not claim a search ran because the help text came back.

# Send a message

Sending a message runs `unreal-agent-runner` on the selected node through the built-in mock model, opens the new session, and streams the transcript back into the same page.

## Sub-features

- `send-composer` types a prompt and clicks Send.
- `send-enter` submits the same form with Enter.
- `send-example` fills the prompt from an empty-state example button.
- `send-shell` runs a `$` command and shows the Bash tool card.
- `send-sleep` starts `sleep 5` and shows the run as still going, then finished.
- `send-raw` opens Raw events for the same session.
- `send-image` attaches a PNG and shows it on the user message.

## How to get to it (user POV)

- Open the hub root. The heading is **New session** and the empty state says **Try the Unreal Agent harness**.
- Type in the composer (`Message the agent`) and click the arrow button (tooltip **Send**), or press Enter.
- On an empty transcript, click an example: **What can the mock do?**, **Run a command**, **Watch an async tool**, or **Look around**.
- After a reply, click **Raw events** in the top bar.
- Attach an image with the photo button, paste, or drop it on the composer.

## Driving it with verify-photon

Preconditions:

- `verify-photon doctor` prints `ok` for this run's URL and data dir.
- `#composer` is enabled and the sidebar shows `local`.
- Provider is **Mock model (built in, no API key)**.
- The bundled proof below expects no earlier session titled `help` in this data dir. `launch` starts from an empty data dir.

- **Open the playground.** Run `.cursor/skills/verify-photon/verify-photon browser start`. The document title is `New session · Photon`, `#composer` is enabled, and the page contains `Try the Unreal Agent harness`.
- **Type the prompt.** Run `.cursor/skills/verify-photon/verify-photon browser fill --selector '#composer' --value 'help'`. The composer shows `help`.
- **Capture the action.** Run `.cursor/skills/verify-photon/verify-photon browser screenshot --path "$PHOTON_VERIFY_ROOT/evidence/send-message/action.png"`. The PNG shows the Photon sidebar and the unsent `help` prompt.
- **Send.** Run `.cursor/skills/verify-photon/verify-photon browser click --selector '#composer-form button[title="Send"]'`. The URL contains `/s/` and the heading becomes `help`.
- **Wait for the reply.** Run `.cursor/skills/verify-photon/verify-photon browser wait-url --includes '/s/'`, then `.cursor/skills/verify-photon/verify-photon browser wait-text --within '#transcript' --text "I'm the built-in mock model"`, then `.cursor/skills/verify-photon/verify-photon browser wait-text --within '#transcript' --text 'run finished'`. The transcript shows the user text `help`, the mock help, and the run line (rendered in uppercase as `RUN FINISHED`).
- **Confirm the stored session.** Copy `<data>/sessions/<id>/meta.json` and `events.jsonl` from the doctor data dir, using the uuid in the URL. `title` is `help`, `node` is `local`, and `events.jsonl` contains `"Payload":"help"` and `"Kind":"model_response"`.
- **Bundled proof.** Run `.cursor/skills/verify-photon/verify-photon drive send-message`. It performs the steps above and writes `$PHOTON_VERIFY_ROOT/evidence/send-message/`.
- **Enter key.** On a fresh launch, fill `#composer` with `help` and run `.cursor/skills/verify-photon/verify-photon browser press --selector '#composer' --key Enter`. The same session URL and mock reply appear. Shift+Enter must not be used; it inserts a newline.
- **Example button.** On an empty transcript, run `.cursor/skills/verify-photon/verify-photon browser click --selector 'button:has-text("What can the mock do?")'`. That button is `phx-click="example"` with prompt `help`. The result matches the composer path.
- **Shell command.** On an empty transcript, run `.cursor/skills/verify-photon/verify-photon browser click --selector 'button:has-text("Run a command")'`. The user text is `$ uname -a && date`. After `run finished`, `#transcript` shows a Bash tool card whose command text contains `uname -a`. `events.jsonl` contains `"Kind":"model_response"` more than once (the tool call, then the report).
- **Async sleep.** On an empty transcript, run `.cursor/skills/verify-photon/verify-photon browser click --selector 'button:has-text("Watch an async tool")'`. The prompt is `sleep 5`. While it runs, the top bar says `Running` and the transcript says `Agent is working`. Do not click Stop. After about five seconds the transcript contains `tick` and `run finished`.
- **Raw events.** After any finished run, run `.cursor/skills/verify-photon/verify-photon browser click --selector 'button[phx-click="tab"][phx-value-tab="raw"]'`. The panel says `Newest first` and shows `model_response`. Return with `button[phx-click="tab"][phx-value-tab="chat"]`.
- **Image.** Write a 1×1 PNG into the run dir (cleanup deletes it):

  ```sh
  base64 -d > "$PHOTON_VERIFY_ROOT/run/pixel.png" <<'B64'
  iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
  B64
  ```

  Run `.cursor/skills/verify-photon/verify-photon browser upload --selector '#composer-form input[type="file"]' --path "$PHOTON_VERIFY_ROOT/run/pixel.png"`, wait until `#composer-form img` is visible, then click Send with an empty composer. The heading becomes `Image`. After `run finished`, `#transcript img[src^="/sessions/"]` is present and the assistant text contains `Taking a look at the image you attached`. The same bytes exist under `<data>/sessions/<id>/attachments/`.

## Gotchas

- Example buttons render only while the transcript has no entries. After the first message they are gone; use the composer.
- `help`, `?`, and `/help` are the only mock prompts that skip tools. Any other text runs `pwd && ls -la`. A leading `$` runs that shell command. `sleep 5` really sleeps for about five seconds.
- The session title is the first line of the prompt, trimmed, cut at 60 characters with a unicode ellipsis `…` when longer.
- DOM text for a successful exit is `run finished`. CSS uppercases it. `wait-text` is case-insensitive; a screenshot shows `RUN FINISHED`.
- An empty composer click does nothing unless an image is attached.
- `#composer` is disabled when `local` is offline or the runner binary is missing. Doctor fails closed on that page; do not send anyway.
- The first real runner start can take longer than the mock reply itself. `wait-text` allows 60s. Do not treat a missing reply before that as a product failure without the server log (`$PHOTON_VERIFY_ROOT/run/server.log`).
- Stop (`button[title="Stop (sends SIGINT to the runner)"]`) replaces Send while a run is in progress. The `help` proof must not click it.
- Image upload accepts `.png`, `.jpg`, `.jpeg`, and `.webp` only, up to 4 files and 10 MB. The file input is the `sr-only` input inside `#composer-form`, not the photo icon.

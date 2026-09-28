---
name: verify-photon
description: "Drive the Photon hub's Phoenix LiveView (playground, sessions, settings, nodes) in a headless browser against an isolated PHOTON_DATA_DIR. Use to prove hub UI behavior, after LiveView changes, or when maintaining this verification skill."
---

# Verify Photon

Photon is a Phoenix LiveView hub for unreal-agent. This skill starts that hub the way the README does, drives it in Chrome, and keeps proof after the process is gone. The primary surface is the single LiveView at `/` and `/s/:id` (`PhotonWeb.PlaygroundLive`): composer, session list, settings, and the nodes panel. Remote node install, the `node/` CLI, and Fly deploy are not this harness.

The repo has LiveView tests in `test/photon_web/live/playground_live_test.exs`. They name the stable DOM ids this skill uses, and they run inside `mix test` with a fake node. They do not drive `mix phx.server`. There is no Playwright or Cypress suite. This harness is headless Chrome (Playwright's driver, system Google Chrome) against the real dev server and the built-in `local` node.

Run every command from anywhere. Paths below are relative to the repo root.

## Launch

One-time, from the repo root, with Elixir on `PATH` (`mix.exs` requires `~> 1.17`; the README asks for 1.20+) and Go 1.27+:

```sh
mix setup
mix photon.build_runner
```

`mix photon.build_runner` clones unreal-agent and writes `node/priv/bin/unreal-agent-runner`. The dev server copies that into `_build` on compile. Without it the composer stays disabled and the page says the node has no `unreal-agent-runner`.

Each verification run:

```sh
.cursor/skills/verify-photon/verify-photon launch
```

That command:

- Installs `playwright-core` into `.cursor/skills/verify-photon/node_modules` on first use (`npm install`). Needs Node.js and network once.
- Binds `127.0.0.1` and `PORT` (default **4010**, not the app's 4000). Override with `PHOTON_VERIFY_PORT`.
- Sets `PHOTON_DATA_DIR` to `$PHOTON_VERIFY_ROOT/run/data` (default `/tmp/verify-photon/run/data`). This replaces any `PHOTON_DATA_DIR` already in the environment. It does not read or write the repo `.photon/` directory.
- Unsets `PHOTON_PASSWORD`, `PHOTON_BIND`, `PHOTON_PUBLIC_URL`, and `PHOTON_TRUST_TAILNET` for the server process only. Dev auth stays open. Do not export `PHOTON_PASSWORD` into this server.
- Starts `mix phx.server` with `nohup` and records its pid in `$PHOTON_VERIFY_ROOT/run/pid`. Log: `$PHOTON_VERIFY_ROOT/run/server.log`.
- Refuses to start if that port is already taken. It does not kill a hub it did not start.
- Returns when doctor passes (below), or kills the process it started and exits non-zero. First boot can spend the wait compiling; the limit is 90s.

Ready means doctor prints `ok`, not merely that a port is open. A second `launch` while that same pid is healthy prints the doctor block and does not start another server.

`PHOTON_VERIFY_ROOT` must be an absolute path. Default `/tmp/verify-photon`.

## Doctor

```sh
.cursor/skills/verify-photon/verify-photon doctor
```

Read-only. Run it before every drive and again if the page looks wrong. Exit 0 prints:

```text
ok
url=http://127.0.0.1:4010
pid=<server pid>
listen_pid=<pid bound to 127.0.0.1:4010>
data_dir=/tmp/verify-photon/run/data
auth=open
node=local
provider=mock
```

It fails unless all of these are true:

- `run/pid` is alive and is the process (or its parent) listening on `127.0.0.1:$PORT`. Another machine's bind is rejected.
- `GET /healthz` body is `ok`. This route is unauthenticated and is not proof of the GUI.
- `GET /` is HTTP 200, not 401 `Photon needs its password`.
- The HTML title contains `Photon`, the empty state says `Try the Unreal Agent harness`, `textarea#composer` exists and is not `disabled`, the sidebar lists `local`, and `select[name="settings[provider]"]` has `mock` selected.
- The HTML does not contain `No nodes are connected yet.`, `is offline.`, or `has no` (the missing-runner banner).
- The HTML contains the run's `PHOTON_DATA_DIR` (the local node's workspace is `<data>/workspace`). A page that does not mention that directory is a different instance.

Do not drive a hub this run did not start.

## Drive

The browser daemon keeps one Chrome window (1440×900, headless, `--no-sandbox`) pointed at the hub:

```sh
.cursor/skills/verify-photon/verify-photon browser start
.cursor/skills/verify-photon/verify-photon browser <command> [flags]
.cursor/skills/verify-photon/verify-photon browser stop
```

`browser start` is idempotent while its pid is alive. It opens the hub and waits until `textarea#composer` is enabled and the LiveView has class `phx-connected` (the socket is up). Commands talk to `$PHOTON_VERIFY_ROOT/run/browser.sock`. `browser.mjs` is the daemon; call it only through `verify-photon`.

| Command | Flags | Result |
| --- | --- | --- |
| `goto` | `--url` `/` or an absolute URL | Opens that URL |
| `fill` | `--selector` `--value` | Replaces the field value |
| `click` | `--selector` `--confirm` (optional) | Clicks. `--confirm` accepts a `window.confirm`; without it the dialog is dismissed |
| `press` | `--selector` `--key` | Presses a key (`Enter` in `#composer` submits) |
| `hover` | `--selector` | Hovers |
| `select` | `--selector` `--value` | Selects an `<option>` |
| `check` / `uncheck` | `--selector` | Toggles a checkbox |
| `upload` | `--selector` `--path` | Sets a file input |
| `wait-selector` | `--selector` `--timeout` ms | Waits until the selector matches |
| `wait-text` | `--text` `--within` (optional) `--timeout` ms | Visible text, substring, case-insensitive. Default timeout 60s |
| `wait-url` | `--includes` | URL contains the substring |
| `text` | `--selector` | Prints `innerText` |
| `title` / `url` | | Prints the document title or URL |
| `screenshot` | `--path` | Viewport PNG |

`drive send-message` runs the composer path in `features/send-message.md` and writes evidence. Other features are driven with the commands in their feature files. Read `features/README.md` first.

Stable handles, from `playground_live.ex` and the LiveView tests:

| UI | Selector |
| --- | --- |
| Composer | `#composer` |
| Composer form | `#composer-form` |
| Send | `#composer-form button[title="Send"]` |
| Stop | `button[title="Stop (sends SIGINT to the runner)"]` |
| Transcript | `#transcript` |
| Page heading | `h1` |
| New session | `aside a[href="/"]` |
| A session | `aside a[href="/s/<uuid>"]` |
| Delete session | `a[href="/s/<uuid>"] + button[title="Delete session"]` |
| Settings toggle | `button[title="Settings"]` |
| Settings form | `#settings-form` |
| Provider | `select[name="settings[provider]"]` |
| Model | `input[name="settings[model]"]` |
| API key | `input[name="settings[api_key]"]` |
| Base URL | `input[name="settings[base_url]"]` |
| Thinking level | `input[name="settings[thinking_level]"][value="high"]` (also `low`, `medium`, `xhigh`, `max`) |
| Tool checkbox | `input[name="settings[enabled_tools][]"][value="Bash"]` and `ViewImage` |
| Workspace | `input[name="settings[workspace]"]` |
| System prompt | `textarea[name="settings[system_prompt]"]` |
| Max attempts | `input[name="settings[max_attempts]"]` |
| Reset settings | `button[phx-click="reset_settings"]` |
| Node picker (new session only) | `#node-picker select[name="node"]` |
| Add a node | `button[title="Connect a node"]` |
| Close the node panel | `div.fixed button[phx-click="toggle_connect"]` |
| Conversation tab | `button[phx-click="tab"][phx-value-tab="chat"]` |
| Raw events tab | `button[phx-click="tab"][phx-value-tab="raw"]` |
| Mock examples (empty transcript only) | `button:has-text("What can the mock do?")`, `button:has-text("Run a command")`, `button:has-text("Watch an async tool")`, `button:has-text("Look around")` |
| Image file input | `#composer-form input[type="file"]` |

Bundled proof:

```sh
.cursor/skills/verify-photon/verify-photon doctor
.cursor/skills/verify-photon/verify-photon drive send-message
```

`drive send-message` runs doctor again, types `help`, clicks Send, waits for the mock reply and `run finished`, and copies the session files into the evidence directory.

## Evidence

Proof goes to `$PHOTON_VERIFY_ROOT/evidence/<feature>/` (default `/tmp/verify-photon/evidence/send-message/`). Cleanup never deletes that tree.

`drive send-message` writes:

- `action.png` — composer filled with `help`, before Send
- `result.png` — transcript after the run, with the Photon sidebar still visible
- `transcript.txt`, `heading.txt`, `url.txt`, `title.txt`
- `meta.json` and `events.jsonl` — copies of `<data>/sessions/<id>/meta.json` and `events.jsonl`
- `doctor.txt`, `summary.txt`

A passing send-message proof has all of:

- `heading.txt` is `help` and `url.txt` matches `/s/<uuid>`
- `transcript.txt` contains the prompt `help`, the sentence `I'm the built-in mock model`, and `run finished` (the UI uppercases that line to `RUN FINISHED`)
- `meta.json` has `"title": "help"` and `"node": "local"`
- `events.jsonl` contains `"Payload":"help"` and `"Kind":"model_response"` plus the same mock sentence

That is the user path (type and Send), the resulting transcript, and the files the hub wrote. The mock provider is the product's built-in stand-in; `help` does not call a shell and does not use the network. Do not prove messaging by writing session files yourself.

Screenshots of **Add a node** after expanding **Any other machine** include the node token. Do not put that image in evidence. Assert that the command contains `/node/install.sh` and `PHOTON_NODE_TOKEN=` without recording the token.

## Cleanup

```sh
.cursor/skills/verify-photon/verify-photon cleanup
```

Sends `SIGTERM` (then `SIGKILL` if needed) to the browser pid and the server pid recorded under `$PHOTON_VERIFY_ROOT/run`, then deletes that `run` directory, including the disposable data dir. It does not delete `$PHOTON_VERIFY_ROOT/evidence`, the repo `.photon/` directory, or any process it did not start. It does not kill `epmd` or every `beam.smp`.

After a failed drive, run cleanup before starting again so the port and Chrome daemon are not left behind. Then confirm evidence is still there:

```sh
test -f /tmp/verify-photon/evidence/send-message/result.png \
  && test -f /tmp/verify-photon/evidence/send-message/meta.json \
  && test ! -d /tmp/verify-photon/run
```

## Helpers

`.cursor/skills/verify-photon/verify-photon` is the only entry point. It is executable. `browser.mjs` and `package.json` exist so that script can start Chrome; do not invent a second CLI.

```sh
.cursor/skills/verify-photon/verify-photon launch
.cursor/skills/verify-photon/verify-photon doctor
.cursor/skills/verify-photon/verify-photon drive send-message
.cursor/skills/verify-photon/verify-photon browser start
.cursor/skills/verify-photon/verify-photon browser click --selector 'button[title="Settings"]'
.cursor/skills/verify-photon/verify-photon browser stop
.cursor/skills/verify-photon/verify-photon cleanup
```

## Maintenance

When the hub's UI changes, run `/maintain-verification-skill` against `.cursor/skills/verify-photon/` so the feature map stays aligned with the LiveView.

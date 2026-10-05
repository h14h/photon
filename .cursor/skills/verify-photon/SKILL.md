---
name: verify-photon
description: "Drive the Photon hub's Phoenix LiveView (overview, Blip, sessions, settings, nodes) in a headless browser against an isolated PHOTON_DATA_DIR. Use to prove hub UI behavior, after LiveView changes, or when maintaining this verification skill."
---

# Verify Photon

Photon is a Phoenix LiveView hub. This skill starts that hub the way the README does, drives it in Chrome, and keeps proof after the process is gone. The GUI is the shell in `PhotonWeb.Layouts` plus four pages and Blip:

- `/` is `PhotonWeb.OverviewLive` (machines, running work, recent work, schedules).
- `/sessions/:id` is `PhotonWeb.SessionLive` (one node session).
- `/nodes` is `PhotonWeb.NodesLive`.
- `/settings` is `PhotonWeb.SettingsLive`.
- `PhotonWeb.BlipLive` floats over every page. That is where you send a message.

Remote node install, the `apps/node` CLI, and Fly deploy are not this harness. It drives one hub and the built-in `local` node.

The repo has LiveView tests under `apps/hub/test/web/live/`. They name the stable DOM ids this skill uses, and they run inside `mix test`. They do not drive `mix phx.server`. There is no Playwright or Cypress suite. This harness is headless Chrome (Playwright's driver, system Google Chrome) against the real dev server and the built-in `local` node.

Run every command from anywhere. Paths below are relative to the repo root.

## Launch

One-time, from `apps/hub`, with Elixir on `PATH` (`apps/hub/mix.exs` requires `~> 1.17`; the README asks for 1.20+):

```sh
cd apps/hub && mix setup
```

There is no `mix photon.build_runner`. The hub starts a built-in node named `local` inside the same VM (`config :photon, local_node: true` in development). `mix photon.package` (from `apps/node`) only fills binaries for remote installs. This harness does not need those binaries.

Each verification run:

```sh
.cursor/skills/verify-photon/verify-photon launch
```

That command:

- Installs `playwright-core` into `.cursor/skills/verify-photon/node_modules` on first use (`npm install`). Needs Node.js and network once.
- Binds `127.0.0.1` and `PORT` (default **4010**, not the app's 4000). Override with `PHOTON_VERIFY_PORT`.
- Runs `mix phx.server` in `apps/hub` (the repo root has no Mix project).
- Sets `PHOTON_DATA_DIR` to `$PHOTON_VERIFY_ROOT/run/data` (default `/tmp/verify-photon/run/data`) and `PHOTON_MOCK_MODEL=1`. This replaces any `PHOTON_DATA_DIR` already in the environment. It does not read or write `apps/hub/.photon/`. The scripted model is what lets Blip answer without a ChatGPT sign-in. Without it the composer is replaced by **Sign in with ChatGPT**.
- Unsets `PHOTON_PASSWORD`, `PHOTON_AUTH`, `PHOTON_BIND`, `PHOTON_PUBLIC_URL`, and `PHOTON_TRUST_TAILNET` for the server process only. Dev auth stays open (`Photon.Auth` mode `:off`). Do not export `PHOTON_PASSWORD` into this server.
- Starts `mix phx.server` with `nohup` and records its pid in `$PHOTON_VERIFY_ROOT/run/pid`. Log: `$PHOTON_VERIFY_ROOT/run/server.log`.
- Refuses to start if that port is already taken. It does not kill a hub it did not start.
- Returns when doctor passes (below), or kills the process it started and exits non-zero. First boot can spend the wait compiling and waiting for `local` to connect; the limit is 90s.

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

`provider=mock` means the server process was started with `PHOTON_MOCK_MODEL=1`. The sidebar still names the default model **GPT-6.1 Sol**. That label is not a ChatGPT sign-in.

It fails unless all of these are true:

- `run/pid` is alive and is the process (or its parent) listening on `127.0.0.1:$PORT`. Another machine's bind is rejected.
- `GET /healthz` body is `ok`. This route is unauthenticated and is not proof of the GUI.
- `GET /` and `GET /nodes` are HTTP 200, not 401 `Photon needs its password`.
- The HTML title contains `Overview · Photon`, `#blip-face` exists, and `#composer-input` exists. `#sign-in-to-talk` instead of the composer means the mock model is off.
- The overview HTML lists `#side-node-local` or `#machine-local`, and does not contain `No nodes are connected`.
- The nodes HTML lists `#node-local` and contains the run's `PHOTON_DATA_DIR` (the local node's workspace is `<data>/local-node/workspace`). A page that does not mention that directory is a different instance.

Do not drive a hub this run did not start.

## Drive

The browser daemon keeps one Chrome window (1440×900, headless, `--no-sandbox`) pointed at the hub:

```sh
.cursor/skills/verify-photon/verify-photon browser start
.cursor/skills/verify-photon/verify-photon browser <command> [flags]
.cursor/skills/verify-photon/verify-photon browser stop
```

`browser start` is idempotent while its pid is alive. It opens the hub, waits until the LiveView has class `phx-connected`, clicks `#blip-face`, and waits until `#composer-input` is visible. Commands talk to `$PHOTON_VERIFY_ROOT/run/browser.sock`. `browser.mjs` is the daemon; call it only through `verify-photon`.

| Command | Flags | Result |
| --- | --- | --- |
| `goto` | `--url` `/` or an absolute URL | Opens that URL |
| `fill` | `--selector` `--value` | Replaces the field value |
| `click` | `--selector` `--confirm` (optional) | Clicks. `--confirm` accepts a `window.confirm`; without it the dialog is dismissed |
| `press` | `--selector` `--key` | Presses a key (`Enter` in `#composer-input` submits) |
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

Stable handles, from the LiveViews and their tests:

| UI | Selector |
| --- | --- |
| Open Blip | `#blip-face` |
| Blip panel | `#blip-panel` |
| Close Blip | `#blip-close` |
| Blip conversation | `#conversation` |
| Empty Blip state | `#empty-state` |
| Composer form | `#composer` |
| Composer | `#composer-input` |
| Send | `#send` |
| Stop Blip | `#stop` |
| Steer / wait toggle | `#mode-toggle` |
| Example (empty transcript only) | `#empty-state button` |
| Overview | `#nav-overview` |
| Nodes | `#nav-nodes` |
| Settings | `#nav-settings` |
| Sidebar | `#sidebar` |
| Built-in node | `#side-node-local` |
| A session row | `#side-session-<id>` |
| Overview machine | `#machine-local` |
| Session page input | `#session-input` |
| Session send | `#session-composer button[type="submit"]` |
| Stop session | `#stop-session` |
| Delete session | `#delete-session` |
| Settings form | `#settings-form` |
| Save settings | `#save-settings` |
| Your name | `input[name="settings[user_name]"]` |
| Time zone | `input[name="settings[timezone]"]` |
| Standing instructions | `textarea[name="settings[instructions]"]` |
| Sign in button | `#begin-sign-in` |
| Edit memory | `#edit-memory` |
| Memory text | `#memory-text` |
| Fresh context | `#fresh-start` |
| Node card | `#node-local` |
| Manual node name | `#manual-node-id` |
| Make install command | `#make-install-command` |
| Install command | `#install-command` |

Bundled proof:

```sh
.cursor/skills/verify-photon/verify-photon doctor
.cursor/skills/verify-photon/verify-photon drive send-message
```

`drive send-message` runs doctor again, opens Blip, types `help`, clicks Send, waits for the scripted reply, and copies the conversation rows out of `<data>/photon.db`.

## Evidence

Proof goes to `$PHOTON_VERIFY_ROOT/evidence/<feature>/` (default `/tmp/verify-photon/evidence/send-message/`). Cleanup never deletes that tree.

`drive send-message` writes:

- `action.png` — composer filled with `help`, before Send
- `result.png` — Blip's reply, with the Photon sidebar still visible
- `transcript.txt`, `url.txt`, `title.txt`
- `entries.jsonl` — the `data` column of every row in `photon.db`'s `entries` table
- `doctor.txt`, `summary.txt`

A passing send-message proof has all of:

- `title.txt` contains `Photon` and `url.txt` is the hub root (Blip does not navigate away)
- `transcript.txt` contains the prompt `help` and the sentence `I'm Blip, on the scripted model`
- `entries.jsonl` contains both of those strings

That is the user path (open Blip, type, and Send) and the rows the hub committed. The scripted model is the product's built-in stand-in; `help` does not call a shell and does not use the network. Do not prove messaging by inserting rows yourself.

Screenshots of **Any other machine** after **Make its command** include that node's key. Do not put that image in evidence. Assert that the command contains `/node/install.sh` and `PHOTON_NODE_TOKEN=` without recording the token.

## Cleanup

```sh
.cursor/skills/verify-photon/verify-photon cleanup
```

Sends `SIGTERM` (then `SIGKILL` if needed) to the browser pid and the server pid recorded under `$PHOTON_VERIFY_ROOT/run`, then deletes that `run` directory, including the disposable data dir. It does not delete `$PHOTON_VERIFY_ROOT/evidence`, `apps/hub/.photon/`, or any process it did not start. It does not kill `epmd` or every `beam.smp`.

After a failed drive, run cleanup before starting again so the port and Chrome daemon are not left behind. Then confirm evidence is still there:

```sh
test -f /tmp/verify-photon/evidence/send-message/result.png \
  && test -f /tmp/verify-photon/evidence/send-message/entries.jsonl \
  && test ! -d /tmp/verify-photon/run
```

## Helpers

`.cursor/skills/verify-photon/verify-photon` is the only entry point. It is executable. `browser.mjs` and `package.json` exist so that script can start Chrome; do not invent a second CLI.

```sh
.cursor/skills/verify-photon/verify-photon launch
.cursor/skills/verify-photon/verify-photon doctor
.cursor/skills/verify-photon/verify-photon drive send-message
.cursor/skills/verify-photon/verify-photon browser start
.cursor/skills/verify-photon/verify-photon browser click --selector '#nav-settings'
.cursor/skills/verify-photon/verify-photon browser stop
.cursor/skills/verify-photon/verify-photon cleanup
```

## Maintenance

When the hub's UI changes, run `/maintain-verification-skill` against `.cursor/skills/verify-photon/` so the feature map stays aligned with the LiveView.

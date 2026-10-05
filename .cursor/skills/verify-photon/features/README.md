# Photon verification map

This directory is the maintained source for verifying the Photon hub's user-facing behavior. Read this index, then use the matching feature file.

The hub GUI is the shell plus four pages and Blip, which floats over all of them:

- [Send a message](./send-message.md) covers Blip: opening the panel, the composer, example prompts, and handing work to the built-in `local` node.
- [Sessions](./sessions.md) covers an empty overview, a session row, opening `/sessions/:id`, and delete.
- [Settings](./settings.md) covers the settings page, saving Blip's name and instructions, memory, and fresh context.
- [Nodes](./nodes.md) covers the built-in `local` node and the manual install command, without installing a remote node.

Remote install over SSH, the `apps/node` service, and Fly deploy are outside this map. Web search is a ChatGPT-only path and is not driven here.

## Baseline preconditions

- Run `.cursor/skills/verify-photon/verify-photon launch`. It serves `http://127.0.0.1:4010` unless `PHOTON_VERIFY_PORT` is set.
- Data lives in `$PHOTON_VERIFY_ROOT/run/data` (default `/tmp/verify-photon/run/data`), in `photon.db` and `settings.json`. That is not `apps/hub/.photon/`. Launch overrides `PHOTON_DATA_DIR`, sets `PHOTON_MOCK_MODEL=1`, and unsets `PHOTON_PASSWORD` and `PHOTON_AUTH`.
- `verify-photon doctor` must print `ok`, the same URL, that data directory, `auth=open`, `node=local`, and `provider=mock`.
- `cd apps/hub && mix setup` has already succeeded, so the dev server can boot. The built-in `local` node does not need `mix photon.package`.
- Never drive a hub this verification run did not start.
- One launch covers the whole pass. Later recipes continue on that hub. A recipe that needs an empty Blip transcript says so.

## Driving conventions

- Prefer the ids and `name` selectors in `../SKILL.md`. Do not click by coordinates.
- Run browser actions through `verify-photon browser`. Quoted flags are literal.
- `browser start` opens Blip once. A click outside the floating panel closes it (the nav links count). Click `#blip-face` again before using `#composer-input`.
- `verify-photon drive send-message` is the bundled Blip proof. It runs the `help` steps in `send-message.md`. It does not cover the other features.
- Restore nothing under `apps/hub/.photon/`. The disposable data dir is removed by cleanup. Do not remove `$PHOTON_VERIFY_ROOT/evidence`.

## Proof and skip reporting

- Capture the user action and the resulting state, not only the final screen.
- UI proof is a viewport screenshot plus the transcript or panel text. The Photon name in the sidebar must be visible in screenshots of the shell.
- Mutation proof for a message is the `entries` rows in `<data>/photon.db`. Settings proof is `<data>/settings.json`. Session proof is the `node_sessions` row and the session page.
- Record the feature id and the entry point in `summary.txt`.
- An entry point that cannot be reached is not verified by a different one. Record the command that failed and the missing precondition.
- Do not screenshot the install command after **Make its command**. It contains that node's key.

## Feature entry contract

Each feature file starts with an H1 and one paragraph, then exactly these H2 sections, in order:

1. `Sub-features`
2. `How to get to it (user POV)`
3. `Driving it with verify-photon`
4. `Gotchas`

## Features

- [Send a message](./send-message.md) covers opening Blip, Send, Enter, an example prompt, `nodes`, a shell task on `local`, and a short sleep.
- [Sessions](./sessions.md) covers the empty overview, the sidebar row, opening a session, and delete.
- [Settings](./settings.md) covers the settings page, save, memory, and fresh context.
- [Nodes](./nodes.md) covers the built-in `local` node, the tailnet note, and the manual install command, without installing a remote node.

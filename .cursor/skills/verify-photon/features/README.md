# Photon verification map

This directory is the maintained source for verifying the Photon hub's user-facing behavior. Read this index, then use the matching feature file.

The hub is one Phoenix LiveView: playground at `/`, a session at `/s/:id`, the settings aside, and the nodes panel. Remote install over SSH, the `node/` service, and Fly deploy are outside this map.

## Baseline preconditions

- Run `.cursor/skills/verify-photon/verify-photon launch`. It serves `http://127.0.0.1:4010` unless `PHOTON_VERIFY_PORT` is set.
- Data lives in `$PHOTON_VERIFY_ROOT/run/data` (default `/tmp/verify-photon/run/data`). That is not the repo `.photon/` directory. Launch overrides `PHOTON_DATA_DIR` and unsets `PHOTON_PASSWORD`.
- `verify-photon doctor` must print `ok`, the same URL, that data directory, `auth=open`, `node=local`, and `provider=mock`.
- `mix setup` and `mix photon.build_runner` have already succeeded, so `#composer` is enabled.
- Never drive a hub this verification run did not start.

## Driving conventions

- Start every recipe from a fresh launch unless its preconditions say otherwise.
- Prefer the ids and `title` / `name` selectors in `../SKILL.md`. Do not click by coordinates.
- Run browser actions through `verify-photon browser`. Quoted flags are literal.
- `verify-photon drive send-message` is the bundled composer proof. It runs the commands in `send-message.md`; it does not cover the other features.
- Restore nothing in the repo `.photon/` tree. The disposable data dir is removed by cleanup. Do not remove `$PHOTON_VERIFY_ROOT/evidence`.

## Proof and skip reporting

- Capture the user action and the resulting state, not only the final screen.
- UI proof is a viewport screenshot plus the transcript or panel text. The Photon name in the sidebar must be visible in screenshots of the playground.
- Mutation proof copies `<data>/sessions/<id>/meta.json` and `events.jsonl`, or `<data>/settings.json`, into the evidence directory and checks the copy.
- Record the feature id and the entry point in `summary.txt`.
- An entry point that cannot be reached is not verified by a different one. Record the command that failed and the missing precondition.
- Do not screenshot the expanded node install command. It contains the node token.

## Feature entry contract

Each feature file starts with an H1 and one paragraph, then exactly these H2 sections, in order:

1. `Sub-features`
2. `How to get to it (user POV)`
3. `Driving it with verify-photon`
4. `Gotchas`

## Features

- [Send a message](./send-message.md) covers the composer, mock-model examples, shell and sleep prompts, raw events, and image attach.
- [Sessions](./sessions.md) covers the sidebar list, opening a session, New session, and delete.
- [Settings](./settings.md) covers the settings aside, provider changes, and reset.
- [Nodes](./nodes.md) covers the built-in `local` node and the Add a node panel, without installing a remote node.

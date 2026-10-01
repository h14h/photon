# Settings

Settings choose the provider, model, tools, and workspace used for the next run. Changes save immediately into the hub data directory and show up in the open form.

## Sub-features

- `settings-open` shows the settings aside on a fresh page and toggles it from the header.
- `settings-provider` switches provider and persists `settings.json`.
- `settings-tools` turns Bash or ViewImage off for the next run.
- `settings-reset` restores the built-in defaults after confirmation.

## How to get to it (user POV)

- The **Settings** aside is open on first load, to the right of the transcript.
- Click the gear (tooltip **Settings**) to hide or show it.
- Change **Provider**, **Thinking level**, **Tools**, **Workspace**, **System prompt**, or **Max attempts**. There is no save button.
- **Model** and **Base URL** appear for OpenAI, OpenAI Codex, OpenRouter, Fireworks, and Ollama. **API key** appears for OpenAI, OpenRouter, and Fireworks. OpenAI Codex shows a hint about `~/.codex/auth.json`. Ollama shows a hint that the default base URL is `http://localhost:11434/v1`.
- Click **Reset** and confirm **Reset all settings to defaults?**

## Driving it with verify-photon

Preconditions:

- `verify-photon doctor` prints `provider=mock` and the isolated data dir.
- Do not type a real API key. Leave **API key** blank.
- Start from a fresh launch so `<data>/settings.json` does not exist yet. Defaults apply without that file.

- **Aside is open.** Run `.cursor/skills/verify-photon/verify-photon browser start` and `.cursor/skills/verify-photon/verify-photon browser wait-selector --selector '#settings-form'`. The heading **Settings** is visible and `select[name="settings[provider]"]` value is `mock` (doctor already checked the selected option in the HTML).
- **Toggle.** Run `.cursor/skills/verify-photon/verify-photon browser click --selector 'button[title="Settings"]'`. `#settings-form` is gone. Click the same button again and `#settings-form` is back.
- **Change provider.** Run `.cursor/skills/verify-photon/verify-photon browser select --selector 'select[name="settings[provider]"]' --value openrouter`, then `.cursor/skills/verify-photon/verify-photon browser wait-text --text 'OPENROUTER_API_KEY'`. The hint names that variable. Read `<data>/settings.json`: `"provider"` is `"openrouter"`. The file mode is `0600`. Screenshot `$PHOTON_VERIFY_ROOT/evidence/settings/openrouter.png` with the Photon sidebar and the OpenRouter hint visible.
- **Blank key.** Do not fill `input[name="settings[api_key]"]`. With OpenRouter selected and the key empty, the hint reads `$OPENROUTER_API_KEY isn't set on node local. Paste a key here, or export it where the node runs.` when that variable is unset on the local node, and `✓ $OPENROUTER_API_KEY is set on node local.` when the node reports it.
- **Thinking level.** The level control is the visible label, not the clipped radio. Run `.cursor/skills/verify-photon/verify-photon browser click --selector '#settings-form label:has(input[name="settings[thinking_level]"][value="low"])'`. `settings.json` `"thinking_level"` becomes `"low"`.
- **Disable a tool.** Run `.cursor/skills/verify-photon/verify-photon browser uncheck --selector 'input[name="settings[enabled_tools][]"][value="Bash"]'`. `settings.json` `"disallowed_tools"` contains `"Bash"`.
- **Reset.** Run `.cursor/skills/verify-photon/verify-photon browser click --confirm --selector 'button[phx-click="reset_settings"]'`. `settings.json` `"provider"` is `"mock"`, `"thinking_level"` is `"high"`, and `"disallowed_tools"` is `[]`. The provider select shows **Mock model (built in, no API key)** and the OpenRouter key hint is gone.
- **Proof.** Copy the post-reset `settings.json` to `$PHOTON_VERIFY_ROOT/evidence/settings/settings.json` and record `feature=settings` in `summary.txt`. The copy is the side effect; the screenshot is the visible state before reset.

## Gotchas

- The form saves on `phx-change`. Waiting for a submit button will hang. After `browser select` or `browser check`, read `settings.json` rather than trusting the control alone.
- Labels are plain text, not `<label for>`. Use the `name` selectors, not an accessible name.
- `#settings-form` is absent from the DOM while the aside is closed. Open it with `button[title="Settings"]` before selecting.
- **Reset** uses `window.confirm`. Without `--confirm` the click is dismissed and the previous provider stays.
- Mock hides model, API key, and base URL. Model and base URL inputs are in the DOM for every other provider. `input[name="settings[api_key]"]` is in the DOM for OpenAI, OpenRouter, and Fireworks.
- API keys are written in plain text to `settings.json` and sent to the node with each run. A verification run must leave `api_key` empty.
- `phx-auto-recover="ignore"` is on this form so a reconnect does not replay a stale change. There is nothing to click.
- Default node is `local`, but the node choice for a new session is `#node-picker`, not a field inside `#settings-form`. Picking a node writes `"node"` in `settings.json`.

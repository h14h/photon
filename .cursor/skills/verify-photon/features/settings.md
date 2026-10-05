# Settings

Settings are the hub's ChatGPT sign-in, the name and instructions Blip should know, and the memory Blip keeps. The name and instructions save when you click **Save settings**, into `settings.json` in the data directory. Memory has its own edit button.

## Sub-features

- `settings-open` shows the settings page and the signed-out ChatGPT card.
- `settings-save` stores your name, time zone, and standing instructions.
- `settings-memory` edits what Blip remembers.
- `settings-fresh` starts a fresh context after confirmation.

## How to get to it (user POV)

- Click **Settings** in the sidebar. The page heading is **Settings**.
- The **ChatGPT** card says Blip needs a model and offers **Sign in with ChatGPT**. With the scripted model, Blip can already talk; this card is still signed out.
- Under **Blip**, edit **Your name**, **Your time zone**, and **Standing instructions**. Click **Save settings**. There is no save-as-you-type.
- Under **What Blip remembers**, click **Edit**, change the text, and click **Save**.
- Click **Fresh context** and confirm **Start a fresh context? Blip stops seeing earlier messages (they stay in the chat). Memory is kept.**

## Driving it with verify-photon

Preconditions:

- `verify-photon doctor` prints `provider=mock` and the isolated data dir.
- Do not finish a ChatGPT sign-in. Do not paste a callback address. Leave the sign-in form unsubmitted.
- Start from a fresh launch so `<data>/settings.json` does not exist yet. Defaults apply without that file.

- **Open the page.** Run `.cursor/skills/verify-photon/verify-photon browser click --selector '#nav-settings'`, then `.cursor/skills/verify-photon/verify-photon browser wait-selector --selector '#settings-form'`. The heading **Settings** is visible, `#begin-sign-in` is visible, and `#chatgpt` does not say `Signed in`. The model and reasoning fields are absent. The sidebar still shows **Photon**.
- **Save.** Run `.cursor/skills/verify-photon/verify-photon browser fill --selector 'input[name="settings[user_name]"]' --value 'Ada'`, then the same for `input[name="settings[timezone]"]` with `UTC` and `textarea[name="settings[instructions]"]` with `Prefer the local machine.`, then `.cursor/skills/verify-photon/verify-photon browser click --selector '#save-settings'`. Wait for `Saved. The next message uses these settings.` Read `<data>/settings.json`: `user_name` is `Ada`, `timezone` is `UTC`, `instructions` is `Prefer the local machine.`, and `scheduled_work` is `false`. The file mode is `0600`.
- **Memory.** Run `.cursor/skills/verify-photon/verify-photon browser click --selector '#edit-memory'`, fill `#memory-form textarea` with `The local machine is the one to use.`, click `#memory-form button[type="submit"]`, and wait until `#memory-text` contains that sentence.
- **Fresh context.** Run `.cursor/skills/verify-photon/verify-photon browser click --confirm --selector '#fresh-start'`. The page says `Started a fresh context.` Earlier Blip messages stay in the panel if you open it again.
- **Proof.** Copy the saved `settings.json` to `$PHOTON_VERIFY_ROOT/evidence/settings/settings.json`. Screenshot `$PHOTON_VERIFY_ROOT/evidence/settings/saved.png` after save, with the Photon sidebar and **Saved.** visible. Record `feature=settings` in `summary.txt`.

## Gotchas

- The form does not save on `phx-change`. **Save settings** (`#save-settings`) writes the file. Waiting for a change to touch `settings.json` without that click will hang.
- Model, reasoning effort, and the schedules checkbox render only when ChatGPT is signed in (`#chatgpt` shows **Signed in**). The mock model does not sign in, so those controls are not in the DOM. Do not select a provider; there is no provider field.
- **Sign in with ChatGPT** (`#begin-sign-in`) starts the real OpenAI redirect. Verification stops at the button. Completing it needs a ChatGPT account and a callback address this harness does not have.
- API keys are not a field. The account lives in `chatgpt.json`, which this run must not create.
- **Fresh context** uses `window.confirm`. Without `--confirm` the click is dismissed and no reset entry is written.
- **Fresh context** does not delete messages and does not clear memory. It is not a reset of `settings.json`.
- The sidebar's model chip reads **GPT-6.1 Sol** from the default model name even while the scripted model is answering. That is not proof of a sign-in.
- Clicking `#nav-settings` closes Blip's floating panel. Open Blip again with `#blip-face` before sending.

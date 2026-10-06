# Overview

Overview is the hub home page. It lists machines and what is scheduled. Work on a machine is a Blip conversation, not a row on this page. Node sessions are gone: nothing on this page links to `/sessions`, and that path is a 404.

## Sub-features

- `overview-machines` shows the built-in `local` machine online, with a hint to use Blip.
- `overview-schedules-empty` shows no schedules before any are created.
- `overview-schedule` adds a row when Blip schedules a prompt, then removes it on confirm.
- `overview-sessions-gone` has no session link, and `/sessions/ns_1` is a 404.
- `overview-theme` switches the shell to the dark theme.
- `overview-sign-in` shows the signed-out ChatGPT banner in the sidebar.

## How to get to it (user POV)

- Open the hub, or click **Overview** in the sidebar. The heading is **Overview**. The subtitle counts machines. One machine reads **1 of 1 machine online.**
- Under **Machines**, the `local` card says **online** and names its host and platform. Under the cards: **Work happens through Blip: ask it to run something on any of these.**
- Under **Schedules**, before anything is scheduled: **None yet. Ask Blip for something recurring, like "every morning, check my disks".**
- Ask Blip `every 30 minutes: check disks`. A row titled **check disks** appears, with a clock interval. The X (tooltip **Cancel**) asks **Cancel this schedule?**
- The sidebar lists `local` under **Machines** and links it to `/nodes`. It does not list sessions. **Sign in with ChatGPT** sits above **Settings**. The theme control offers **System theme**, **Light theme**, and **Dark theme**.

## Driving it with verify-photon

Preconditions:

- `verify-photon doctor` prints `ok`.
- Start from a fresh launch for the empty schedule check. Create the schedule this recipe cancels with Blip, after that empty check: `every 30 minutes: check disks`. Thirty minutes keeps the routine from firing during the pass.

- **Empty page.** After launch, run `.cursor/skills/verify-photon/verify-photon browser start`, then `.cursor/skills/verify-photon/verify-photon browser click --selector '#blip-close'`, then `.cursor/skills/verify-photon/verify-photon browser wait-text --within '#schedules' --text 'None yet'`. `#machine-local` contains `online`. `#work-hint` contains `Work happens through Blip`. `#overview-summary` contains `1 of 1 machine online.` `.cursor/skills/verify-photon/verify-photon browser count --selector '#sidebar a[href^="/sessions/"]'` prints `0`. Screenshot `$PHOTON_VERIFY_ROOT/evidence/overview/empty.png` with the Photon sidebar visible.
- **Sessions are gone.** `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${PHOTON_VERIFY_PORT:-4010}/sessions/ns_1` prints `404`.
- **Sign-in banner.** `#sign-in-banner` is visible and its text is `Sign in with ChatGPT`. Do not click it; that opens Settings and starts nothing by itself, but the pass leaves sign-in for `settings.md`.
- **Theme.** Run `.cursor/skills/verify-photon/verify-photon browser click --selector 'button[title="Dark theme"]'`, then `.cursor/skills/verify-photon/verify-photon browser count --selector 'html[data-theme="dark"]'`. It prints `1`. Click `button[title="System theme"]` to put it back. `html[data-theme-source="system"]` then counts `1`.
- **Schedule.** Open Blip with `#blip-face`. Fill `#composer-input` with `every 30 minutes: check disks` and click `#send`. Wait until `#conversation` contains `Scheduling it.` Close Blip with `#blip-close`. `#schedules` contains `check disks` and a `#schedule-` row. The `machine_ops` table is not the proof; the row is a durable routine, and the transcript is enough alongside the page.
- **Cancel.** Run `.cursor/skills/verify-photon/verify-photon browser click --confirm --selector '#schedules button[title="Cancel"]'`. The confirm text is `Cancel this schedule?`. `#schedules` again contains `None yet`, and no `#schedule-` row remains.
- **Proof.** Screenshots: `empty.png` before any schedule, `scheduled.png` while the row is visible, `cancelled.png` after confirm. Record `feature=overview` in `summary.txt`.

## Gotchas

- Closing Blip before the empty screenshot keeps the machines and schedules in view. The panel covers the bottom of the page while it is open.
- Close Blip with `#blip-close` before clicking **Overview**, **Nodes**, or **Settings**. The outside-click animation consumes the click, so the first click only closes the panel. `#blip-close` is not visible while the panel is already closed.
- The sidebar machine row is `#side-node-local` and its address is `/nodes`. There is no `#side-session-` id.
- The cancel control has no id of its own. With one schedule, `#schedules button[title="Cancel"]` is that button. Omit `--confirm` and the harness dismisses the dialog, leaving the schedule in place.
- `in 2 minutes: …` would fire during a long pass. Use `every 30 minutes: …` so the row stays until you cancel it.
- An empty hub with no machines shows `#no-machines` (**No machines yet**) and the subtitle **Add a machine and Blip can start working on it.** This harness always has `local`, so that empty state is not the one to assert.
- **Make its command** on Nodes issues a key, and Overview then counts that machine too (`1 of 2 machines online.` once `vps-1` exists). Read **1 of 1 machine online.** before that step.
- The theme buttons have no id. Match `button[title="Dark theme"]` and `button[title="System theme"]`.

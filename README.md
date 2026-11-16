# DeskRecall

A macOS menu bar app that puts every window back where it belongs — the right display, the right
Mission Control desktop (Space), the right size — for whichever monitors are plugged in right now.

You save a **profile** per display setup (laptop only, home monitor, office monitor, two monitors…).
Click **Arrange** and DeskRecall works out which profile fits the displays connected now and which
open window belongs in which saved slot, then moves them. Apps that aren't open are skipped.

## What makes it different

| | Stay | Rectangle Pro | DeskRecall |
| --- | --- | --- | --- |
| Layout per display setup | yes, exact match only | yes, per named display | yes, and the closest profile is adapted to a new setup |
| Move windows to other desktops (Spaces) | no | no | yes |
| Windows on desktops you aren't looking at | no | no | yes |
| Matching windows whose titles changed | manual "linking" / patterns | title regex, z-order | a decision model (Jev) |
| Snapping, halves/thirds, shortcuts | no | yes | no (use Rectangle for that) |

## How it decides

Identity cases are settled locally: a profile saved on exactly these monitors, a window with the
same title, one open window for one saved slot. Every judgement call goes to
[TypeSafe Jev](https://typesafe.ai), a decision model that returns a typed answer with a calibrated
confidence:

- **Which profile?** When no profile was saved on exactly this set of monitors (or several were).
- **Which display stands in for which?** When a profile is replayed on different monitors.
- **Which window is which?** When an app has several windows and the titles no longer match.

Low-confidence answers are treated as conflicts: Arrange shows one dialog with its best guess
preselected and lets you correct it. After arranging from a merely similar profile, DeskRecall
offers to save the result as a new profile for this setup. Auto-arrange never guesses unattended.

Without a Jev key the app still works for exact setups; same-app windows are then paired in window
order and you pick the profile yourself when it is ambiguous.

## Install

Requires macOS 26.4 or later for moving windows between desktops (window frames work on macOS 14+),
and Xcode command line tools.

```bash
scripts/build-app.sh
```

This builds `DeskRecall.app`, signs it, installs it to `/Applications` and launches it. Then:

1. Grant **Accessibility** when asked (System Settings → Privacy & Security → Accessibility). It is
   the only permission the app needs; it is what lets it read window titles and move windows.
2. Menu bar icon → **Add TypeSafe Jev Key…**. The key is stored in your login keychain.
3. Lay out your windows, then **Save Layout as New Profile…**. Repeat once per display setup.

Signing: the script uses the first code-signing identity in your keychain so the Accessibility
grant survives rebuilds. With none, it signs ad hoc and macOS asks again after each rebuild.

## Menu

- **Arrange** — find the profile for the current displays and arrange.
- **Save Layout as New Profile…** / **Update “…” with Current Layout**
- **Profiles ▸** apply, replace, rename or delete any profile.
- **Auto-arrange When Displays Change** — arranges a few seconds after a monitor is connected or removed.
- **Ask When Unsure About a Window** — turn off to always take Jev's best guess.
- **Launch at Login**

## Command line

Accessibility belongs to the app bundle, so run commands through it:

```bash
open -W -n -a DeskRecall --args --arrange --out /tmp/deskrecall.txt
```

`--arrange [--profile NAME]`, `--save NAME`, `--dump` (displays, desktops and windows as the app
sees them), `--selfcheck` (logic tests; runs straight from `.build/debug/DeskRecall`).

## Limits

- Spaces are handled through Apple's private SkyLight framework because no public API exists. That
  rules out the Mac App Store, and a future macOS could break it; the app then still restores
  displays, positions and sizes.
- Desktops are remembered by position ("third desktop on the built-in display"). DeskRecall doesn't
  create desktops: if a profile needs more than exist, it uses the last one and tells you.
- Minimized and full-screen windows are left alone.
- Profiles live in `~/Library/Application Support/DeskRecall/profiles.json`.

## Layout of the code

`Sources/DeskRecall/` — `Config` (names, thresholds), `Displays`, `Spaces` (private API),
`Windows` (Accessibility), `Profiles`, `Jev`, `Arranger` (the decision flow), `App` (menu and dialogs).

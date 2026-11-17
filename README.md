# DeskRecall

A macOS menu bar app that puts every window back where it belongs — the right display, the right
Mission Control desktop (Space), the right size, minimized or not — for whichever monitors are
plugged in right now.

You save a **profile** per display setup (laptop only, home monitor, office monitor, two monitors…).
Click **Arrange** and DeskRecall works out which profile fits the displays connected now and which
open window belongs in which saved slot, then moves them. Apps that aren't open are skipped.
A window that was minimized when the profile was saved is minimized again; a window that is
minimized now but was on screen in the profile comes out of the Dock and goes to its saved desktop.

The **Profiles window** (menu → Profiles…, or just open the app again) shows every profile as a
picture: each display, each desktop drawn to scale with its windows, and the minimized ones listed
underneath. It is view only on purpose. To change a layout, arrange the real windows and press
**Update with Current Layout…**.

## What makes it different

| | Stay | Rectangle Pro | DeskRecall |
| --- | --- | --- | --- |
| Layout per display setup | yes, exact match only | yes, per named display | yes, and the closest profile is adapted to a new setup |
| Move windows to other desktops (Spaces) | no | no | yes |
| Windows on desktops you aren't looking at | no | no | yes |
| Minimized state | no | no | yes, both ways |
| See a saved layout as a picture | no | no | yes |
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
offers to save the result as a new profile for this setup. Auto-arrange never picks a profile by
guesswork: with no clear match it does nothing. For a window it is unsure about it takes the best
guess, which is always a slot of the same app, and says so in the status line.

Without a Jev key the app still works for exact setups; same-app windows are then paired in window
order and you pick the profile yourself when it is ambiguous.

A monitor counts as the same monitor at any scaled resolution (frames are stored as fractions of the
display). Several profiles can be saved on the same monitors, say "Work" and "Evening": Arrange uses
the one you last saved or applied there, and **Apply Profile ▸** switches.

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
- **Apply Profile ▸** — arrange from a specific profile (ticked: saved on the displays connected now).
- **Save Layout as New Profile…** / **Update “…” with Current Layout…** (asks first; there is no undo).
  Saving under an existing name updates that profile.
- **Profiles…** — the window: look at, apply, update, rename or delete any profile.
- **Auto-arrange When Displays Change** — arranges a few seconds after a monitor is connected or removed.
- **Ask When Unsure About a Window** — turn off to always take Jev's best guess.
- **Launch at Login**

## Command line

Accessibility belongs to the app bundle, so run commands through it:

```bash
open -W -n -a DeskRecall --args --arrange --out /tmp/deskrecall.txt
```

`--arrange [--profile NAME]`, `--save NAME`, `--dump [--verbose]` (displays, desktops and windows as
the app sees them), `--selfcheck` (logic tests; runs straight from `.build/debug/DeskRecall`).

For checking what a macOS release still allows, one step on one window (ids from `--dump`):
`--move WINDOW SPACE`, `--minimize WINDOW true|false`. `--shot FILE.png` prints the menu and renders
the Profiles window to an image without showing either.

The Jev key can also come from a `TYPESAFE_API_KEY` environment variable, which wins over the
keychain. To put a key in the keychain without the menu, let the app store it (an item added by
another tool, such as `security`, makes macOS prompt on every read):

```bash
open -W -n --env TYPESAFE_API_KEY=your-key -a DeskRecall --args --store-key
```

## Limits

- Spaces are handled through Apple's private SkyLight framework because no public API exists. That
  rules out the Mac App Store, and a future macOS could break it; the app then still restores
  displays, positions and sizes.
- Desktops are remembered by position ("third desktop on the built-in display"). DeskRecall doesn't
  create desktops: if a profile needs more than exist, it uses the last one and tells you.
- With "Displays have separate Spaces" switched off in System Settings, one row of desktops spans
  every display. The code handles that case but it has not been tested on a real Mac.
- Full-screen windows are left alone. So are windows that are open but not in the profile.
- A profile saved by version 0.1 has no minimized information, so every window in it counts as
  "on screen". Press **Update with Current Layout…** once to record it.
- If the profiles file can't be read (hand-edited, or written by a newer version) it is moved aside
  to `profiles.unreadable.json` rather than overwritten.
- Profiles live in `~/Library/Application Support/DeskRecall/profiles.json`.

## Layout of the code

`Sources/DeskRecall/` — `Config` (names, thresholds), `Displays`, `Spaces` (private API),
`Windows` (Accessibility), `Profiles`, `Jev`, `Arranger` (pick the profile, match, move),
`App` (menu, dialogs, actions), `ProfilesWindow` (the SwiftUI window).

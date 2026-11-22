#!/usr/bin/env python3
"""Live tests: drive the installed DeskRecall against real windows on the displays connected now.

    uv run python scripts/live-test.py            every case the current setup allows
    uv run python scripts/live-test.py frame dock just the named cases

Each case puts three TextEdit windows into a known layout, saves it as a profile, messes the
layout up, runs Arrange, and checks every window is back: display, desktop, frame, minimized.
Cases that need a second desktop or a second display are skipped when there is none, so run it
again on each setup you use (laptop only, one monitor, two monitors).

It only touches TextEdit (it refuses to start if TextEdit is already open), saves a profile that
holds only TextEdit windows, and puts your saved profiles and settings back when it finishes.
Mission Control opens briefly in the cases that add or remove a desktop.
"""
import os, re, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
PROFILES = os.path.expanduser("~/Library/Application Support/DeskRecall/profiles.json")
DOMAIN = "com.sreenivasanac.deskrecall"
APP = "com.apple.TextEdit"
PROFILE = "__livetest"
NAMES = ["dr-test-A.txt", "dr-test-B.txt", "dr-test-C.txt"]
TOLERANCE = 6          # points; the app itself treats 4 as "in place"


def cli(*args):
    """One DeskRecall command-line mode, through the app bundle."""
    return subprocess.run([os.path.join(HERE, "run-cli.sh"), *map(str, args)], capture_output=True, text=True).stdout


class Desk:
    """What --dump reports, reduced to what the tests compare."""

    def __init__(self):
        out = cli("--dump")
        self.displays = []      # (x, y, width, height, [space ids])
        self.windows = {}       # title -> dict(id, frame, display, desktop, minimized)
        for m in re.finditer(r"^display \d+ .*?(\d+)x(\d+), at x=(-?\d+) y=(-?\d+).*desktops=\[(.*?)\]", out, re.M):
            w, h, x, y = map(int, m.groups()[:4])
            self.displays.append((x, y, w, h, [int(s) for s in m.group(5).split(",") if s.strip()]))
        for m in re.finditer(r'^window (\d+) \[TextEdit\] "(.*?)" frame=\((.*?)\) spaces=\[(.*?)\](.*)$', out, re.M):
            frame = tuple(float(n) for n in m.group(3).split(","))
            spaces = [int(s) for s in m.group(4).split(",") if s.strip()]
            display, desktop = next(((i, d[4].index(spaces[0]) + 1) for i, d in enumerate(self.displays)
                                     if len(spaces) == 1 and spaces[0] in d[4]), (None, 0))
            self.windows[m.group(2)] = dict(id=int(m.group(1)), frame=frame, display=display, desktop=desktop,
                                            minimized="minimized" in m.group(5))

    def place(self, display, fx, fy, fw, fh):
        """A frame given as fractions of a display, kept clear of the menu bar and the Dock."""
        x, y, w, h, _ = self.displays[display]
        return (round(x + fx * w), round(y + 40 + fy * (h - 140)), round(fw * w), round(fh * (h - 140)))


def differences(want, got):
    """Why the layout `got` is not the layout `want`; empty when it is."""
    problems = []
    for title, a in want.items():
        b = got.get(title)
        if b is None:
            problems.append(f"{title}: window is gone")
            continue
        if any(abs(p - q) > TOLERANCE for p, q in zip(a["frame"], b["frame"])):
            problems.append(f"{title}: frame {b['frame']} instead of {a['frame']}")
        for key in ("display", "desktop", "minimized"):
            if a[key] != b[key]:
                problems.append(f"{title}: {key} {b[key]} instead of {a[key]}")
    return problems


def windows():
    """The three test windows, by short name."""
    desk = Desk()
    return desk, {n[8]: desk.windows[n] for n in NAMES if n in desk.windows}


def lay_out(desk, w, plan):
    """plan: short name -> (frame, desktop or None, minimized). Applies it with the low-level flags."""
    for name, (frame, space, minimized) in plan.items():
        cli("--minimize", w[name]["id"], "false")
        cli("--frame", w[name]["id"], *frame)
        if space:
            cli("--move", w[name]["id"], space)
        if minimized:
            cli("--minimize", w[name]["id"], "true")


def check(baseline_plan, mess):
    """Lay out, save, mess up, arrange, compare. `mess` gets (desk, windows) and changes things."""
    desk, w = windows()
    plan = baseline_plan(desk)
    lay_out(desk, w, plan)
    time.sleep(1)
    now = Desk()
    want = now.windows
    # The starting layout must really be the one asked for, or a pass would prove nothing.
    for name, (_, space, minimized) in plan.items():
        got = want.get("dr-test-%s.txt" % name)
        if got is None:     # closed by hand, or the app did not answer in time
            return [f"setup failed: test window {name} is not there"], ""
        on = now.displays[got["display"]][4][got["desktop"] - 1] if got["display"] is not None else None
        if on != space or got["minimized"] != minimized:
            return [f"setup failed: {name} is on desktop {on}, minimized={got['minimized']}; wanted {space}, {minimized}"], ""
    cli("--save", PROFILE, "--app", APP)
    desk, w = windows()
    mess(desk, w)
    time.sleep(1)
    messed = Desk().windows
    noticed = cli("--moved", PROFILE).strip()
    summary = cli("--arrange", "--profile", PROFILE).strip()
    time.sleep(1.5)
    problems = differences(want, Desk().windows)
    # What the menu says about the layout: changed after the mess, in place again after Arrange.
    if noticed in ("", "moved 0"):
        problems.append(f"the app did not notice the changed layout ({noticed or 'no answer'})")
    after = cli("--moved", PROFILE).strip()
    if after != "moved 0":
        problems.append(f"after Arrange the app still reports a changed layout ({after or 'no answer'})")
    if not differences(want, messed):
        problems.append("the mess step changed nothing, so this proved nothing")
    return problems, summary


def side_by_side(desk, display=0, space_b=None, c_minimized=False, c_display=None):
    d = desk.displays[display][4]
    cd = display if c_display is None else c_display
    return {"A": (desk.place(display, 0.02, 0.02, 0.45, 0.9), d[0], False),
            "B": (desk.place(display, 0.5, 0.02, 0.45, 0.55), space_b or d[0], False),
            "C": (desk.place(cd, 0.3, 0.3, 0.4, 0.5), desk.displays[cd][4][0], c_minimized)}


# ---- The cases. Each returns (problems, arrange summary), or a string saying why it was skipped.

def case_frame():
    """Moved and resized windows go back to their saved position and size."""
    def mess(desk, w):
        cli("--frame", w["A"]["id"], *desk.place(0, 0.4, 0.3, 0.3, 0.4))
        cli("--frame", w["B"]["id"], *desk.place(0, 0.05, 0.1, 0.6, 0.8))
    return check(side_by_side, mess)


def case_restore():
    """A window that is minimized now but was on screen in the profile comes out of the Dock, in place."""
    def mess(desk, w):
        cli("--frame", w["A"]["id"], *desk.place(0, 0.4, 0.3, 0.3, 0.4))
        cli("--minimize", w["A"]["id"], "true")
    return check(side_by_side, mess)


def case_dock():
    """A window that was minimized in the profile is minimized again."""
    def mess(desk, w):
        cli("--minimize", w["C"]["id"], "false")
    return check(lambda desk: side_by_side(desk, c_minimized=True), mess)


def case_desktop():
    """A window goes back to its desktop, including one that is not showing."""
    desk = Desk()
    if len(desk.displays[0][4]) < 2:
        return "needs a second desktop on display 0"
    def mess(desk, w):
        cli("--move", w["B"]["id"], desk.displays[0][4][0])
    return check(lambda desk: side_by_side(desk, space_b=desk.displays[0][4][1]), mess)


def case_desktop_and_dock():
    """Minimized now and on the wrong desktop: restored onto the desktop it was saved on."""
    desk = Desk()
    if len(desk.displays[0][4]) < 2:
        return "needs a second desktop on display 0"
    def mess(desk, w):
        cli("--move", w["B"]["id"], desk.displays[0][4][0])
        cli("--minimize", w["B"]["id"], "true")
    return check(lambda desk: side_by_side(desk, space_b=desk.displays[0][4][1]), mess)


def case_display():
    """A window dragged to another display goes back to its own."""
    if len(Desk().displays) < 2:
        return "needs a second display"
    def mess(desk, w):
        cli("--frame", w["C"]["id"], *desk.place(0, 0.1, 0.1, 0.3, 0.3))
    return check(lambda desk: side_by_side(desk, c_display=1), mess)


def case_new_desktop():
    """The profile uses a desktop that no longer exists: DeskRecall adds it and moves the window there."""
    before = len(Desk().displays[0][4])
    out = cli("--add-desktop", 0)
    if "ok" not in out:
        return [f"setup failed: could not add a desktop ({out.strip()})"], ""
    setup = []
    def mess(desk, w):
        cli("--move", w["B"]["id"], desk.displays[0][4][0])
        out = cli("--remove-desktop", 0)
        if "ok" not in out:
            setup.append(f"setup failed: could not remove the desktop ({out.strip()})")
    try:
        problems, summary = check(lambda desk: side_by_side(desk, space_b=desk.displays[0][4][-1]), mess)
        if setup:
            return setup, summary
        if "added 1 desktop" not in summary:
            problems.append("the summary does not say a desktop was added")
        return problems, summary
    finally:
        desk, w = windows()
        if "B" in w:
            cli("--move", w["B"]["id"], desk.displays[0][4][0])
        while len(Desk().displays[0][4]) > before:
            if "ok" not in cli("--remove-desktop", 0):
                break


def case_reopened():
    """Windows that were closed and opened again (new window ids) are recognised by their file."""
    def mess(desk, w):
        subprocess.run(["pkill", "-x", "TextEdit"])
        time.sleep(1.5)
        open_textedit()
        desk, w = windows()
        cli("--frame", w["A"]["id"], *desk.place(0, 0.4, 0.3, 0.3, 0.4))
    return check(side_by_side, mess)


CASES = {"frame": case_frame, "restore": case_restore, "dock": case_dock, "desktop": case_desktop,
         "desktop-dock": case_desktop_and_dock, "display": case_display, "new-desktop": case_new_desktop,
         "reopened": case_reopened}

FILES = []


def open_textedit():
    subprocess.run(["open", "-F", "-a", "TextEdit", *FILES])     # -F: don't bring back windows from last time
    for _ in range(20):
        time.sleep(1)
        if len(windows()[1]) == len(NAMES):
            return
    sys.exit("TextEdit did not open the three test windows")


def main():
    wanted = sys.argv[1:] or list(CASES)
    unknown = [c for c in wanted if c not in CASES]
    if unknown:
        sys.exit(f"unknown case {unknown}; choose from {list(CASES)}")
    if subprocess.run(["pgrep", "-x", "TextEdit"], capture_output=True).returncode == 0:
        sys.exit("TextEdit is open. Quit it first: the tests open and close TextEdit themselves.")
    if "accessibility trusted: true" not in cli("--dump"):
        sys.exit("DeskRecall is not installed or has no Accessibility permission.")

    tmp = tempfile.mkdtemp(prefix="deskrecall-test-")
    backup, settings = os.path.join(tmp, "profiles.json"), os.path.join(tmp, "settings.plist")
    had_profiles = os.path.exists(PROFILES)
    if had_profiles:
        shutil.copy2(PROFILES, backup)
    subprocess.run(["defaults", "export", DOMAIN, settings])
    for name in NAMES:
        path = os.path.join(tmp, name)
        open(path, "w").write(f"DeskRecall live test window {name}\n")
        FILES.append(path)

    desk = Desk()
    print(f"{len(desk.displays)} display(s), desktops per display: {[len(d[4]) for d in desk.displays]}")
    failed = 0
    try:
        open_textedit()
        for name in wanted:
            result = CASES[name]()
            if isinstance(result, str):
                print(f"SKIP  {name}: {result}")
                continue
            problems, summary = result
            failed += bool(problems)
            print(f"{'FAIL' if problems else 'PASS'}  {name}: {CASES[name].__doc__}\n      arrange said: {summary}")
            for p in problems:
                print(f"      - {p}")
    finally:
        subprocess.run(["pkill", "-x", "TextEdit"])
        if had_profiles:
            shutil.copy2(backup, PROFILES)
        elif os.path.exists(PROFILES):
            os.remove(PROFILES)
        subprocess.run(["defaults", "import", DOMAIN, settings])
        shutil.rmtree(tmp, ignore_errors=True)
    print("your profiles and settings are restored")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()

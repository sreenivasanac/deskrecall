import AppKit

// Command-line modes, for scripting and debugging. Accessibility is granted to the app bundle,
// so run them through it:  open -W -n -a DeskRecall --args --arrange --out /tmp/log.txt
let args = CommandLine.arguments
func value(after flag: String) -> String? {
    args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
}
if let path = value(after: "--out") { freopen(path, "w", stdout) }

// `--selfcheck`: the pure logic, no permissions or network needed.
if args.contains("--selfcheck") {
    let picked = Matching.assign([(live: 1, slot: 10, p: 0.6), (live: 2, slot: 10, p: 0.9), (live: 1, slot: 11, p: 0.3), (live: 3, slot: 10, p: 0.5)])
    precondition(picked == [2: 10, 1: 11], "best pairs first, one window per slot, extras left out")

    let display = DisplayInfo(name: "T", vendor: 1, model: 2, serial: 3, builtin: false, uuid: "u", x: -133, y: -1080, width: 1920, height: 1080)
    let half = SavedWindow(bundleID: "b", appName: "a", title: "t", display: 0, space: 1, fx: 0.5, fy: 0, fw: 0.5, fh: 1)
    precondition(half.frame(on: display) == CGRect(x: 827, y: -1080, width: 960, height: 1080), "fractions scale to the display")

    let other = DisplayInfo(name: "B", vendor: 9, model: 9, serial: 0, builtin: true, uuid: "v", x: 0, y: 0, width: 1512, height: 982)
    precondition(Displays.setKey([display, other]) == Displays.setKey([other, display]), "display set identity ignores order")

    let sample = #"{"model":"jev-1.14.0","answers":{"w1":{"type":"choice","choice":"s2","confidence":0.7,"probabilities":{"s1":0.2,"s2":0.8}},"close":{"type":"noul","noul":0.98}},"usage":{"input_tokens":1,"output_tokens":1}}"#
    let parsed = try Jev.parse(Data(sample.utf8))
    precondition(parsed["w1"]?.choice == "s2" && parsed["w1"]?.probabilities["s1"] == 0.2 && parsed["close"]?.yes == 0.98, "documented response shape parses")
    print("selfcheck ok")
    exit(0)
}

// `--dump`: what the app can see.
if args.contains("--dump") {
    let spaces = Spaces.userSpaces()
    print("accessibility trusted:", Windows.trusted)
    for d in Displays.current() { print("display \(d.summary) key=\(d.hardwareKey) desktops=\(spaces[d.uuid] ?? [])") }
    for w in Windows.capture() {
        print("window \(w.id) [\(w.appName)] \"\(w.title.prefix(40))\" frame=\(w.frame.integral) spaces=\(w.spaces)")
    }
    exit(0)
}

// `--move <windowID> <spaceID>`: move one window to a Space and report where it ended up.
if let w = value(after: "--move").flatMap(CGWindowID.init), args.count > 3, let space = UInt64(args[args.firstIndex(of: "--move")! + 2]) {
    print("before:", Spaces.of(w))
    Spaces.move([w], to: space)
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    print("after:", Spaces.of(w))
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// `--save <name>` and `--arrange`: the two menu actions without the menu (never show dialogs).
if let name = value(after: "--save") {
    let profile = Profile.snapshot(name: name, displays: Displays.current(), windows: Windows.capture(), spaces: Spaces.userSpaces())
    Store.save(Store.load().filter { $0.name != name } + [profile])
    print("saved \(name): \(profile.windows.count) windows (accessibility trusted: \(Windows.trusted))")
    exit(0)
}
if args.contains("--arrange") {
    Task { @MainActor in
        let forced = value(after: "--profile").flatMap { name in Store.load().first { $0.name == name } }
        print(await Arranger.arrange(interactive: false, forced: forced).summary)
        exit(0)
    }
    app.run()
}

let delegate = MainActor.assumeIsolated { AppDelegate() }   // top-level code runs on the main thread
app.delegate = delegate
app.run()

import AppKit
import SwiftUI

// Command-line modes, for scripting and debugging. Accessibility is granted to the app bundle,
// so run them through it:  open -W -n -a DeskRecall --args --arrange --out /tmp/log.txt
let args = CommandLine.arguments
func value(after flag: String) -> String? {
    args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
}
if let path = value(after: "--out") { freopen(path, "w", stdout) }
UserDefaults.standard.register(defaults: [Keys.autoArrange: true, Keys.askWhenUnsure: true])    // both toggles start on

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

    // A profile written before minimized windows were recorded must still load (losing it would lose the user's layouts).
    let old = #"{"bundleID":"b","appName":"a","title":"t","display":0,"space":2,"fx":0,"fy":0,"fw":1,"fh":1}"#
    let window = try JSONDecoder().decode(SavedWindow.self, from: Data(old.utf8))
    precondition(!window.isMinimized && window.space == 2, "old profiles decode, not minimized")
    precondition(DisplayInfo(name: "T", vendor: 1, model: 2, serial: 3, builtin: false, uuid: "x", x: 0, y: 0, width: 2560, height: 1440).hardwareKey == display.hardwareKey,
                 "a monitor is the same monitor at another resolution")

    // "Displays have separate Spaces" off: one desktop spans both displays, so the frame must pick the display.
    let onSecond = LiveWindow(element: AXUIElementCreateSystemWide(), id: 1, bundleID: "b", appName: "a", title: "t",
                              frame: CGRect(x: 100, y: 100, width: 400, height: 300), spaces: [5], minimized: false)
    let shared = Profile.snapshot(name: "s", displays: [display, other], windows: [onSecond], spaces: ["u": [4, 5], "v": [4, 5]])
    precondition(shared.windows[0].display == 1 && shared.windows[0].space == 2, "a shared desktop leaves the display to the window's frame")
    let own = Profile.snapshot(name: "o", displays: [display, other], windows: [onSecond], spaces: ["u": [4, 5], "v": [6]])
    precondition(own.windows[0].display == 0 && own.windows[0].space == 2, "a desktop of one display decides the display")
    print("selfcheck ok")
    exit(0)
}

// `--dump`: what the app can see.
if args.contains("--dump") {
    let spaces = Spaces.userSpaces()
    Windows.debug = args.contains("--verbose")
    print("accessibility trusted:", Windows.trusted, "visible desktops:", Spaces.visible().sorted())
    for d in Displays.current() { print("display \(d.summary) key=\(d.hardwareKey) desktops=\(spaces[d.uuid] ?? [])") }
    for w in Windows.capture() {
        print("window \(w.id) [\(w.appName)] \"\(w.title.prefix(40))\" frame=\(w.frame.integral) spaces=\(w.spaces)\(w.minimized ? " minimized" : "")")
    }
    exit(0)
}

// `--store-key`: copy TYPESAFE_API_KEY from the environment into the keychain, owned by this app.
//   open -W -n --env TYPESAFE_API_KEY=... -a DeskRecall --args --store-key
if args.contains("--store-key") {
    guard let key = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !key.isEmpty else { print("TYPESAFE_API_KEY is not set"); exit(1) }
    let stored = Jev.store(key)
    print(stored ? "stored" : "the keychain refused the key")
    exit(stored ? 0 : 1)
}

// `--move <windowID> <spaceID>` and `--minimize <windowID> <true|false>`: one low-level step on
// one window, then where it ended up. For checking what a macOS release still allows.
func report(_ id: CGWindowID) {
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    let now = Windows.capture().first { $0.id == id }
    print("after: spaces=\(Spaces.of(id)) minimized=\(now?.minimized ?? false) frame=\(now?.frame.integral ?? .zero) visible=\(Spaces.visible().sorted())")
    exit(0)
}
if let i = args.firstIndex(of: "--move"), args.count > i + 2, let id = CGWindowID(args[i + 1]), let space = UInt64(args[i + 2]) {
    print("before: spaces=\(Spaces.of(id)) visible=\(Spaces.visible().sorted())")
    Spaces.move([id], to: space)
    report(id)
}
if let i = args.firstIndex(of: "--minimize"), args.count > i + 2, let id = CGWindowID(args[i + 1]), let on = Bool(args[i + 2]) {
    guard let window = Windows.capture().first(where: { $0.id == id }) else { print("no such window"); exit(1) }
    print("before: spaces=\(window.spaces) minimized=\(window.minimized) frame=\(window.frame.integral) visible=\(Spaces.visible().sorted())")
    Windows.setMinimized(window.element, on)
    report(id)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// `--shot <png>`: print the menu and draw the Profiles window into an image, without showing either, to check the UI.
if let path = value(after: "--shot") {
    MainActor.assumeIsolated {
        let model = AppDelegate()
        model.refresh()
        let menu = NSMenu()
        model.menuNeedsUpdate(menu)
        func show(_ menu: NSMenu, _ indent: String) {
            for item in menu.items {
                print(indent + (item.isSeparatorItem ? "────" : (item.state == .on ? "✓ " : "") + item.title + (item.action == nil && item.submenu == nil ? "   (info)" : "")))
                if let sub = item.submenu { show(sub, indent + "    ") }
            }
        }
        show(menu, "")
        let host = NSHostingView(rootView: ProfilesView(app: model).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: Config.profilesWindowSize),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))    // let SwiftUI lay out and load icons
        if let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: image)
            try? image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
    exit(0)
}

// `--save <name>` and `--arrange`: the two menu actions without the menu (never show dialogs).
if let name = value(after: "--save") {
    // Without the permission no window can be read, and saving that would replace a real profile with an empty one.
    guard Windows.trusted else { print("not saved: needs Accessibility permission"); exit(1) }
    let profile = Profile.snapshot(name: name, displays: Displays.current(), windows: Windows.capture(), spaces: Spaces.userSpaces())
    guard Store.save(Store.load().filter { $0.name != name } + [profile]) else { print("not saved: couldn't write \(Config.profilesURL.path)"); exit(1) }
    print("saved \(name): \(profile.windows.count) windows")
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

import AppKit
import ServiceManagement
import SwiftUI

/// The app: the menu bar item, the Profiles window, and the actions both of them trigger.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, ObservableObject {
    // What the menu and the Profiles window show. Refreshed from the system whenever either appears.
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var trusted = false
    @Published private(set) var busy = false
    @Published private(set) var status = "Ready"
    @Published private(set) var hasJevKey = false
    @Published private(set) var launchAtLogin = false
    @Published var pane = Pane.profiles
    /// The layout this display setup is on, and how many of its windows have been moved since.
    @Published private(set) var current: Profile?
    @Published private(set) var moved = 0

    enum Pane: String, CaseIterable { case welcome = "Welcome", profiles = "Profiles", settings = "Settings", about = "About" }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var window: NSWindow?
    private var lastKey = ""
    private var pending: DispatchWorkItem?

    private var setKey: String { Displays.setKey(displays) }
    /// Profiles saved on exactly the monitors connected now.
    var matching: [Profile] { profiles.filter { $0.fits(displays) } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        item.button?.image = NSImage(systemSymbolName: Config.menuBarSymbol, accessibilityDescription: Config.appName)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refresh()
        lastKey = setKey
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        Updates.start()
        // First run: the Welcome pane says what to do next. Someone already set up before it existed skips it.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Keys.onboarded) {
            if profiles.isEmpty || !trusted { show(.welcome) } else { defaults.set(true, forKey: Keys.onboarded) }
        } else if profiles.isEmpty || !trusted {
            show(.profiles)
        }
    }

    func refresh() {
        profiles = Store.load()
        displays = Displays.current()
        trusted = Windows.trusted
        hasJevKey = Jev.hasKey
        launchAtLogin = SMAppService.mainApp.status == .enabled
        current = Store.current(profiles, for: displays)
    }

    /// Compares the open windows with the current layout. Reads every window, so it runs only
    /// when the menu or the window is about to show the answer, not on every refresh.
    private func refreshMoved() {
        moved = trusted ? current.map { Arranger.moved(from: $0, displays: displays, live: Windows.capture()) } ?? 0 : 0
    }
    private var movedText: String { "\(moved) window\(moved == 1 ? " has" : "s have") moved" }

    /// Every change to the saved profiles goes through here: read from disk, change, write, republish.
    /// False, with the reason as the status, when the file could not be written.
    @discardableResult
    private func edit(_ change: (inout [Profile]) -> Void) -> Bool {
        var all = Store.load()
        change(&all)
        let saved = Store.save(all)
        refresh()
        if !saved { finish("Couldn't write \(Config.profilesURL.lastPathComponent); nothing was changed", ok: false) }
        return saved
    }

    /// False, after pointing at the permission banner, while Accessibility is not granted.
    private func ready() -> Bool {
        refresh()
        if !trusted { show(.profiles) }
        return trusted
    }

    // MARK: Menu (rebuilt each time it opens, so it always shows the current setup)

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        refreshMoved()
        menu.removeAllItems()
        func info(_ text: String) { menu.addItem(NSMenuItem(title: text, action: nil, keyEquivalent: "")) }

        info("Displays: " + displays.map { "\($0.name) \($0.width)×\($0.height)" }.joined(separator: " + "))
        if let current {
            info("Layout: “\(current.name)” · " + (moved == 0 ? "no window has moved" : "\(movedText) since"))
        } else {
            info("Layout: " + (profiles.isEmpty ? "no profile saved yet" : "no profile for these displays yet"))
        }
        info(status)
        menu.addItem(.separator())
        if !trusted {
            menu.addItem(ActionItem("Grant Accessibility Permission…") { Windows.requestTrust() })
            menu.addItem(.separator())
        }
        // The two ways out of a changed layout sit next to each other: go back to it, or keep the change.
        if let current {
            menu.addItem(ActionItem(moved == 0 ? "Restore “\(current.name)”" : "Put Windows Back (Restore “\(current.name)”)") { [weak self] in self?.arrange(interactive: true) })
            menu.addItem(ActionItem(moved == 0 ? "Update “\(current.name)” with Current Layout…" : "Keep This Layout (Update “\(current.name)”)…") { [weak self] in self?.update(current) })
        } else {
            menu.addItem(ActionItem(profiles.isEmpty ? "Arrange" : "Arrange from the Closest Profile") { [weak self] in self?.arrange(interactive: true) })
        }
        menu.addItem(ActionItem("Save Layout as New Profile…") { [weak self] in self?.saveNew() })
        if profiles.count > (current == nil ? 0 : 1) {
            let apply = NSMenuItem(title: "Switch to Profile", action: nil, keyEquivalent: "")
            apply.submenu = NSMenu()
            for p in profiles {
                // A tick for the layout in force, a dash once windows have moved away from it.
                let state: NSControl.StateValue = p.id != current?.id ? .off : moved == 0 ? .on : .mixed
                apply.submenu?.addItem(ActionItem(p.name, state: state) { [weak self] in self?.arrange(interactive: true, forced: p) })
            }
            menu.addItem(apply)
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("Profiles…") { [weak self] in self?.show(.profiles) })
        menu.addItem(ActionItem("Settings…") { [weak self] in self?.show(.settings) })
        // The one switch worth reaching without opening a window, say before plugging into a projector.
        let defaults = UserDefaults.standard
        menu.addItem(ActionItem("Auto-arrange When Displays Change", checked: defaults.bool(forKey: Keys.autoArrange)) {
            defaults.set(!defaults.bool(forKey: Keys.autoArrange), forKey: Keys.autoArrange)
        })
        menu.addItem(.separator())
        let help = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        help.submenu = NSMenu()
        help.submenu?.addItem(ActionItem("Welcome Guide") { [weak self] in self?.show(.welcome) })
        help.submenu?.addItem(ActionItem("Website and Documentation") { NSWorkspace.shared.open(Config.website) })
        help.submenu?.addItem(.separator())
        help.submenu?.addItem(ActionItem("Report a Bug…") { Diagnostics.reportBug() })
        help.submenu?.addItem(ActionItem("Send Feedback…") { Diagnostics.sendFeedback() })
        help.submenu?.addItem(ActionItem("Copy Diagnostics") { [weak self] in self?.copyDiagnostics() })
        menu.addItem(help)
        if Updates.available { menu.addItem(ActionItem("Check for Updates…") { Updates.check() }) }
        menu.addItem(ActionItem("About \(Config.appName)") { [weak self] in self?.show(.about) })
        menu.addItem(ActionItem("Quit \(Config.appName)") { NSApp.terminate(nil) })
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Diagnostics.report(), forType: .string)
        finish("Diagnostics copied to the clipboard", ok: true)
    }

    // MARK: Window (profiles and settings share it)

    func show(_ pane: Pane) {
        self.pane = pane
        refresh()
        refreshMoved()
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: ProfilesView(app: self)))
            w.title = Config.appName
            w.setContentSize(Config.profilesWindowSize)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opening the app again (Spotlight, Finder, Launchpad) shows the window: a menu bar app has no other front door.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show(.profiles)
        return true
    }

    /// Coming back from System Settings or another app: permission and displays may have changed.
    func windowDidBecomeKey(_ notification: Notification) { refresh(); refreshMoved() }

    // MARK: Actions (shared by the menu and the window)

    func arrange(interactive: Bool, forced: Profile? = nil) {
        guard !busy else { return }
        busy = true
        item.button?.title = " …"
        Task {
            let outcome = await Arranger.arrange(interactive: interactive, forced: forced)
            busy = false
            refresh()
            refreshMoved()
            finish(outcome.summary, ok: outcome.arranged)
            guard interactive, !outcome.cancelled else { return }
            if !trusted {
                show(.profiles)
            } else if !outcome.arranged {
                if UI.confirm(outcome.summary, "Save the current window layout as a profile for this display setup?", ok: "Save as New Profile…", cancel: "Not Now") { saveNew() }
            } else if !outcome.exact, forced == nil {
                // Arranged from the closest profile: offer this setup one of its own.
                if UI.confirm("New display setup", "\(outcome.summary).\n\nThis setup has no profile of its own yet. Adjust anything you like, then save it. You can also do that later from the menu.",
                              ok: "Save as New Profile…", cancel: "Later") { saveNew() }
            }
        }
    }

    private func snapshot(named name: String) -> Profile {
        Profile.snapshot(name: name, displays: Displays.current(), windows: Windows.capture(), spaces: Spaces.userSpaces())
    }

    func saveNew() {
        guard ready() else { return }
        let suggested = displays.map(\.name).joined(separator: " + ")
        guard let name = UI.prompt("Save layout as a new profile",
                                   "Records every open window: its display, desktop, size and whether it is minimized. It applies to the displays connected now.",
                                   value: suggested) else { return }
        if let existing = profiles.first(where: { $0.name == name }) { return update(existing) }   // same name: replace, after asking
        let profile = snapshot(named: name)
        guard edit({ $0.append(profile) }) else { return }
        Store.prefer(profile, on: displays)
        refresh(); refreshMoved()
        finish("Saved “\(name)” (\(profile.windows.count) windows)", ok: true)
    }

    /// Replaces a profile's layout with where the windows are now. No undo, so it asks first.
    func update(_ old: Profile) {
        guard ready() else { return }
        let moved = old.fits(displays) ? "" : " It was saved on other displays; it will now belong to the displays connected now."
        guard UI.confirm("Update “\(old.name)” with the current layout?",
                         "Its \(old.windows.count) saved windows are replaced by where your windows are now." + moved, ok: "Update") else { return }
        var fresh = snapshot(named: old.name)
        fresh.id = old.id
        guard edit({ all in if let i = all.firstIndex(where: { $0.id == old.id }) { all[i] = fresh } }) else { return }
        Store.prefer(fresh, on: displays)
        refresh(); refreshMoved()
        finish("Updated “\(old.name)” (\(fresh.windows.count) windows)", ok: true)
    }

    func rename(_ profile: Profile) {
        guard let name = UI.prompt("Rename profile", "", value: profile.name) else { return }
        edit { all in if let i = all.firstIndex(where: { $0.id == profile.id }) { all[i].name = name } }
    }

    func delete(_ profile: Profile) {
        guard UI.confirm("Delete “\(profile.name)”?", "This cannot be undone.", ok: "Delete") else { return }
        edit { $0.removeAll { $0.id == profile.id } }
    }

    func setJevKey() {
        guard let key = UI.prompt("TypeSafe Jev API key", "With a key, details of your displays, the names of the apps and profiles involved, and the titles of windows \(Config.appName) can't match on its own are sent to \(Config.jevEndpoint.host ?? "TypeSafe") when you arrange. Saving a key is your agreement to that. The key itself stays in your login keychain.", secure: true) else { return }
        guard Jev.store(key) else {
            _ = UI.confirm("Couldn't save the Jev key", "The login keychain refused it. Unlock the keychain and try again.", cancel: nil)
            return
        }
        refresh()
        Task {   // one tiny request to confirm the key works
            do {
                _ = try await Jev.ask(state: "ping", questions: ["ok": Jev.noul("Is this text the word ping?")])
                _ = UI.confirm("Jev key saved", "The key works.", cancel: nil)
            } catch {
                _ = UI.confirm("Jev key saved, but the test request failed", "\(error)", cancel: nil)
            }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { _ = UI.confirm("Couldn't change Launch at Login", error.localizedDescription, cancel: nil) }
        refresh()
    }

    /// Result of the last action: in the menu, the window footer, the icon's tooltip, and as a brief mark.
    private func finish(_ text: String, ok: Bool) {
        status = text
        item.button?.toolTip = text
        item.button?.title = ok ? " ✓" : " –"
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.busy == false { self?.item.button?.title = "" }
        }
    }

    /// Fires for any screen change; only a different set of monitors triggers an arrange,
    /// and only after macOS has finished reshuffling windows on its own.
    @objc private func screensChanged() {
        refresh()
        refreshMoved()      // the count must not outlive the layout it was taken for
        guard setKey != lastKey else { return }
        lastKey = setKey
        pending?.cancel()
        guard UserDefaults.standard.bool(forKey: Keys.autoArrange) else { return }
        let work = DispatchWorkItem { [weak self] in self?.arrange(interactive: false) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Config.displayChangeSettle, execute: work)
    }
}

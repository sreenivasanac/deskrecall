import AppKit
import ServiceManagement
import SwiftUI

/// The few dialogs the app needs, as plain alerts.
@MainActor
enum UI {
    private static func alert(_ title: String, _ message: String, buttons: [String], accessory: NSView? = nil) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        alert.accessoryView = accessory
        if let accessory { alert.window.initialFirstResponder = accessory }
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func confirm(_ title: String, _ message: String, ok: String = "OK", cancel: String? = "Cancel") -> Bool {
        alert(title, message, buttons: [ok] + (cancel.map { [$0] } ?? []))
    }

    static func prompt(_ title: String, _ message: String, value: String = "", secure: Bool = false) -> String? {
        let field: NSTextField = secure ? NSSecureTextField() : NSTextField()
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        field.stringValue = value
        guard alert(title, message, buttons: ["Save", "Cancel"], accessory: field) else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func popup(_ options: [String], selected: Int) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26))
        // Items by index, not title: two saved windows can share a description.
        for option in options { popup.menu?.addItem(NSMenuItem(title: option, action: nil, keyEquivalent: "")) }
        popup.selectItem(at: selected)
        return popup
    }

    static func pick(_ title: String, _ message: String, options: [String], selected: Int) -> Int? {
        let popup = popup(options, selected: selected)
        return alert(title, message, buttons: ["Use", "Cancel"], accessory: popup) ? popup.indexOfSelectedItem : nil
    }

    /// One row per uncertain window: its name and a menu of places it could go.
    static func resolve(_ title: String, _ message: String, rows: [(label: String, options: [String], selected: Int)]) -> [Int]? {
        let popups = rows.map { popup($0.options, selected: $0.selected) }
        let views = zip(rows, popups).flatMap { [NSTextField(labelWithString: $0.label), $1] as [NSView] }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: CGFloat(rows.count) * 54)
        return alert(title, message, buttons: ["Arrange", "Skip These"], accessory: stack) ? popups.map(\.indexOfSelectedItem) : nil
    }
}

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, checked: Bool = false, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { run() }
}

/// The app: the menu bar item, the Profiles window, and the actions both of them trigger.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, ObservableObject {
    // What the menu and the Profiles window show. Refreshed from the system whenever either appears.
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var trusted = false
    @Published private(set) var busy = false
    @Published private(set) var status = "Ready"

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var window: NSWindow?
    private var lastKey = ""
    private var pending: DispatchWorkItem?

    var setKey: String { Displays.setKey(displays) }
    /// Profiles saved on exactly the monitors connected now.
    var matching: [Profile] { profiles.filter { $0.setKey == setKey } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        item.button?.image = NSImage(systemSymbolName: Config.menuBarSymbol, accessibilityDescription: Config.appName)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refresh()
        lastKey = setKey
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        if profiles.isEmpty || !trusted { showProfiles() }    // first run: the window says what to do next
    }

    func refresh() {
        profiles = Store.load()
        displays = Displays.current()
        trusted = Windows.trusted
    }

    /// Every change to the saved profiles goes through here: read from disk, change, write, republish.
    private func edit(_ change: (inout [Profile]) -> Void) {
        var all = Store.load()
        change(&all)
        Store.save(all)
        refresh()
    }

    /// False, after pointing at the permission banner, while Accessibility is not granted.
    private func ready() -> Bool {
        refresh()
        if !trusted { showProfiles() }
        return trusted
    }

    // MARK: Menu (rebuilt each time it opens, so it always shows the current setup)

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()
        let same = matching
        func info(_ text: String) { menu.addItem(NSMenuItem(title: text, action: nil, keyEquivalent: "")) }

        info("Displays: " + displays.map { "\($0.name) \($0.width)×\($0.height)" }.joined(separator: " + "))
        info("Profile: " + (!same.isEmpty ? same.map(\.name).joined(separator: ", ")
                            : profiles.isEmpty ? "none saved yet" : "none for this setup, the closest is adapted"))
        info(status)
        menu.addItem(.separator())
        if !trusted {
            menu.addItem(ActionItem("Grant Accessibility Permission…") { Windows.requestTrust() })
            menu.addItem(.separator())
        }
        menu.addItem(ActionItem("Arrange") { [weak self] in self?.arrange(interactive: true) })
        if !profiles.isEmpty {
            let apply = NSMenuItem(title: "Apply Profile", action: nil, keyEquivalent: "")
            apply.submenu = NSMenu()
            for p in profiles {
                apply.submenu?.addItem(ActionItem(p.name, checked: same.contains { $0.id == p.id }) { [weak self] in self?.arrange(interactive: true, forced: p) })
            }
            menu.addItem(apply)
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("Save Layout as New Profile…") { [weak self] in self?.saveNew() })
        if same.count == 1 {
            menu.addItem(ActionItem("Update “\(same[0].name)” with Current Layout…") { [weak self] in self?.update(same[0]) })
        }
        menu.addItem(ActionItem("Profiles…") { [weak self] in self?.showProfiles() })
        menu.addItem(.separator())
        let defaults = UserDefaults.standard
        menu.addItem(ActionItem("Auto-arrange When Displays Change", checked: defaults.bool(forKey: Keys.autoArrange)) {
            defaults.set(!defaults.bool(forKey: Keys.autoArrange), forKey: Keys.autoArrange)
        })
        menu.addItem(ActionItem("Ask When Unsure About a Window", checked: defaults.bool(forKey: Keys.askWhenUnsure)) {
            defaults.set(!defaults.bool(forKey: Keys.askWhenUnsure), forKey: Keys.askWhenUnsure)
        })
        let loginOn = SMAppService.mainApp.status == .enabled
        menu.addItem(ActionItem("Launch at Login", checked: loginOn) {
            do { if loginOn { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() } }
            catch { _ = UI.confirm("Couldn't change Launch at Login", error.localizedDescription, cancel: nil) }
        })
        menu.addItem(ActionItem(Jev.apiKey == nil ? "Add TypeSafe Jev Key…" : "Change TypeSafe Jev Key…") { [weak self] in self?.setJevKey() })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit \(Config.appName)") { NSApp.terminate(nil) })
    }

    // MARK: Profiles window

    func showProfiles() {
        refresh()
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: ProfilesView(app: self)))
            w.title = "\(Config.appName) Profiles"
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
        showProfiles()
        return true
    }

    /// Coming back from System Settings or another app: permission and displays may have changed.
    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    // MARK: Actions (shared by the menu and the window)

    func arrange(interactive: Bool, forced: Profile? = nil) {
        guard !busy else { return }
        busy = true
        item.button?.title = " …"
        Task {
            let outcome = await Arranger.arrange(interactive: interactive, forced: forced)
            busy = false
            refresh()
            finish(outcome.summary, ok: outcome.arranged)
            guard interactive, !outcome.cancelled else { return }
            if !trusted {
                showProfiles()
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
        edit { $0.append(profile) }
        Store.prefer(profile)
        finish("Saved “\(name)” (\(profile.windows.count) windows)", ok: true)
    }

    /// Replaces a profile's layout with where the windows are now. No undo, so it asks first.
    func update(_ old: Profile) {
        guard ready() else { return }
        let moved = old.setKey == setKey ? "" : " It was saved on other displays; it will now belong to the displays connected now."
        guard UI.confirm("Update “\(old.name)” with the current layout?",
                         "Its \(old.windows.count) saved windows are replaced by where your windows are now." + moved, ok: "Update") else { return }
        var fresh = snapshot(named: old.name)
        fresh.id = old.id
        edit { all in if let i = all.firstIndex(where: { $0.id == old.id }) { all[i] = fresh } }
        Store.prefer(fresh)
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

    private func setJevKey() {
        guard let key = UI.prompt("TypeSafe Jev API key", "Stored in your login keychain and sent only to \(Config.jevEndpoint.host ?? "TypeSafe").", secure: true) else { return }
        Jev.apiKey = key
        Task {   // one tiny request to confirm the key works
            do {
                _ = try await Jev.ask(state: "ping", questions: ["ok": Jev.noul("Is this text the word ping?")])
                _ = UI.confirm("Jev key saved", "The key works.", cancel: nil)
            } catch {
                _ = UI.confirm("Jev key saved, but the test request failed", "\(error)", cancel: nil)
            }
        }
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
        guard setKey != lastKey else { return }
        lastKey = setKey
        pending?.cancel()
        guard UserDefaults.standard.bool(forKey: Keys.autoArrange) else { return }
        let work = DispatchWorkItem { [weak self] in self?.arrange(interactive: false) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Config.displayChangeSettle, execute: work)
    }
}

import AppKit
import ServiceManagement

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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var lastSummary = "Ready"
    private var lastKey = Displays.setKey(Displays.current())
    private var pending: DispatchWorkItem?
    private var busy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Keys.autoArrange: true, Keys.askWhenUnsure: true])
        item.button?.image = NSImage(systemSymbolName: Config.menuBarSymbol, accessibilityDescription: Config.appName)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        if !Windows.trusted { Windows.requestTrust() }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // MARK: Menu (rebuilt each time it opens, so it always shows the current setup)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let displays = Displays.current()
        let profiles = Store.load()
        let same = profiles.filter { $0.setKey == Displays.setKey(displays) }
        func info(_ text: String) { menu.addItem(NSMenuItem(title: text, action: nil, keyEquivalent: "")) }

        info("Displays: " + displays.map { "\($0.name) \($0.width)×\($0.height)" }.joined(separator: " + "))
        info("Profile: " + (same.isEmpty ? "none saved for this setup" : same.map(\.name).joined(separator: ", ")))
        info(lastSummary)
        menu.addItem(.separator())
        if !Windows.trusted {
            menu.addItem(ActionItem("Grant Accessibility Permission…") { Windows.requestTrust() })
            menu.addItem(.separator())
        }
        menu.addItem(ActionItem("Arrange") { [weak self] in self?.arrange(interactive: true) })
        menu.addItem(ActionItem("Save Layout as New Profile…") { [weak self] in self?.saveNew() })
        if same.count == 1 {
            menu.addItem(ActionItem("Update “\(same[0].name)” with Current Layout") { [weak self] in self?.replace(same[0]) })
        }
        if !profiles.isEmpty {
            let all = NSMenuItem(title: "Profiles", action: nil, keyEquivalent: "")
            all.submenu = NSMenu()
            for p in profiles {
                let one = NSMenuItem(title: "\(p.name)  (\(p.displays.count) display\(p.displays.count == 1 ? "" : "s"), \(p.windows.count) windows)", action: nil, keyEquivalent: "")
                one.submenu = NSMenu()
                one.submenu?.addItem(ActionItem("Apply Now") { [weak self] in self?.arrange(interactive: true, forced: p) })
                one.submenu?.addItem(ActionItem("Replace with Current Layout") { [weak self] in self?.replace(p) })
                one.submenu?.addItem(ActionItem("Rename…") {
                    guard let name = UI.prompt("Rename profile", "", value: p.name) else { return }
                    Store.save(Store.load().map { var q = $0; if q.id == p.id { q.name = name }; return q })
                })
                one.submenu?.addItem(ActionItem("Delete") {
                    guard UI.confirm("Delete “\(p.name)”?", "This cannot be undone.", ok: "Delete") else { return }
                    Store.save(Store.load().filter { $0.id != p.id })
                })
                all.submenu?.addItem(one)
            }
            menu.addItem(all)
        }
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

    // MARK: Actions

    private func arrange(interactive: Bool, forced: Profile? = nil) {
        guard !busy else { return }
        busy = true
        Task {
            let outcome = await Arranger.arrange(interactive: interactive, forced: forced)
            busy = false
            lastSummary = outcome.summary
            flash(outcome.arranged ? "✓" : "–")
            guard interactive else { return }
            if !Windows.trusted {
                Windows.requestTrust()
            } else if !outcome.arranged {
                if UI.confirm(outcome.summary, "Save the current window layout as a profile for this display setup?", ok: "Save as New Profile…", cancel: "Not Now") { saveNew() }
            } else if !outcome.exact, forced == nil {
                // Arranged from the closest profile: offer this setup one of its own.
                if UI.confirm("New display setup", "\(outcome.summary).\n\nThis setup has no profile of its own yet. Adjust anything you like, then save it. You can also do that later from the menu.",
                              ok: "Save as New Profile…", cancel: "Later") { saveNew() }
            }
        }
    }

    private func saveNew() {
        guard Windows.trusted else { return Windows.requestTrust() }
        let displays = Displays.current()
        let suggested = displays.map(\.name).joined(separator: " + ")
        guard let name = UI.prompt("Save layout as a new profile", "Records where every open window is, on which desktop, for the displays connected now.", value: suggested) else { return }
        let profile = Profile.snapshot(name: name, displays: displays, windows: Windows.capture(), spaces: Spaces.userSpaces())
        Store.save(Store.load() + [profile])
        lastSummary = "Saved “\(name)” (\(profile.windows.count) windows)"
        flash("✓")
    }

    private func replace(_ old: Profile) {
        guard Windows.trusted else { return Windows.requestTrust() }
        var fresh = Profile.snapshot(name: old.name, displays: Displays.current(), windows: Windows.capture(), spaces: Spaces.userSpaces())
        fresh.id = old.id
        Store.save(Store.load().map { $0.id == old.id ? fresh : $0 })
        lastSummary = "Updated “\(old.name)” (\(fresh.windows.count) windows)"
        flash("✓")
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

    private func flash(_ mark: String) {
        item.button?.title = " " + mark
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.item.button?.title = "" }
    }

    /// Fires for any screen change; only a different set of monitors triggers an arrange,
    /// and only after macOS has finished reshuffling windows on its own.
    @objc private func screensChanged() {
        let key = Displays.setKey(Displays.current())
        guard key != lastKey else { return }
        lastKey = key
        pending?.cancel()
        guard UserDefaults.standard.bool(forKey: Keys.autoArrange) else { return }
        let work = DispatchWorkItem { [weak self] in self?.arrange(interactive: false) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Config.displayChangeSettle, execute: work)
    }
}

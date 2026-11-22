import AppKit

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

    /// A confirmation with one checkbox: nil when cancelled, otherwise whether the box was ticked.
    static func confirm(_ title: String, _ message: String, ok: String, option: String) -> Bool? {
        let box = NSButton(checkboxWithTitle: option, target: nil, action: nil)
        return alert(title, message, buttons: [ok, "Cancel"], accessory: box) ? box.state == .on : nil
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
    init(_ title: String, checked: Bool = false, state: NSControl.StateValue? = nil, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        self.state = state ?? (checked ? .on : .off)
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { run() }
}

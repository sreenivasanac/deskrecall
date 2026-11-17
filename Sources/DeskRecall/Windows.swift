import AppKit
import ApplicationServices

/// A window that is open right now.
struct LiveWindow {
    let element: AXUIElement
    let id: CGWindowID
    let pid: pid_t
    let bundleID: String
    let appName: String
    let title: String
    let document: String?      // file or URL shown, when the app reports one (document-based apps)
    var frame: CGRect          // global CG coordinates (top-left origin); kept while minimized
    var spaces: [UInt64]
    var minimized: Bool        // in the Dock; still belongs to a desktop
}

/// Reads and moves other apps' windows through the Accessibility API (the one permission the app needs).
enum Windows {
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias CreateWithToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    private static let getWindow = dlsym(rtldDefault, "_AXUIElementGetWindow").map { unsafeBitCast($0, to: GetWindow.self) }
    private static let createWithToken = dlsym(rtldDefault, "_AXUIElementCreateWithRemoteToken").map { unsafeBitCast($0, to: CreateWithToken.self) }

    static var debug = false    // `--dump --verbose` prints every window element and why it was kept or dropped
    static var trusted: Bool { AXIsProcessTrusted() }
    static func requestTrust() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func frame(of el: AXUIElement) -> CGRect? {
        guard let p: AXValue = attr(el, kAXPositionAttribute), let s: AXValue = attr(el, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p, .cgPoint, &point); AXValueGetValue(s, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    /// kAXWindows only lists windows on the visible Spaces. Windows parked on other Spaces are
    /// found by asking for the app's accessibility elements by id (the technique AltTab uses).
    /// ponytail: scans ids 0..<1000 for at most 100 ms per app; long-lived apps with very many
    /// windows opened and closed can exceed that, raise the cap if windows on other Spaces go missing.
    private static func elementsOnOtherSpaces(pid: pid_t) -> [AXUIElement] {
        guard let createWithToken else { return [] }
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f_636f)) { Data($0) })
        var found: [AXUIElement] = []
        let deadline = Date().addingTimeInterval(0.1)
        for elementID in UInt64(0)..<1000 {
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementID) { Data($0) })
            if let el = createWithToken(token as CFData)?.takeRetainedValue(),
               let subrole: String = attr(el, kAXSubroleAttribute), subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole {
                found.append(el)
            }
            if Date() > deadline { break }
        }
        return found
    }

    /// Every standard, non-fullscreen window of every regular app, on all Spaces, minimized ones included.
    static func capture() -> [LiveWindow] {
        var result: [LiveWindow] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier, bundleID != Config.bundleID else { continue }
            let pid = app.processIdentifier
            let appEl = AXUIElementCreateApplication(pid)
            // Covers only the window-list read below, so a hung app costs a second there. Its window
            // elements keep the system default; the hidden-Space scan stops at its deadline after one slow answer.
            AXUIElementSetMessagingTimeout(appEl, 1)
            let visible: [AXUIElement] = attr(appEl, kAXWindowsAttribute) ?? []
            var seen = Set<CGWindowID>()
            for el in visible + elementsOnOtherSpaces(pid: pid) {
                var id: CGWindowID = 0
                guard let getWindow, getWindow(el, &id) == .success, id != 0, seen.insert(id).inserted else { continue }
                let subrole: String? = attr(el, kAXSubroleAttribute)
                let minimized = (attr(el, kAXMinimizedAttribute) as Bool?) == true
                let fullscreen = (attr(el, "AXFullScreen") as Bool?) == true
                let spaces = Spaces.of(id)      // empty = not shown on any desktop (hidden helper windows)
                // Only files: browsers report the page address here, which changes with every tab and is nobody's business.
                let document = (attr(el, kAXDocumentAttribute) as String?).flatMap { $0.hasPrefix("file:") ? $0 : nil }
                if debug { print("  ax \(id) [\(app.localizedName ?? "")] subrole=\(subrole ?? "-") min=\(minimized) full=\(fullscreen) spaces=\(spaces) doc=\(document ?? "-") ident=\(attr(el, kAXIdentifierAttribute) as String? ?? "-") title=\(attr(el, kAXTitleAttribute) as String? ?? "-")") }
                // Some apps (Safari, Muse) report an ordinary window as a dialog while it sits in the Dock.
                // "On no desktop" only means a hidden helper window while desktops can be read at all.
                guard subrole == kAXStandardWindowSubrole || (minimized && subrole == kAXDialogSubrole), !fullscreen,
                      !spaces.isEmpty || !Spaces.available, let frame = frame(of: el) else { continue }
                result.append(LiveWindow(element: el, id: id, pid: pid, bundleID: bundleID, appName: app.localizedName ?? bundleID,
                                         title: attr(el, kAXTitleAttribute) ?? "", document: document, frame: frame, spaces: spaces, minimized: minimized))
            }
        }
        return result
    }

    /// Size, then position, then size again: the first resize can be clamped by the old display's edges.
    static func setFrame(_ el: AXUIElement, _ frame: CGRect) {
        var origin = frame.origin, size = frame.size
        guard let p = AXValueCreate(.cgPoint, &origin), let s = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, s)
        AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, p)
        AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, s)
    }

    /// Sends a window to the Dock or brings it back.
    static func setMinimized(_ el: AXUIElement, _ minimized: Bool) {
        AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString, minimized as CFBoolean)
    }
}

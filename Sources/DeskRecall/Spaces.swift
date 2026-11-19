import AppKit
import ObjectiveC

/// Mission Control Spaces. macOS has no public API for these, so everything here goes through
/// the private SkyLight framework, looked up at runtime so a missing symbol degrades to
/// "no Spaces support" instead of a crash. Works with SIP enabled on macOS 26.4+.
enum Spaces {
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias DisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias SpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias InitOperation = @convention(c) (AnyObject, Selector, NSArray, UInt64) -> AnyObject?

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let skyLight, let found = dlsym(skyLight, name) else { return nil }
        return unsafeBitCast(found, to: type)
    }
    private static let connection = symbol("SLSMainConnectionID", as: MainConnection.self)
    private static let displaySpaces = symbol("SLSCopyManagedDisplaySpaces", as: DisplaySpaces.self)
    private static let spacesForWindows = symbol("SLSCopySpacesForWindows", as: SpacesForWindows.self)

    /// False when this macOS no longer answers "which desktops is this window on". Callers then
    /// keep working without desktops rather than treating every window as shown nowhere.
    static var available: Bool { connection != nil && spacesForWindows != nil }

    /// Ordinary desktops per display UUID, in Mission Control order (fullscreen-app Spaces left out).
    /// Index + 1 is the "Desktop N" position on that display.
    static func userSpaces() -> [String: [UInt64]] {
        guard let connection, let displaySpaces,
              let displays = displaySpaces(connection())?.takeRetainedValue() as? [[String: Any]] else { return [:] }
        var result: [String: [UInt64]] = [:]
        for display in displays {
            guard let id = display["Display Identifier"] as? String,
                  let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            let desktops = spaces.filter { ($0["type"] as? Int) == 0 }
                .compactMap { ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value }
            // With "Displays have separate Spaces" off, SkyLight reports a single display called "Main":
            // one row of desktops that spans every display.
            if id == "Main" { for d in Displays.current() { result[d.uuid] = desktops } } else { result[id] = desktops }
        }
        return result
    }

    /// The desktop showing on each display right now.
    static func visible() -> Set<UInt64> {
        guard let connection, let displaySpaces,
              let displays = displaySpaces(connection())?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return Set(displays.compactMap { (($0["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value })
    }

    /// The Spaces a window is on (more than one only for "all desktops" windows).
    static func of(_ window: CGWindowID) -> [UInt64] {
        guard let connection, let spacesForWindows,
              let spaces = spacesForWindows(connection(), 7 /* all spaces */, [NSNumber(value: window)] as CFArray)?
                .takeRetainedValue() as? [NSNumber] else { return [] }
        return spaces.map(\.uint64Value)
    }

    /// Moves windows to a Space through the window-management bridge macOS itself uses.
    /// Asynchronous: read back with `of(_:)` to confirm.
    static func move(_ windows: [CGWindowID], to space: UInt64) {
        let initializer = NSSelectorFromString("initWithWindows:spaceID:")
        let run = NSSelectorFromString("performWithWMBridgeDelegate")
        guard let type = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation") as? NSObject.Type,
              type.instancesRespond(to: initializer), type.instancesRespond(to: run),
              let fresh = type.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else { return }
        let make = unsafeBitCast(class_getMethodImplementation(type, initializer), to: InitOperation.self)
        guard let operation = make(fresh, initializer, windows.map { NSNumber(value: $0) } as NSArray, space) as? NSObject else { return }
        _ = operation.perform(run)
    }

    // MARK: Adding and removing desktops

    // macOS offers no call that adds a desktop, so this does what a person does: open Mission
    // Control and press its "+" button, through the Dock's accessibility tree (the technique
    // Hammerspoon uses). Mission Control is on screen for about a second while it happens.
    private static let missionControl = URL(fileURLWithPath: "/System/Applications/Mission Control.app")

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
    private static func child(of element: AXUIElement, identifier: String, displayID: CGDirectDisplayID? = nil) -> AXUIElement? {
        (attribute(element, kAXChildrenAttribute) as [AXUIElement]? ?? []).first {
            attribute($0, kAXIdentifierAttribute) as String? == identifier
                && (displayID == nil || (attribute($0, "AXDisplayID") as NSNumber?)?.uint32Value == displayID)
        }
    }

    /// Opens Mission Control, hands the display's row of desktops to `work`, and closes it again.
    /// False when Mission Control's controls could not be found (the tree changes between macOS versions).
    @MainActor
    private static func inMissionControl(displayUUID: String, _ work: (_ bar: AXUIElement) async -> Bool) async -> Bool {
        guard let uuid = CFUUIDCreateFromString(nil, displayUUID as CFString),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return false }
        let displayID = CGDisplayGetDisplayIDFromUUID(uuid)
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        func bar() -> AXUIElement? {
            child(of: dockElement, identifier: "mc").flatMap { child(of: $0, identifier: "mc.display", displayID: displayID) }
                .flatMap { child(of: $0, identifier: "mc.spaces") }
        }
        guard bar() == nil else { print("mission control: already open"); return false }   // the user is in there, keep out
        NSWorkspace.shared.open(missionControl)
        var found: AXUIElement?
        for _ in 0..<30 where found == nil {                             // it animates in; up to 3 s on a busy Mac
            try? await Task.sleep(nanoseconds: 100_000_000)
            found = bar()
        }
        guard let found else { print("mission control: did not open"); return false }      // don't toggle again
        let done = await work(found)
        NSWorkspace.shared.open(missionControl)                          // opening it again closes it
        try? await Task.sleep(nanoseconds: 700_000_000)
        return done
    }

    /// Adds `count` desktops at the end of a display's row. Returns whether the button was found and pressed.
    @MainActor
    static func addDesktops(_ count: Int, displayUUID: String) async -> Bool {
        await inMissionControl(displayUUID: displayUUID) { bar in
            guard let add = child(of: bar, identifier: "mc.spaces.add") else { print("mission control: no add button"); return false }
            for _ in 0..<count {
                guard AXUIElementPerformAction(add, kAXPressAction as CFString) == .success else { return false }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            return true
        }
    }

    /// Removes the last desktop of a display's row; its windows move to a neighbouring desktop.
    /// Only the command line uses this, to clean up after the live tests.
    @MainActor
    static func removeLastDesktop(displayUUID: String) async -> Bool {
        await inMissionControl(displayUUID: displayUUID) { bar in
            guard let list = child(of: bar, identifier: "mc.spaces.list"),
                  let last = (attribute(list, kAXChildrenAttribute) as [AXUIElement]? ?? []).last else { print("mission control: no desktop list"); return false }
            let removed = AXUIElementPerformAction(last, "AXRemoveDesktop" as CFString) == .success
            if !removed { print("mission control: remove action refused") }
            try? await Task.sleep(nanoseconds: 300_000_000)
            return removed
        }
    }
}

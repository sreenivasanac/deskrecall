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

    /// Ordinary desktops per display UUID, in Mission Control order (fullscreen-app Spaces left out).
    /// Index + 1 is the "Desktop N" position on that display.
    static func userSpaces() -> [String: [UInt64]] {
        guard let connection, let displaySpaces,
              let displays = displaySpaces(connection())?.takeRetainedValue() as? [[String: Any]] else { return [:] }
        var result: [String: [UInt64]] = [:]
        for display in displays {
            guard var id = display["Display Identifier"] as? String,
                  let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            // With "Displays have separate Spaces" off, SkyLight reports a single display called "Main".
            if id == "Main", let main = Displays.current().first(where: { $0.x == 0 && $0.y == 0 }) { id = main.uuid }
            result[id] = spaces.filter { ($0["type"] as? Int) == 0 }
                .compactMap { ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value }
        }
        return result
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
}

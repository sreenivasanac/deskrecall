import Foundation

/// UserDefaults keys for the menu's toggles.
enum Keys {
    static let autoArrange = "autoArrange"
    static let askWhenUnsure = "askWhenUnsure"
}

/// Branding and tunables in one place.
enum Config {
    static let appName = "DeskRecall"
    static let bundleID = "com.sreenivasanac.deskrecall"
    static let menuBarSymbol = "rectangle.3.group"

    // TypeSafe Jev (decision model)
    static let jevEndpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let jevModel = "jev-latest"
    static let jevTimeout: TimeInterval = 8
    /// Below this confidence a Jev decision is treated as a conflict and the user is asked.
    static let jevMinConfidence = 0.5
    static let keychainService = bundleID
    static let keychainAccount = "typesafe-api-key"

    /// Wait this long after a display change before auto-arranging (macOS reshuffles windows itself first).
    static let displayChangeSettle: TimeInterval = 4
    /// Frames within this many points of the target are left alone.
    static let frameTolerance: CGFloat = 4

    static var profilesURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profiles.json")
    }
}

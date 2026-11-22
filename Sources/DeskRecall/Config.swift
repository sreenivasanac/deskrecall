import Foundation

/// UserDefaults keys for the menu's toggles.
enum Keys {
    static let autoArrange = "autoArrange"
    static let whenUnsure = "whenUnsure"            // an Unsure raw value
    static let preferred = "preferredProfiles"      // display set key -> id of the profile last used there
    static let onboarded = "onboarded"              // the Welcome pane has been finished
}

/// What to do with a window whose match is only a best guess (below `Config.matchFloor`/`matchMargin`, or Jev's `jevMinConfidence`).
enum Unsure: String, CaseIterable, Identifiable {
    case ask, guess, leave
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ask: "Ask me"
        case .guess: "Use the best guess"
        case .leave: "Leave the window where it is"
        }
    }
    static var current: Unsure { Unsure(rawValue: UserDefaults.standard.string(forKey: Keys.whenUnsure) ?? "") ?? .ask }
}

/// Branding and tunables in one place.
enum Config {
    static let appName = "DeskRecall"
    static let bundleID = "com.sreenivasanac.deskrecall"
    static let menuBarSymbol = "rectangle.3.group"
    static let website = URL(string: "https://deskrecall.pragnyalabs.com")!
    static let repository = URL(string: "https://github.com/sreenivasanac/deskrecall")!
    static let issues = repository.appendingPathComponent("issues/new")
    static let privacy = website.appendingPathComponent("privacy.html")
    static let terms = website.appendingPathComponent("terms.html")
    static let feedbackEmail = "sreenivasan.nitt@gmail.com"

    // The About pane
    static let author = "Sreenivasan AC"
    static let authorLinks: [(label: String, url: URL)] = [
        ("pragnyalabs.com", URL(string: "https://pragnyalabs.com/")!),
        ("LinkedIn", URL(string: "https://www.linkedin.com/in/sreenivasan-ac/")!),
        ("GitHub", URL(string: "https://github.com/sreenivasanac/")!),
        ("Email", URL(string: "mailto:\(feedbackEmail)")!),
    ]

    // TypeSafe Jev (decision model)
    static let jevEndpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let jevModel = "jev-latest"
    static let jevSignup = URL(string: "https://typesafe.ai")!     // where a key comes from
    static let jevTimeout: TimeInterval = 8
    /// Below this confidence a Jev decision is treated as a conflict and the user is asked.
    static let jevMinConfidence = 0.5
    // Telling an app's reopened windows apart on the Mac: shared title words and "already in its
    // saved place" add up to at most 1. A pair is sure from `matchFloor` up, if it beats every rival by `matchMargin`.
    static let titleWeight = 0.6, placeWeight = 0.4
    static let matchFloor = 0.25, matchMargin = 0.15
    static let keychainService = bundleID
    static let keychainAccount = "typesafe-api-key"

    /// Wait this long after a display change before auto-arranging (macOS reshuffles windows itself first).
    static let displayChangeSettle: TimeInterval = 4
    /// Frames within this many points of the target are left alone.
    static let frameTolerance: CGFloat = 4
    /// Looser, for saying "this window has moved": some apps round the size they are given
    /// (a terminal to whole character cells), and that must not read as a change.
    static let driftTolerance: CGFloat = 24
    /// The Dock animation has to finish before a restored window can be placed (nanoseconds).
    static let minimizeSettle: UInt64 = 700_000_000
    static let profilesWindowSize = CGSize(width: 980, height: 640)

    static var profilesURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profiles.json")
    }
}

import AppKit

/// What a bug report needs, as text the person can read before sending. Nothing is uploaded:
/// it goes to the clipboard, or into a GitHub issue or an email that they send themselves.
@MainActor
enum Diagnostics {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build" }

    /// Versions, displays, counts and settings. No window titles, app names, profile names or serial numbers.
    static func report() -> String {
        let displays = Displays.current(), desktops = Spaces.userSpaces(), profiles = Store.load()
        let defaults = UserDefaults.standard
        var arch = "Intel"
        #if arch(arm64)
        arch = "Apple Silicon"
        #endif
        var lines = [
            "\(Config.appName) \(version)",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(arch)",
            "Accessibility granted: \(Windows.trusted)",
            "Desktops readable: \(Spaces.available)",
        ]
        for d in displays {
            lines.append("Display: \(d.name), \(d.width)x\(d.height), \(d.builtin ? "built-in" : "external"), \(desktops[d.uuid]?.count ?? 0) desktops")
        }
        lines.append("Open windows seen: \(Windows.trusted ? String(Windows.capture().count) : "unknown")")
        lines.append("Profiles: \(profiles.count) (" + profiles.map { "\($0.windows.count) windows on \($0.displays.count) displays\($0.fits(displays) ? ", fits now" : "")" }.joined(separator: "; ") + ")")
        lines.append("Auto-arrange: \(defaults.bool(forKey: Keys.autoArrange)), when unsure: \(Unsure.current.rawValue), Jev key: \(Jev.hasKey), automatic updates: \(Updates.automatic)")
        return lines.joined(separator: "\n")
    }

    /// A new GitHub issue with the report filled in, for the person to complete and submit.
    static func reportBug() {
        var url = URLComponents(url: Config.issues, resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "body", value: "**What happened?**\n\n\n**What did you expect?**\n\n\n**Diagnostics** (no window titles or names)\n```\n\(report())\n```\n")]
        if let url = url.url { NSWorkspace.shared.open(url) }
    }

    static func sendFeedback() {
        var url = URLComponents()
        url.scheme = "mailto"
        url.path = Config.feedbackEmail
        url.queryItems = [URLQueryItem(name: "subject", value: "\(Config.appName) feedback"),
                          URLQueryItem(name: "body", value: "\n\n\(Config.appName) \(version), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")]
        if let url = url.url { NSWorkspace.shared.open(url) }
    }
}

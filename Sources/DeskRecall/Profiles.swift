import Foundation
import CoreGraphics

/// Where one window belongs in a profile. Frames are stored as fractions of the display so a
/// profile can be replayed on a similar display of a different resolution.
struct SavedWindow: Codable, Hashable {
    var bundleID: String
    var appName: String
    var title: String
    var display: Int          // index into Profile.displays
    var space: Int            // 1-based desktop position on that display; 0 = don't care
    var fx: Double, fy: Double, fw: Double, fh: Double
    var minimized: Bool?      // optional so profiles saved before this was recorded still load

    var isMinimized: Bool { minimized == true }

    func frame(on d: DisplayInfo) -> CGRect {
        CGRect(x: (Double(d.x) + fx * Double(d.width)).rounded(), y: (Double(d.y) + fy * Double(d.height)).rounded(),
               width: (fw * Double(d.width)).rounded(), height: (fh * Double(d.height)).rounded())
    }
}

/// A saved layout for one display setup.
struct Profile: Codable, Identifiable {
    var id = UUID()
    var name: String
    var savedAt = Date()
    var displays: [DisplayInfo]
    var windows: [SavedWindow]

    var setKey: String { Displays.setKey(displays) }

    /// Records where every open window is right now, minimized ones included.
    static func snapshot(name: String, displays: [DisplayInfo], windows: [LiveWindow], spaces: [String: [UInt64]]) -> Profile {
        let saved = windows.compactMap { w -> SavedWindow? in
            // The desktop decides the display when it belongs to exactly one (desktops are shared when
            // "Displays have separate Spaces" is off); otherwise the display holding most of the window.
            let owners = displays.indices.filter { w.spaces.count == 1 && (spaces[displays[$0].uuid] ?? []).contains(w.spaces[0]) }
            var index = owners.count == 1 ? owners[0] : nil
            if index == nil {
                index = displays.indices.max { area(w.frame, displays[$0].bounds) < area(w.frame, displays[$1].bounds) }
            }
            guard let index else { return nil }
            let d = displays[index]
            let position = w.spaces.count == 1 ? (spaces[d.uuid]?.firstIndex(of: w.spaces[0]).map { $0 + 1 } ?? 0) : 0
            return SavedWindow(bundleID: w.bundleID, appName: w.appName, title: w.title, display: index, space: position,
                               fx: (w.frame.minX - Double(d.x)) / Double(d.width), fy: (w.frame.minY - Double(d.y)) / Double(d.height),
                               fw: w.frame.width / Double(d.width), fh: w.frame.height / Double(d.height),
                               minimized: w.minimized ? true : nil)
        }
        return Profile(name: name, displays: displays, windows: saved)
    }

    private static func area(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }
}

enum Store {
    static func load() -> [Profile] {
        guard let data = try? Data(contentsOf: Config.profilesURL) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let profiles = try? decoder.decode([Profile].self, from: data) { return profiles }
        // Unreadable (hand-edited, or written by a newer version): set it aside so the next save can't erase it.
        let aside = Config.profilesURL.deletingLastPathComponent().appendingPathComponent("profiles.unreadable.json")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: Config.profilesURL, to: aside)
        return []
    }

    /// False when the file could not be written; the previous file is then untouched (atomic write).
    @discardableResult
    static func save(_ profiles: [Profile]) -> Bool {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(profiles).write(to: Config.profilesURL, options: .atomic)) != nil
    }

    /// Several profiles can be saved on the same monitors (say "Work" and "Evening"). Arrange then
    /// uses the one last saved or applied there, so it stays predictable.
    static func preferred(for setKey: String) -> UUID? {
        (UserDefaults.standard.dictionary(forKey: Keys.preferred)?[setKey] as? String).flatMap { UUID(uuidString: $0) }
    }
    static func prefer(_ profile: Profile) {
        var all = UserDefaults.standard.dictionary(forKey: Keys.preferred) ?? [:]
        all[profile.setKey] = profile.id.uuidString
        UserDefaults.standard.set(all, forKey: Keys.preferred)
    }
}

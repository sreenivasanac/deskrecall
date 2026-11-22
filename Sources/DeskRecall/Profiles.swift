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
    // What identifies the window beyond its title. All optional: older profiles have none of it.
    var windowID: UInt32?     // the same window for as long as it stays open (ids restart at login)
    var pid: Int32?           // ...and only within the same run of its app, which makes the id trustworthy
    var document: String?     // the file or URL the window shows, for apps that report one

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

    /// nil when the profile was not saved on the monitors connected now. Otherwise how sure it is
    /// that these are the very same units, which picks between profiles saved on look-alike setups
    /// (the same monitor model at home and at the office).
    /// ponytail: a plain point count; if two places share model, date, macOS id and arrangement
    /// they cannot be told apart and the profile last used wins.
    func closeness(to current: [DisplayInfo]) -> Int? {
        guard setKey == Displays.setKey(current) else { return nil }
        var score = 0
        for (i, now) in Displays.pair(displays, with: current) {
            let then = displays[i]
            if let a = then.made, let b = now.made, a != b { return nil }    // same model, another unit
            if then.uuid == now.uuid { score += 2 }                          // macOS recognises the monitor
            if then.bounds == now.bounds { score += 1 }                      // same arrangement and resolution
        }
        return score
    }
    func fits(_ current: [DisplayInfo]) -> Bool { closeness(to: current) != nil }

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
                               minimized: w.minimized ? true : nil, windowID: w.id, pid: w.pid, document: w.document)
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
    static func preferred(for key: String) -> UUID? {
        (UserDefaults.standard.dictionary(forKey: Keys.preferred)?[key] as? String).flatMap { UUID(uuidString: $0) }
    }
    /// The profiles saved on these very monitors that fit them best; several when they tie.
    static func candidates(_ profiles: [Profile], for displays: [DisplayInfo]) -> [Profile] {
        let scored = profiles.compactMap { p in p.closeness(to: displays).map { (profile: p, score: $0) } }
        let best = scored.map(\.score).max()
        return scored.filter { $0.score == best }.map(\.profile)
    }
    /// The layout this display setup is on: the fitting profile last saved or applied on these very
    /// monitors, whatever its score (the user chose it); failing that the one best fit, or among
    /// tied fits the one a version before 0.5 recorded for this kind of setup.
    static func current(_ profiles: [Profile], for displays: [DisplayInfo]) -> Profile? {
        if let id = preferred(for: placeKey(displays)), let chosen = profiles.first(where: { $0.id == id && $0.fits(displays) }) { return chosen }
        let same = candidates(profiles, for: displays)
        return same.count == 1 ? same[0] : same.first { $0.id == preferred(for: Displays.setKey(displays)) }
    }
    /// The connected monitors as macOS itself tells them apart, so a choice made at home does not
    /// carry over to the same monitor model at the office.
    private static func placeKey(_ displays: [DisplayInfo]) -> String {
        Displays.setKey(displays) + "|" + displays.map(\.uuid).sorted().joined(separator: ",")
    }
    static func prefer(_ profile: Profile, on displays: [DisplayInfo]) {
        var all = UserDefaults.standard.dictionary(forKey: Keys.preferred) ?? [:]
        all[placeKey(displays)] = profile.id.uuidString
        UserDefaults.standard.set(all, forKey: Keys.preferred)
    }
}

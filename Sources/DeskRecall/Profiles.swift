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

    /// Records where every open window is right now.
    static func snapshot(name: String, displays: [DisplayInfo], windows: [LiveWindow], spaces: [String: [UInt64]]) -> Profile {
        let saved = windows.compactMap { w -> SavedWindow? in
            // The Space decides the display when known; otherwise the display holding most of the window.
            var index = displays.firstIndex { d in w.spaces.count == 1 && (spaces[d.uuid] ?? []).contains(w.spaces[0]) }
            if index == nil {
                index = displays.indices.max { area(w.frame, displays[$0].bounds) < area(w.frame, displays[$1].bounds) }
            }
            guard let index else { return nil }
            let d = displays[index]
            let position = w.spaces.count == 1 ? (spaces[d.uuid]?.firstIndex(of: w.spaces[0]).map { $0 + 1 } ?? 0) : 0
            return SavedWindow(bundleID: w.bundleID, appName: w.appName, title: w.title, display: index, space: position,
                               fx: (w.frame.minX - Double(d.x)) / Double(d.width), fy: (w.frame.minY - Double(d.y)) / Double(d.height),
                               fw: w.frame.width / Double(d.width), fh: w.frame.height / Double(d.height))
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
        return (try? decoder.decode([Profile].self, from: data)) ?? []
    }

    static func save(_ profiles: [Profile]) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(profiles).write(to: Config.profilesURL, options: .atomic)
    }
}

import AppKit
import CoreGraphics

/// One physical display, described by everything macOS exposes that can tell monitors apart.
struct DisplayInfo: Codable, Hashable {
    var name: String          // e.g. "LEN T27h-30", "Built-in Retina Display"
    var vendor: UInt32
    var model: UInt32
    var serial: UInt32        // 0 on many cheap monitors
    var builtin: Bool
    var uuid: String          // matches the "Display Identifier" SkyLight uses for Spaces
    var x: Int, y: Int        // top-left in global (CG) coordinates: the arrangement
    var width: Int, height: Int

    var bounds: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    /// Identity of the hardware, ignoring where it sits and which scaled resolution it runs at
    /// (frames are stored as fractions, so a resolution change needs no new profile). Two profiles
    /// with equal sorted hardware keys were saved on the same set of monitors.
    var hardwareKey: String { "\(vendor)-\(model)-\(serial)-\(builtin ? "b" : "e")" }

    /// Everything Jev needs to compare monitors, as one line.
    var summary: String {
        "\(name) (\(builtin ? "built-in" : "external"), \(width)x\(height), at x=\(x) y=\(y), vendor \(vendor) model \(model) serial \(serial))"
    }
}

enum Displays {
    /// Currently connected displays, left to right then top to bottom.
    static func current() -> [DisplayInfo] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let names = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { s -> (CGDirectDisplayID, String)? in
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return (id, s.localizedName)
        })
        return ids.map { id in
            let b = CGDisplayBounds(id)
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? ""
            let builtin = CGDisplayIsBuiltin(id) != 0
            let name = names[id].flatMap { $0.isEmpty ? nil : $0 } ?? (builtin ? "Built-in display" : "External display")
            return DisplayInfo(name: name, vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                               serial: CGDisplaySerialNumber(id), builtin: builtin, uuid: uuid,
                               x: Int(b.minX), y: Int(b.minY), width: Int(b.width), height: Int(b.height))
        }.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
    }

    static func setKey(_ displays: [DisplayInfo]) -> String {
        displays.map(\.hardwareKey).sorted().joined(separator: "|")
    }
}

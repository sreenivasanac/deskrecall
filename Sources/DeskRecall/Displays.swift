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
    var made: String?         // manufacture date from the monitor itself, e.g. "2019w39"; nil when unknown or saved before 0.3

    var bounds: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    /// Identity of the hardware, ignoring where it sits and which scaled resolution it runs at
    /// (frames are stored as fractions, so a resolution change needs no new profile). Two profiles
    /// with equal sorted hardware keys were saved on the same set of monitors.
    var hardwareKey: String { "\(vendor)-\(model)-\(serial)-\(builtin ? "b" : "e")" }

    /// Everything that tells monitors apart, as one line (for `--dump`).
    var summary: String {
        "\(name) (\(builtin ? "built-in" : "external"), \(width)x\(height), at x=\(x) y=\(y), vendor \(vendor) model \(model) serial \(serial)"
            + (made.map { ", made \($0)" } ?? "") + ")"
    }
}

enum Displays {
    // The manufacture date is only in CoreDisplay's private info dictionary; without it `made` stays nil.
    private typealias InfoDictionary = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
    private static let infoDictionary = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_NOW)
        .flatMap { dlsym($0, "CoreDisplay_DisplayCreateInfoDictionary") }.map { unsafeBitCast($0, to: InfoDictionary.self) }

    /// Many monitors carry a placeholder serial number, so two units of one model look alike. The
    /// week and year they were made is the one further fact the monitor reports about itself.
    private static func made(_ id: CGDirectDisplayID) -> String? {
        guard let info = infoDictionary?(id)?.takeRetainedValue() as? [String: Any],
              let year = info["DisplayYearManufacture"] as? Int, let week = info["DisplayWeekManufacture"] as? Int,
              year > 0 else { return nil }
        return "\(year)w\(week)"
    }

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
                               x: Int(b.minX), y: Int(b.minY), width: Int(b.width), height: Int(b.height), made: made(id))
        }.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
    }

    static func setKey(_ displays: [DisplayInfo]) -> String {
        displays.map(\.hardwareKey).sorted().joined(separator: "|")
    }

    /// Which connected display each saved one is, for a profile saved on these monitors. Among
    /// identical twins, first the one macOS itself recognises (its persistent UUID), then left to
    /// right: both lists are sorted that way.
    static func pair(_ saved: [DisplayInfo], with current: [DisplayInfo]) -> [Int: DisplayInfo] {
        var free = current, map: [Int: DisplayInfo] = [:]
        for sameUUID in [true, false] {
            for (i, d) in saved.enumerated() where map[i] == nil {
                if let j = free.firstIndex(where: { $0.hardwareKey == d.hardwareKey && (!sameUUID || $0.uuid == d.uuid) }) {
                    map[i] = free.remove(at: j)
                }
            }
        }
        return map
    }
}

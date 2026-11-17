// Draws the app icon and writes Resources/AppIcon.icns plus a PNG for the website.
//   swift scripts/make-icon.swift        (run from the repo root; needs iconutil, which ships with macOS)
import AppKit

/// A desk seen from above: one tall window and two stacked ones, the layout the app puts back.
func draw(_ side: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let u = side / 1024                                    // Apple's icon grid: an 824 pt tile on a 1024 pt canvas
    let tile = NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * u, yRadius: 185 * u)
    NSGradient(starting: NSColor(red: 0.20, green: 0.25, blue: 0.62, alpha: 1), ending: NSColor(red: 0.09, green: 0.10, blue: 0.27, alpha: 1))!
        .draw(in: shape, angle: -90)
    func window(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: x * u, y: y * u, width: w * u, height: h * u), xRadius: 34 * u, yRadius: 34 * u).fill()
    }
    window(232, 262, 262, 500, NSColor(white: 1, alpha: 0.95))
    window(530, 532, 262, 230, NSColor(white: 1, alpha: 0.55))
    window(530, 262, 262, 230, NSColor(red: 1.0, green: 0.72, blue: 0.30, alpha: 1))
    NSGraphicsContext.current = nil
    return rep
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try draw(CGFloat(points * scale)).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}
let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try tool.run(); tool.waitUntilExit()
try draw(512).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "site/icon.png"))
print(tool.terminationStatus == 0 ? "wrote Resources/AppIcon.icns and site/icon.png" : "iconutil failed")

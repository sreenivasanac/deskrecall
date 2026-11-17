import SwiftUI

/// The app's window: a Profiles pane showing every saved profile as a picture of its displays and
/// desktops, and a Settings pane. Profiles are view only by design: a layout is changed by
/// arranging the real windows and pressing Update.
struct ProfilesView: View {
    @ObservedObject var app: AppDelegate
    @State private var selection: Profile.ID?

    /// The picked profile; before any pick, the one made for the displays connected now.
    private var selected: Profile? {
        app.profiles.first { $0.id == selection } ?? app.matching.first ?? app.profiles.first
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Pane", selection: $app.pane) {
                ForEach(AppDelegate.Pane.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().padding(.vertical, 10)
            Divider()
            if !app.trusted { permissionBanner }
            if app.pane == .settings { SettingsPane(app: app) } else { profilesPane }
        }
        .frame(minWidth: 760, minHeight: 480)
        // An app without a Dock icon has no main menu, so ⌘W needs a home of its own.
        .background(Button("") { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w").opacity(0))
    }

    @ViewBuilder private var profilesPane: some View {
        if app.profiles.isEmpty {
            emptyState
        } else {
            HStack(spacing: 0) {
                List(app.profiles, selection: Binding(get: { selected?.id }, set: { selection = $0 })) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).lineLimit(2)
                        Text((p.fits(app.displays) ? "Connected now · " : "") + "\(p.windows.count) windows")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.sidebar)
                .frame(width: 230)
                Divider()
                if let profile = selected { ProfileDetail(app: app, profile: profile).id(profile.id) }
            }
        }
        Divider()
        HStack {
            if app.busy { ProgressView().controlSize(.small) }
            Text(app.status).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            Spacer()
            Button("Save Current Layout as New Profile…") { app.saveNew() }
        }
        .padding(10)
    }

    private var permissionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            Text("\(Config.appName) needs Accessibility access to read window titles and move windows. It is the only permission it asks for.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Grant Access…") { Windows.requestTrust() }
        }
        .padding(12)
        .background(Color.orange.opacity(0.15))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: Config.menuBarSymbol).font(.system(size: 44)).foregroundStyle(.secondary)
            Text("No profiles yet").font(.title2.bold())
            Text("Put your windows where you want them, on each display and desktop, and minimize the ones you want out of the way. Then save. Do this once for every display setup you use; Arrange in the menu bar puts everything back.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
            Button("Save Current Layout as New Profile…") { app.saveNew() }
                .buttonStyle(.borderedProminent).padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

/// One profile: what it was saved on, the actions, and a miniature of every desktop it uses.
private struct ProfileDetail: View {
    @ObservedObject var app: AppDelegate
    let profile: Profile
    @State private var hovered: Int?      // index into profile.windows, highlighted in both map and list

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                ForEach(profile.displays.indices, id: \.self) { displaySection($0) }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            summary
            Spacer(minLength: 0)
            if profile.displays.count > 1 { ArrangementMap(displays: profile.displays) }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(profile.name).font(.title2.bold())
            Text("Saved \(profile.savedAt.formatted(date: .abbreviated, time: .shortened)) · \(profile.windows.count) windows"
                 + (minimizedCount > 0 ? ", \(minimizedCount) minimized" : ""))
                .foregroundStyle(.secondary)
            if profile.fits(app.displays) {
                Label("Made for the displays connected now. Arrange uses it as saved.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label("Made for a different display setup. Applied here, it is adapted to the displays connected now.", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Apply Now") { app.arrange(interactive: true, forced: profile) }.buttonStyle(.borderedProminent)
                Button("Update with Current Layout…") { app.update(profile) }
                Button("Rename…") { app.rename(profile) }
                Button("Delete…", role: .destructive) { app.delete(profile) }
            }
            .disabled(app.busy)
            .padding(.top, 4)
        }
    }

    private var minimizedCount: Int { profile.windows.filter(\.isMinimized).count }

    private func displaySection(_ index: Int) -> some View {
        let display = profile.displays[index]
        let windows = profile.windows.indices.filter { profile.windows[$0].display == index }
        // Desktops 1...highest used, so an empty one in between still shows its place; 0 = not tied to one desktop.
        let desktops = (windows.contains { profile.windows[$0].space == 0 } ? [0] : [])
            + Array(1...max(1, windows.map { profile.windows[$0].space }.max() ?? 1))
        return VStack(alignment: .leading, spacing: 10) {
            // String(...) keeps SwiftUI from formatting the numbers as "1,920".
            Label(String("\(display.name) · \(display.width)×\(display.height)"), systemImage: display.builtin ? "laptopcomputer" : "display")
                .font(.headline)
            // What tells this monitor from another of the same model.
            if let made = display.made, !display.builtin {
                Text(String("Serial \(display.serial) · made \(made.replacingOccurrences(of: "w", with: ", week "))"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
                ForEach(desktops, id: \.self) { desktop in
                    DesktopCard(title: desktop == 0 ? "Every desktop" : "Desktop \(desktop)",
                                aspect: CGFloat(display.width) / CGFloat(max(display.height, 1)),
                                windows: windows.filter { profile.windows[$0].space == desktop }.map { ($0, profile.windows[$0]) },
                                hovered: $hovered)
                }
            }
        }
    }
}

/// The profile's displays as they sit next to each other, like the Arrange picture in System Settings.
private struct ArrangementMap: View {
    let displays: [DisplayInfo]

    var body: some View {
        let all = displays.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
        let scale = min(200 / max(all.width, 1), 96 / max(all.height, 1))
        ZStack(alignment: .topLeading) {
            ForEach(displays.indices, id: \.self) { i in
                let d = displays[i]
                RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.15))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor.opacity(0.6)))
                    .overlay(Text(d.builtin ? "Built-in" : d.name).font(.system(size: 9)).lineLimit(1).padding(3))
                    .frame(width: CGFloat(d.width) * scale - 2, height: CGFloat(d.height) * scale - 2)
                    .offset(x: (CGFloat(d.x) - all.minX) * scale, y: (CGFloat(d.y) - all.minY) * scale)
            }
        }
        .frame(width: all.width * scale, height: all.height * scale, alignment: .topLeading)
        .help("How these displays were arranged when the profile was saved")
    }
}

/// A desktop drawn to scale, with the list of its windows underneath.
private struct DesktopCard: View {
    let title: String
    let aspect: CGFloat
    let windows: [(index: Int, window: SavedWindow)]
    @Binding var hovered: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06))
                .aspectRatio(aspect, contentMode: .fit)
                .overlay(GeometryReader { geo in
                    // Largest first, so a small window is never hidden under a big one.
                    let shown = windows.filter { !$0.window.isMinimized }.sorted { $0.window.fw * $0.window.fh > $1.window.fw * $1.window.fh }
                    ForEach(Array(shown.enumerated()), id: \.element.index) { order, entry in
                        let w = entry.window, on = hovered == entry.index
                        // Windows sharing a corner would stack their icons: step each later one aside.
                        let twins = shown[..<order].filter { abs($0.window.fx - w.fx) < 0.05 && abs($0.window.fy - w.fy) < 0.05 }.count
                        RoundedRectangle(cornerRadius: 3).fill(tint(w).opacity(on ? 0.5 : 0.2))
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(tint(w), lineWidth: on ? 2 : 1))
                            .overlay(alignment: .topLeading) {
                                AppIcon(bundleID: w.bundleID).frame(width: 18, height: 18).padding(3).offset(x: CGFloat(twins) * 20)
                            }
                            .frame(width: max(w.fw * geo.size.width, 8), height: max(w.fh * geo.size.height, 8))
                            .offset(x: w.fx * geo.size.width, y: w.fy * geo.size.height)
                            .onHover { hovered = $0 ? entry.index : (hovered == entry.index ? nil : hovered) }
                            .help("\(w.appName): \(w.title)")
                    }
                })
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.18)))
            if windows.isEmpty { Text("No windows").font(.caption).foregroundStyle(.tertiary) }
            ForEach(windows, id: \.index) { entry in
                let w = entry.window
                HStack(spacing: 5) {
                    AppIcon(bundleID: w.bundleID).frame(width: 14, height: 14)
                    Text(w.appName).font(.caption.weight(.medium)).lineLimit(1).layoutPriority(1)
                    if w.title != w.appName { Text(w.title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    if w.isMinimized {
                        Text("minimized").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.1)))
                            .fixedSize()
                    }
                }
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(hovered == entry.index ? tint(w).opacity(0.25) : .clear))
                .onHover { hovered = $0 ? entry.index : (hovered == entry.index ? nil : hovered) }
            }
        }
    }

    /// A steady colour per app, so its windows are recognisable across desktops.
    private func tint(_ w: SavedWindow) -> Color {
        let hue = w.bundleID.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 360 }
        return Color(hue: Double(hue) / 360, saturation: 0.65, brightness: 0.8)
    }
}

/// The installed app's icon, or a placeholder when the app is no longer on this Mac.
private struct AppIcon: View {
    let bundleID: String
    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else {
            Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
        }
    }
}

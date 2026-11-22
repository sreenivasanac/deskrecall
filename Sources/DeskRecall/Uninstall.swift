import AppKit
import ServiceManagement

/// Uninstall (Settings and the Help menu): takes back everything the app has put on this Mac, then
/// moves the app itself to the Trash. The saved layouts are the one thing a person made here, so
/// they are the one thing that can be kept, for a later reinstall.
@MainActor
enum Uninstall {
    /// The files the app, and macOS on its behalf, have written in the user's Library.
    nonisolated static func leftovers(keepLayouts: Bool) -> [URL] {
        let files = FileManager.default
        let library = files.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        var found = ["Caches/\(Config.bundleID)",                                  // the update check and downloaded updates
                     "HTTPStorages/\(Config.bundleID)", "HTTPStorages/\(Config.bundleID).binarycookies",
                     "Saved Application State/\(Config.bundleID).savedState",
                     "Preferences/\(Config.bundleID).plist"].map { library.appendingPathComponent($0) }
        // macOS keeps one small record per app here for its own crash reports.
        let crashes = library.appendingPathComponent("Application Support/CrashReporter")
        found += ((try? files.contentsOfDirectory(at: crashes, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(Config.appName + "_") }
        if !keepLayouts { found.append(Config.profilesURL.deletingLastPathComponent()) }
        return found
    }

    static func run() {
        let files = FileManager.default
        let folder = Config.profilesURL.deletingLastPathComponent()
        let layouts = Store.load().count
        let title = "Uninstall \(Config.appName)?"
        let message = "This moves \(Config.appName) to the Trash and removes its settings, its cache, its launch-at-login entry, its Accessibility permission and the Jev key, if you saved one."
        var deleteLayouts = true
        // Asked whenever the folder holds anything, not only when profiles load: a file set aside as
        // unreadable is still somebody's layouts.
        if (try? files.contentsOfDirectory(atPath: folder.path))?.isEmpty == false {
            guard let ticked = UI.confirm(title, message + "\n\nYour saved layouts are kept unless you tick the box, so they are there if you install \(Config.appName) again.",
                                          ok: "Uninstall", option: layouts > 0 ? "Also delete my \(layouts) saved layout\(layouts == 1 ? "" : "s")" : "Also delete my saved layouts") else { return }
            deleteLayouts = ticked
        } else {
            guard UI.confirm(title, message, ok: "Uninstall") else { return }
        }

        // Whatever could not be removed is named at the end, never passed over in silence.
        var left: [String] = []
        try? SMAppService.mainApp.unregister()
        if !Jev.remove() { left.append("the Jev key: the item “\(Config.keychainService)” in Keychain Access") }
        for url in leftovers(keepLayouts: !deleteLayouts) {
            try? files.removeItem(at: url)
            if files.fileExists(atPath: url.path) { left.append(url.path) }
        }
        // The Accessibility grant is macOS's to hold; tccutil is how an app hands its own back.
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "Accessibility", Config.bundleID]
        reset.standardOutput = FileHandle.nullDevice
        reset.standardError = FileHandle.nullDevice
        let ran = (try? reset.run()) != nil
        if ran { reset.waitUntilExit() }
        if !ran || reset.terminationStatus != 0 {
            left.append("the Accessibility permission: System Settings → Privacy & Security → Accessibility")
        }

        // A running app can be moved to the Trash. It fails where the folder isn't the user's to change,
        // and for a copy macOS runs from a read-only location (opened straight from Downloads).
        let bundle = Bundle.main.bundleURL
        let trashed = bundle.pathExtension == "app" && (try? FileManager.default.trashItem(at: bundle, resultingItemURL: nil)) != nil
        let kept = deleteLayouts ? "" : "\n\nYour saved layouts are still in \(folder.path)."
        let rest = left.isEmpty ? "everything else it stored is gone." : "the rest is gone except for these, which could not be removed and are yours to delete:\n• " + left.joined(separator: "\n• ")
        _ = UI.confirm(trashed ? "\(Config.appName) has been uninstalled" : "Almost done: drag \(Config.appName) to the Trash",
                       (trashed ? "The app is in the Trash and " + rest
                                : "The app itself could not be moved to the Trash; drag it there from your Applications folder. Of what it stored, " + rest) + kept,
                       ok: "Quit", cancel: nil)
        if !trashed { NSWorkspace.shared.activateFileViewerSelecting([bundle]) }
        // Last, so nothing shown above writes a setting back.
        UserDefaults.standard.removePersistentDomain(forName: Config.bundleID)
        NSApp.terminate(nil)
    }
}

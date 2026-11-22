import Foundation
import Sparkle

/// In-app updates through Sparkle: the app reads a feed on the website, and a newer version is
/// downloaded, checked against the update key in Info.plist and installed in place.
@MainActor
enum Updates {
    // ponytail: Sparkle's standard window. A menu bar app can't always bring a scheduled update
    // alert to the front; add Sparkle's "gentle reminders" if people miss updates.
    private static var controller: SPUStandardUpdaterController?
    /// False in a bare binary (`swift run`), which has no feed to read, and in the command-line
    /// modes, which never start the updater.
    static var available: Bool { controller != nil }

    /// Called once when the menu bar app launches; from then on Sparkle checks on its own schedule.
    static func start() {
        guard controller == nil, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }
    static func check() { controller?.checkForUpdates(nil) }
    static var automatic: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
}

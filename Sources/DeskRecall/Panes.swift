import SwiftUI

/// First run: the three things to do, in order, and the settings as they stand. Nothing here
/// blocks: every step can be skipped and found again in Settings.
struct WelcomePane: View {
    @ObservedObject var app: AppDelegate
    @AppStorage(Keys.autoArrange) private var autoArrange = true
    @AppStorage(Keys.onboarded) private var onboarded = false
    @State private var automaticUpdates = Updates.automatic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to \(Config.appName)").font(.largeTitle.bold())
                    Text("It lives in the menu bar and puts your windows back where they belong: the right display, the right desktop, the right size.")
                        .foregroundStyle(.secondary)
                }
                step(1, "Allow Accessibility", "The only permission the app uses. It lets it read window titles and move windows.", done: app.trusted) {
                    Button("Grant Access…") { Windows.requestTrust() }
                }
                step(2, "Save your first layout", "Put your windows where you like them, on each display and desktop, then save. Do this once for every display setup you use.", done: !app.profiles.isEmpty) {
                    Button("Save Current Layout…") { app.saveNew() }.disabled(!app.trusted)
                }
                step(3, "Optional: add a TypeSafe Jev key", "Jev is a decision model that settles unclear cases, such as which of an app's five windows is which. With a key, details of your displays, the names of the apps and profiles involved, and the titles of the windows in question are sent to \(Config.jevEndpoint.host ?? "TypeSafe"). Without one nothing is sent and the app still works.", done: app.hasJevKey) {
                    Button("Add Key…") { app.setJevKey() }
                    Link("Get a key", destination: Config.jevSignup)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("How it is set up").font(.headline)
                    Toggle("Arrange automatically when displays change", isOn: $autoArrange)
                    Toggle("Launch at login", isOn: Binding(get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))
                    if Updates.available {
                        Toggle("Check for updates automatically", isOn: $automaticUpdates)
                            .onChange(of: automaticUpdates) { Updates.automatic = automaticUpdates }
                    }
                    Text("You can change these at any time in Settings.").font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Done") { onboarded = true; app.pane = .profiles }.buttonStyle(.borderedProminent)
                    Link("Privacy", destination: Config.privacy)
                }
            }
            .padding(28)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func step(_ number: Int, _ title: String, _ text: String, done: Bool, @ViewBuilder actions: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle").font(.title2)
                .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !done { HStack { actions() } }
            }
        }
    }
}

/// Who made it, where it lives, and the ways to get help or send word back.
struct AboutPane: View {
    @ObservedObject var app: AppDelegate

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text(Config.appName).font(.title.bold())
            Text("Version \(Diagnostics.version)").foregroundStyle(.secondary)
            Text("© 2026 \(Config.author) · MIT licence").font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                ForEach(Config.authorLinks, id: \.label) { Link($0.label, destination: $0.url) }
            }
            Divider().frame(width: 320).padding(.vertical, 6)
            HStack(spacing: 16) {
                Link("Website", destination: Config.website)
                Link("Source code", destination: Config.repository)
                Link("Privacy", destination: Config.privacy)
                Link("Terms", destination: Config.terms)
            }
            HStack {
                if Updates.available { Button("Check for Updates…") { Updates.check() } }
                Button("Report a Bug…") { Diagnostics.reportBug() }
                Button("Send Feedback…") { Diagnostics.sendFeedback() }
                Button("Copy Diagnostics") { app.copyDiagnostics() }
            }
            .padding(.top, 6)
            Text("Diagnostics list versions, displays and settings, with no window titles or names. Report a Bug passes them to GitHub when it opens the issue page; nothing else leaves your Mac.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

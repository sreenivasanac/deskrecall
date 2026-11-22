import SwiftUI

/// The Settings pane of the window. Switches write straight to UserDefaults, which the arranger
/// and the menu read each time they need them.
struct SettingsPane: View {
    @ObservedObject var app: AppDelegate
    @AppStorage(Keys.autoArrange) private var autoArrange = true
    @AppStorage(Keys.whenUnsure) private var whenUnsure = Unsure.ask
    @State private var automaticUpdates = Updates.automatic

    var body: some View {
        Form {
            Section {
                Toggle("Arrange automatically when displays change", isOn: $autoArrange)
                Picker("When unsure which window is which", selection: $whenUnsure) {
                    ForEach(Unsure.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Arranging")
            } footer: {
                note("An app that was quit and reopened, with several windows whose titles have since changed, can leave \(Config.appName) unsure which is which. It goes by the words the titles share and by where the windows sit. Windows it is sure about are always placed. When it arranges on its own after a display change there is nobody to ask, so “Ask me” leaves those windows where they are.")
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))
            }

            Section {
                LabeledContent("Accessibility") {
                    if app.trusted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant Access…") { Windows.requestTrust() }
                    }
                }
            } header: {
                Text("Permission")
            } footer: {
                note("The only permission \(Config.appName) uses. It lets the app read window titles and move windows.")
            }

            Section {
                LabeledContent("API key") {
                    HStack {
                        Text(app.hasJevKey ? "Saved in your login keychain" : "None").foregroundStyle(.secondary)
                        Button(app.hasJevKey ? "Change…" : "Add…") { app.setJevKey() }
                        if !app.hasJevKey { Link("Get a key", destination: Config.jevSignup) }
                    }
                }
            } header: {
                Text("TypeSafe Jev (optional)")
            } footer: {
                note("\(Config.appName) works without this, and nothing about your windows leaves your Mac. Jev is a decision model that gives a second opinion on the one case above: reopened windows that titles and positions cannot tell apart. With a key, for those windows only, the window titles and the names of their app, the profile and its displays are sent to \(Config.jevEndpoint.host ?? "TypeSafe").")
            }

            if Updates.available {
                Section {
                    Toggle("Check for updates automatically", isOn: $automaticUpdates)
                        .onChange(of: automaticUpdates) { Updates.automatic = automaticUpdates }
                    LabeledContent("Version \(Diagnostics.version)") { Button("Check Now…") { Updates.check() } }
                } header: {
                    Text("Updates")
                } footer: {
                    note("About once a day \(Config.appName) asks \(Config.website.host ?? "its website") whether a newer version exists. Nothing about you or your windows is sent.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 640)                 // a form stretched across the whole window is hard to read
        .frame(maxWidth: .infinity)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}

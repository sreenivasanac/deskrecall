import SwiftUI

/// The Settings pane of the window. Switches write straight to UserDefaults, which the arranger
/// and the menu read each time they need them.
struct SettingsPane: View {
    @ObservedObject var app: AppDelegate
    @AppStorage(Keys.autoArrange) private var autoArrange = true
    @AppStorage(Keys.whenUnsure) private var whenUnsure = Unsure.ask

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
                note("An app with several windows whose titles have changed can leave \(Config.appName) unsure which is which. Windows it is sure about are always placed. When it arranges on its own after a display change there is nobody to ask, so “Ask me” leaves those windows where they are.")
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
                    }
                }
            } header: {
                Text("TypeSafe Jev")
            } footer: {
                note("Jev is the decision model that settles the unclear cases: which profile suits a new display setup, which display stands in for a missing one, which window is which. For those questions the names of your displays and the titles of the windows in question are sent to \(Config.jevEndpoint.host ?? "TypeSafe"). Without a key nothing is sent, and same-app windows are paired in order.")
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build")
                Link("Website", destination: Config.website)
                Link("Source code on GitHub", destination: Config.repository)
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

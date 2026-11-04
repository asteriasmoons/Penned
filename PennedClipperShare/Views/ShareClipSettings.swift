import SwiftUI

/// Preferences and connected-account information for the Share Extension.
struct ShareClipSettings: View {
    @AppStorage("pennedShareClipperTheme") private var selectedTheme = "system"
    let connection: ClipperConnection?
    let onRefreshConnection: () -> Void

    private var themeSelection: Binding<String> {
        Binding(get: { selectedTheme }, set: { selectedTheme = $0 })
    }

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: themeSelection) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }

            Section("Connected Account") {
                if let connection {
                    LabeledContent("Account", value: connection.accountName)
                    LabeledContent("Spaces", value: "\(connection.spaces.count)")
                } else {
                    Text("Penned is not connected")
                        .foregroundStyle(.secondary)
                }

                Button("Refresh Connection", action: onRefreshConnection)
            }

            Section {
                Link("Manage Account in Penned", destination: URL(string: "penned://clipper/connect")!)
            }
        }
        .navigationTitle("Clipper Settings")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(selectedTheme == "light" ? .light : selectedTheme == "dark" ? .dark : nil)
    }
}

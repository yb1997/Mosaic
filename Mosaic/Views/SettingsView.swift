import SwiftUI

/// App settings. Wallpapers themselves are picked in the menu bar panel.
struct SettingsView: View {
    @Environment(LoginItem.self) private var loginItem

    var body: some View {
        Form {
            Section {
                Toggle("Open at Login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.set($0) }))
                if loginItem.needsApproval {
                    LabeledContent("Waiting for approval in Login Items") {
                        Button("Open System Settings…") { loginItem.openSystemSettings() }
                            .buttonStyle(.glass)
                    }
                }
                if let error = loginItem.error {
                    Text(error).foregroundStyle(.red)
                }
            } footer: {
                Text("Lock screen images show while the Mac is locked and switch back when you unlock.")
            }

            ProfileSettingsSection()

            UpdateSettingsSection()
        }
        .formStyle(.grouped)
        // A grouped Form scrolls by default and reports a tiny height; size the window to the content instead.
        .scrollDisabled(true)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { loginItem.refresh() }
    }
}

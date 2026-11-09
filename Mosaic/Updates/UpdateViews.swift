import SwiftUI

/// The action and status text an update row shows, shared by the menu banner and Settings.
@MainActor
private struct UpdateStatus {
    let service = UpdateService.shared
    let installer = UpdateInstaller.shared

    /// Installing in place needs the release's DMG and a copy that may replace itself.
    var canInstall: Bool { service.dmgURL != nil && installer.unavailableReason == nil }

    var isBusy: Bool { service.isChecking || installer.isBusy }

    var isError: Bool {
        if case .failed = installer.state { return true }
        return service.lastCheckFailed
    }

    /// nil when there's nothing worth saying (up to date and never checked by hand).
    func text(showUpToDate: Bool) -> String? {
        switch installer.state {
        case .downloading(let fraction): return "Downloading update… \(Int(fraction * 100))%"
        case .verifying: return "Checking the update…"
        case .installing: return "Installing…"
        case .relaunching: return "Restarting Mosaic…"
        case .failed(let message): return message
        case .idle: break
        }
        if service.isChecking { return "Checking…" }
        if service.hasUpdate, let latest = service.latestVersion {
            if service.dmgURL != nil, let reason = installer.unavailableReason { return reason }
            return "Version \(latest) is available"
        }
        if service.lastCheckFailed { return "Couldn’t reach GitHub. Try again later." }
        if showUpToDate, service.lastCheckDate != nil { return "Mosaic is up to date." }
        return nil
    }

    func install() {
        guard let dmg = service.dmgURL else { return }
        Task { await installer.install(from: dmg) }
    }
}

/// Shown in the menu panel only while a newer version is available.
struct UpdateBanner: View {
    private var status: UpdateStatus { UpdateStatus() }

    var body: some View {
        let status = status
        if status.service.hasUpdate {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.text(showUpToDate: false) ?? "")
                        .font(.caption)
                        .foregroundStyle(status.isError ? .red : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .downloading(let fraction) = status.installer.state {
                        ProgressView(value: fraction).controlSize(.small)
                    }
                }
                Spacer(minLength: 4)
                if status.isBusy {
                    ProgressView().controlSize(.small)
                } else if status.canInstall {
                    Button("Install") { status.install() }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                        .help("Download and install the new version, then restart Mosaic")
                } else {
                    Button("Download…") { status.service.openReleasePage() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }
            .padding(10)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
    }
}

/// The Updates section of the Settings window.
struct UpdateSettingsSection: View {
    @State private var checkedByHand = false
    private var status: UpdateStatus { UpdateStatus() }

    var body: some View {
        let status = status
        @Bindable var service = status.service
        Section("Software Update") {
            Toggle("Check for updates automatically", isOn: $service.checksAutomatically)
            LabeledContent {
                if status.isBusy {
                    ProgressView().controlSize(.small)
                } else if status.service.hasUpdate {
                    if status.canInstall {
                        Button("Install") { status.install() }
                            .buttonStyle(.glassProminent)
                    } else {
                        Button("Download…") { status.service.openReleasePage() }
                            .buttonStyle(.glass)
                    }
                } else {
                    Button("Check Now") {
                        checkedByHand = true
                        Task { await status.service.checkForUpdates() }
                    }
                    .buttonStyle(.glass)
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Version \(status.service.currentVersion)")
                    if let text = status.text(showUpToDate: checkedByHand) {
                        Text(text)
                            .font(.caption)
                            .foregroundStyle(status.isError ? .red : (status.service.hasUpdate ? .green : .secondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if case .downloading(let fraction) = status.installer.state {
                        ProgressView(value: fraction).controlSize(.small)
                    }
                }
            }
        }
    }
}

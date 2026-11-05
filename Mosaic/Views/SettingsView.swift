import SwiftUI

/// App settings. Wallpapers themselves are picked in the menu bar panel.
struct SettingsView: View {
    @Environment(LoginItem.self) private var loginItem
    @Environment(WallpaperStore.self) private var store
    @AppStorage(WallpaperFade.defaultsKey) private var fadesWallpaperChanges = true
    @AppStorage(VideoFormat.frameRateKey) private var frameRate = VideoFormat.standard.frameRate
    @AppStorage(VideoFormat.qualityKey) private var quality = VideoFormat.standard.quality
    @AppStorage(VideoFormat.pausesOnBatteryKey) private var pausesOnBattery = false
    @State private var storageUsed: Int64?

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
                Toggle("Fade Between Wallpapers", isOn: $fadesWallpaperChanges)
            } footer: {
                Text("Lock screen images show while the Mac is locked and switch back when you unlock.")
            }

            Section {
                Picker("Frame Rate", selection: $frameRate) {
                    ForEach(FrameRate.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                // Original quality keeps the source's frames too.
                .disabled(quality == .original)
                Picker("Quality", selection: $quality) {
                    ForEach(VideoQuality.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Pause on Battery Power", isOn: $pausesOnBattery)
                LabeledContent("Wallpapers use \(storageUsed.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.imagesDirectory])
                    }
                    .buttonStyle(.glass)
                }
            } header: {
                Text("Videos")
            } footer: {
                Text("New videos use these settings. Change one screen’s video from its tile’s menu. Videos are muted and pause while hidden, locked, asleep or in Low Power Mode.")
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
        .task { storageUsed = await store.storageUsed() }
    }
}

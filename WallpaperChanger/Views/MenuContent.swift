import SwiftUI

/// The menu bar panel: each screen's desktop and lock screen images, editable in place.
struct MenuContent: View {
    @Environment(WallpaperStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(store.displays) { display in
                VStack(alignment: .leading, spacing: 6) {
                    Label(display.name, systemImage: display.isMain ? "laptopcomputer" : "display")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 8) {
                        ForEach(Slot.allCases, id: \.self) { slot in
                            WallpaperTile(display: display, slot: slot)
                                .frame(width: 136, height: 85)
                        }
                    }
                    Toggle(isOn: Binding(
                        get: { store.wallpapers(for: display).lockSameAsDesktop },
                        set: { store.setLockSameAsDesktop($0, display: display) }
                    )) {
                        Text("Lock screen same as desktop")
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
            }

            if let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GlassEffectContainer {
                HStack {
                    Button {
                        openWindow(id: "settings")
                        NSApp.activate()
                    } label: {
                        Label("Settings…", systemImage: "gearshape")
                    }
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                }
                .buttonStyle(.glass)
            }
        }
        .padding(14)
        .frame(width: 308)
    }
}

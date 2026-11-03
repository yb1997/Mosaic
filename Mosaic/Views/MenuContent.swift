import SwiftUI

/// The menu bar panel: each screen's desktop and lock screen images, editable in place.
struct MenuContent: View {
    @Environment(WallpaperStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    /// Up to this many screens show in full; more than that scroll.
    private let maxVisibleDisplays = 3
    private let sectionSpacing: CGFloat = 14
    /// Two 136 pt tiles and the gap between them.
    private let contentWidth: CGFloat = 280
    /// A column for the scroll bar, wide enough for an always-shown scroller.
    private let scrollerWidth: CGFloat = 16
    @State private var sectionHeights: [String: CGFloat] = [:]

    var body: some View {
        let scrolls = store.displays.count > maxVisibleDisplays
        VStack(alignment: .leading, spacing: 14) {
            ProfileBar()
                .frame(width: contentWidth)

            if scrolls {
                ScrollView {
                    displayList
                        .frame(width: contentWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.visible)
                .frame(width: contentWidth + scrollerWidth, height: listHeight)
            } else {
                displayList
                    .frame(width: contentWidth)
            }

            if UpdateService.shared.hasUpdate {
                UpdateBanner()
                    .frame(width: contentWidth)
            }

            if let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(width: contentWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GlassEffectContainer {
                HStack {
                    Button {
                        dismiss()
                        openWindow(id: "settings")
                        NSApp.activate()
                    } label: {
                        Label("Settings…", systemImage: "gearshape")
                            .labelStyle(.iconOnly)
                    }
                    .help("Settings")
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                }
                .buttonStyle(.glass)
            }
            .frame(width: contentWidth)
            .padding(.top, 6)
        }
        .padding(14)
        .fixedSize()
    }

    private var displayList: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            ForEach(store.displays) { display in
                DisplaySection(display: display)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { height in
                        // The first layout pass reports a few points more, so keep each section's latest height.
                        sectionHeights[display.id] = height
                    }
            }
        }
    }

    /// Exactly `maxVisibleDisplays` sections, so the list is as tall as it would be without scrolling.
    private var listHeight: CGFloat {
        let section = sectionHeights.values.max() ?? 130
        let count = CGFloat(maxVisibleDisplays)
        return section * count + sectionSpacing * (count - 1)
    }
}

private struct DisplaySection: View {
    @Environment(WallpaperStore.self) private var store
    let display: Display

    var body: some View {
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
}

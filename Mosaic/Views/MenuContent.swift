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

            if let change = store.undoable {
                HStack(spacing: 8) {
                    Text(change.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Undo") { store.undo() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .keyboardShortcut("z", modifiers: .command)
                        .help("Put the image back (⌘Z)")
                }
                .frame(width: contentWidth)
                .transition(.opacity)
            }

            if UpdateService.shared.hasUpdate {
                UpdateBanner()
                    .frame(width: contentWidth)
            }

            if let error = store.lastError {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        store.dismissError()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss error")
                }
                .frame(width: contentWidth)
                .transition(.opacity)
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
                    if store.hasVideos {
                        Button {
                            store.videosPaused.toggle()
                        } label: {
                            Label(store.videosPaused ? "Play Videos" : "Pause Videos",
                                  systemImage: store.videosPaused ? "play.fill" : "pause.fill")
                        }
                        .help(store.videosPaused ? "Play the video wallpapers again" : "Pause every video wallpaper")
                        Spacer()
                    }
                    Button("Quit") { NSApp.terminate(nil) }
                }
                .buttonStyle(.glass)
            }
            .frame(width: contentWidth)
            .padding(.top, 6)
        }
        .padding(14)
        .fixedSize()
        .animation(.easeOut(duration: 0.15), value: store.undoable?.message)
        .animation(.easeOut(duration: 0.15), value: store.lastError)
        // Undo lasts while the panel is open; a replace made through the open
        // panel (which closes this one first) can be undone the next time it opens.
        // An error, once seen, goes when the panel closes.
        .onDisappear {
            store.dismissUndo()
            store.dismissError()
        }
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

/// One screen's tiles and its "same as desktop" switch. Also used by the drop shelf.
struct DisplaySection: View {
    @Environment(WallpaperStore.self) private var store
    let display: Display
    var showsLockToggle = true

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
            if showsLockToggle, VideoFile.isVideo(store.wallpapers(for: display).desktop),
               store.wallpapers(for: display).effectiveLock == nil {
                Text("Lock screen shows a still from the video.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if showsLockToggle {
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
}

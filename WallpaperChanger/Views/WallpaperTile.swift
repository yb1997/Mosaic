import SwiftUI
import UniformTypeIdentifiers

/// One image slot of one screen. Click (or hover and click "Choose…") to pick
/// an image in a Finder panel; the × in the corner clears it.
struct WallpaperTile: View {
    @Environment(WallpaperStore.self) private var store
    let display: Display
    let slot: Slot
    @State private var isHovering = false

    var body: some View {
        let wallpapers = store.wallpapers(for: display)
        // A lock tile that follows the desktop shows the desktop image and can't be edited.
        let isLinked = slot == .lock && wallpapers.lockSameAsDesktop
        let fileName = isLinked ? nil : wallpapers[slot]
        let shown = isLinked ? wallpapers.desktop : fileName
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        Button(action: choose) {
            Thumbnail(url: store.imageURL(shown), placeholder: slot == .lock ? "Same as desktop" : "Not set")
                .opacity(isLinked ? 0.6 : 1)
                .overlay {
                    if isLinked {
                        Label("Same as desktop", systemImage: "link")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .glassEffect(.regular, in: .capsule)
                    } else if isHovering {
                        ZStack {
                            shape.fill(.black.opacity(0.25))
                            Label("Choose…", systemImage: "photo.badge.plus")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .glassEffect(.regular, in: .capsule)
                        }
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    Text(slot.title)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .glassEffect(.regular, in: .capsule)
                        .padding(5)
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(isLinked)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .overlay(alignment: .topTrailing) {
            if fileName != nil {
                Button {
                    store.clear(slot, display: display)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .padding(5)
                .help("Clear \(slot.title.lowercased()) image")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(display.name), \(slot.title)")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the \(slot.title.lowercased()) image for \(display.name)"
        NSApp.activate()
        // The menu panel closes when the open panel takes focus, so don't rely on this view after it.
        let store = store, display = display, slot = slot
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                store.setImage(from: url, slot: slot, display: display)
            }
        }
    }
}

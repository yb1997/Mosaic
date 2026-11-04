import SwiftUI
import UniformTypeIdentifiers

/// One image slot of one screen. Click (or hover and click "Choose…") to pick
/// an image in a Finder panel, or drop an image on it; the × in the corner clears it.
struct WallpaperTile: View {
    @Environment(WallpaperStore.self) private var store
    let display: Display
    let slot: Slot
    @State private var isHovering = false
    @State private var isDropTarget = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let wallpapers = store.wallpapers(for: display)
        // A lock tile that follows the desktop shows the desktop image and can't be edited.
        let isLinked = slot == .lock && wallpapers.lockSameAsDesktop
        let fileName = isLinked ? nil : wallpapers[slot]
        let shown = isLinked ? wallpapers.desktop : fileName
        let isImporting = store.isImporting(slot, display: display)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        Button(action: choose) {
            // A linked tile already says "Same as desktop" in its label, so its placeholder stays blank.
            Thumbnail(url: store.imageURL(shown),
                      placeholder: isLinked ? "" : slot == .lock ? "Same as desktop" : "Not set")
                .opacity(isLinked ? 0.6 : 1)
                .overlay {
                    if isImporting {
                        ZStack {
                            shape.fill(.black.opacity(0.25))
                            ProgressView()
                                .controlSize(.small)
                        }
                    } else if isLinked {
                        Label("Same as desktop", systemImage: "link")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .glassEffect(.regular, in: .capsule)
                    } else if isHovering || isDropTarget {
                        ZStack {
                            shape.fill(.black.opacity(0.25))
                            Label(isDropTarget ? "Drop to Use" : "Choose…",
                                  systemImage: isDropTarget ? "arrow.down.circle" : "photo.badge.plus")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .glassEffect(.regular, in: .capsule)
                        }
                    }
                }
                .overlay {
                    if isDropTarget {
                        shape.strokeBorder(.tint, lineWidth: 2)
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
        .disabled(isLinked || isImporting)
        .onHover { isHovering = $0 }
        .onDrop(of: [.fileURL, .image], isTargeted: Binding(
            get: { isDropTarget },
            set: { isDropTarget = $0 && !isLinked && !isImporting }
        )) { providers in
            guard !isLinked, !isImporting, let provider = providers.first else { return false }
            return accept(provider)
        }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .animation(.easeOut(duration: 0.15), value: isDropTarget)
        .overlay(alignment: .topTrailing) {
            if fileName != nil && !isImporting {
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
        // Close the menu panel first: it floats above other windows and would cover the open panel.
        dismiss()
        NSApp.activate()
        let store = store, display = display, slot = slot
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                store.setImage(from: url, slot: slot, display: display)
            }
        }
    }

    /// A file from Finder is copied like a picked one. Anything else (Photos,
    /// a browser) arrives as a temporary file that only exists inside the
    /// callback, so it is copied there, off the main thread.
    private func accept(_ provider: NSItemProvider) -> Bool {
        let store = store, slot = slot, displayID = display.id
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    guard let display = store.displays.first(where: { $0.id == displayID }) else { return }
                    if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
                        store.setImage(from: url, slot: slot, display: display)
                    } else {
                        store.importFailed(url.lastPathComponent, CocoaError(.fileReadCorruptFile, userInfo: [
                            NSLocalizedDescriptionKey: "It isn’t an image.",
                        ]))
                    }
                }
            }
            return true
        }
        guard let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .image) }) else { return false }
        let destination = store.beginImport(slot: slot, displayID: displayID,
                                            fileExtension: type.preferredFilenameExtension ?? "")
        let droppedName = provider.suggestedName ?? "The dropped image"
        _ = provider.loadFileRepresentation(for: type) { url, _, error in
            var failure: Error? = error ?? (url == nil ? CocoaError(.fileReadUnknown) : nil)
            if let url {
                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                } catch {
                    failure = error
                }
            }
            let result = failure
            Task { @MainActor in
                store.finishImport(destination, error: result, sourceName: droppedName, slot: slot, displayID: displayID)
            }
        }
        return true
    }
}

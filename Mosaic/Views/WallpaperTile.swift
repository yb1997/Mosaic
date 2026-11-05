import SwiftUI
import UniformTypeIdentifiers

/// One image slot of one screen. Click (or hover and click "Choose…") to pick
/// an image in a Finder panel, or drop an image on it; the × in the corner clears it.
/// A desktop slot also takes a video (docs/VIDEO_WALLPAPERS.md).
struct WallpaperTile: View {
    @Environment(WallpaperStore.self) private var store
    let display: Display
    let slot: Slot
    @State private var isHovering = false
    @State private var isDropTarget = false
    @State private var videoDuration: (name: String, seconds: TimeInterval)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let wallpapers = store.wallpapers(for: display)
        // A lock tile that follows the desktop shows the desktop image and can't be edited.
        let isLinked = slot == .lock && wallpapers.lockSameAsDesktop
        let fileName = isLinked ? nil : wallpapers[slot]
        let shown = isLinked ? wallpapers.desktop : fileName
        let isImporting = store.isImporting(slot, display: display)
        let progress = store.videoProgress(slot, display: display)
        let isVideo = VideoFile.isVideo(fileName)
        let scaling = isLinked ? wallpapers.desktopScaling : wallpapers.scaling(slot)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        Button(action: choose) {
            // A linked tile already says "Same as desktop" in its label, so its placeholder stays blank.
            Thumbnail(url: store.pictureURL(shown),
                      placeholder: isLinked ? "" : slot == .lock ? "Same as desktop" : "Not set",
                      scaling: scaling,
                      screenPixels: screenPixels)
                .opacity(isLinked ? 0.6 : 1)
                .overlay {
                    if isImporting {
                        ZStack {
                            shape.fill(.black.opacity(0.25))
                            if let progress {
                                VStack(spacing: 5) {
                                    ProgressView(value: progress)
                                        .progressViewStyle(.circular)
                                        .controlSize(.small)
                                    Text("Optimizing… \(Int(progress * 100))%")
                                        .font(.caption2.weight(.semibold))
                                        .monospacedDigit()
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .glassEffect(.regular, in: .capsule)
                                }
                            } else {
                                ProgressView()
                                    .controlSize(.small)
                            }
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
                .overlay(alignment: .topLeading) {
                    if isVideo && !isImporting && !isHovering && !isDropTarget {
                        Label(videoDuration?.name == fileName ? videoDuration.map { Self.format($0.seconds) } ?? "Video" : "Video",
                              systemImage: "play.fill")
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .glassEffect(.regular, in: .capsule)
                            .padding(5)
                            .accessibilityLabel("Video")
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
        .onDrop(of: [.fileURL, .image, .movie], isTargeted: Binding(
            get: { isDropTarget },
            set: { isDropTarget = $0 && !isLinked && !isImporting }
        )) { providers in
            guard !isLinked, !isImporting, let provider = providers.first else { return false }
            return accept(provider)
        }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .animation(.easeOut(duration: 0.15), value: isDropTarget)
        .overlay(alignment: .topTrailing) {
            // While a video converts, × stops it.
            if (fileName != nil && !isImporting) || progress != nil {
                Button {
                    if progress != nil {
                        store.cancelVideoConversion(slot, display: display)
                    } else {
                        store.clear(slot, display: display)
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .padding(5)
                .help(progress != nil ? "Stop converting the video" : "Clear \(slot.title.lowercased()) \(isVideo ? "video" : "image")")
            }
        }
        .task(id: fileName) {
            guard isVideo, let fileName, let url = store.imageURL(fileName) else { return }
            if let seconds = await VideoEncoder.duration(of: url) { videoDuration = (fileName, seconds) }
        }
        .contextMenu { menu(fileName: fileName, isLinked: isLinked, isImporting: isImporting) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(display.name), \(slot.title)")
    }

    /// Right-click (or Control-click) actions for this tile.
    @ViewBuilder
    private func menu(fileName: String?, isLinked: Bool, isImporting: Bool) -> some View {
        let others = store.displays.filter { $0.id != display.id }
        let hasImage = fileName != nil && !isImporting
        let isVideo = VideoFile.isVideo(fileName)

        Button(slot == .desktop ? "Choose Image or Video…" : "Choose Image…", systemImage: "photo.badge.plus", action: choose)
            .disabled(isLinked || isImporting)

        if !others.isEmpty {
            Divider()
            Button("Use on All Screens", systemImage: "rectangle.on.rectangle") {
                store.useOnAllScreens(slot, from: display)
            }
            .disabled(!hasImage)
            Menu("Copy to", systemImage: "arrow.right.doc.on.clipboard") {
                ForEach(others) { target in
                    Button(target.name) { store.copy(slot, from: display, to: target) }
                }
            }
            .disabled(!hasImage)
        }

        Picker("Scaling", systemImage: "arrow.up.left.and.arrow.down.right", selection: Binding(
            get: { store.wallpapers(for: display).scaling(slot) },
            set: { store.setScaling($0, slot, display: display) }
        )) {
            ForEach(Scaling.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
        .disabled(!hasImage)

        if isVideo, slot == .desktop, let format = store.videoFormat(on: display) {
            videoMenu(format, fileName: fileName, isImporting: isImporting)
        }

        Button("Swap Desktop and Lock Screen", systemImage: "arrow.left.arrow.right") {
            store.swapDesktopAndLock(on: display)
        }
        .disabled(isImporting || !store.canSwap(on: display))

        Divider()
        Button("Show in Finder", systemImage: "folder") {
            if let url = store.imageURL(fileName) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        .disabled(!hasImage)
        Button("Clear \(slot.title) \(isVideo ? "Video" : "Image")", systemImage: "xmark", role: .destructive) {
            store.clear(slot, display: display)
        }
        .disabled(!hasImage)
    }

    /// Frame rate and quality for this screen's video, checked where they apply.
    @ViewBuilder
    private func videoMenu(_ format: VideoFormat, fileName: String?, isImporting: Bool) -> some View {
        let standard = VideoFormat.default()
        Menu("Video", systemImage: "film") {
            Section("Frame Rate") {
                ForEach(FrameRate.allCases, id: \.self) { rate in
                    // Original quality keeps every frame, so another rate needs re-encoding at the default quality.
                    let wanted = VideoFormat(frameRate: rate,
                                             quality: format.quality == .original && rate != .original ? standard.quality : format.quality)
                    formatToggle(rate.title, isOn: format.frameRate == rate, wanted: wanted, isImporting: isImporting)
                }
            }
            Section("Quality") {
                ForEach(VideoQuality.allCases, id: \.self) { quality in
                    formatToggle(quality.title, isOn: format.quality == quality,
                                 wanted: VideoFormat(frameRate: format.frameRate, quality: quality), isImporting: isImporting)
                }
            }
            Divider()
            Button("Use Default (\(standard.title))") { store.setVideoFormat(standard, display: display) }
                .disabled(format == standard || isImporting || !store.canUse(standard, on: display))
            if let details = videoDetails(fileName) {
                Divider()
                Text(details)
            }
        }
    }

    private func formatToggle(_ title: String, isOn: Bool, wanted: VideoFormat, isImporting: Bool) -> some View {
        Toggle(title, isOn: Binding(
            get: { isOn },
            set: { _ in store.setVideoFormat(wanted, display: display) }
        ))
        .disabled(isImporting || (!isOn && !store.canUse(wanted, on: display)))
    }

    /// "45 MB · 4608×2592" for the stored video.
    private func videoDetails(_ fileName: String?) -> String? {
        guard let url = store.imageURL(fileName),
              let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        guard let pixels = store.pictureURL(fileName).flatMap({ Thumbnails.shared.pixelSize(for: $0) }) else { return size }
        return "\(size) · \(Int(pixels.width))×\(Int(pixels.height))"
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var screenPixels: CGSize {
        let frame = display.screen.frame
        let scale = display.screen.backingScaleFactor
        return CGSize(width: frame.width * scale, height: frame.height * scale)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = slot == .desktop ? [.image, .movie] : [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = slot == .desktop
            ? "Choose the desktop image or video for \(display.name)"
            : "Choose the \(slot.title.lowercased()) image for \(display.name)"
        // Close the menu panel first: it floats above other windows and would cover the open panel.
        dismiss()
        NSApp.activate()
        let store = store, display = display, slot = slot
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                store.setMedia(from: url, slot: slot, display: display)
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
                    if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true || VideoFile.isVideoSource(url) {
                        store.setMedia(from: url, slot: slot, display: display)
                    } else {
                        store.importFailed(url.lastPathComponent, CocoaError(.fileReadCorruptFile, userInfo: [
                            NSLocalizedDescriptionKey: slot == .desktop ? "It isn’t an image or a video." : "It isn’t an image.",
                        ]))
                    }
                }
            }
            return true
        }
        if let movie = provider.registeredContentTypes.first(where: { $0.conforms(to: .movie) }) {
            return acceptVideo(provider, type: movie)
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

    /// A video from another app (say, Photos) arrives as a temporary file
    /// that only exists inside the callback, so it is copied out first. The
    /// copy is temporary too, so no link to it is kept.
    private func acceptVideo(_ provider: NSItemProvider, type: UTType) -> Bool {
        let store = store, slot = slot, displayID = display.id
        guard slot == .desktop else {
            store.importFailed(provider.suggestedName ?? "The video", VideoEncoder.Failure(message: "The lock screen can only show images."))
            return true
        }
        let droppedName = provider.suggestedName ?? "The dropped video"
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mosaic-\(UUID().uuidString).\(type.preferredFilenameExtension ?? "mov")")
        _ = provider.loadFileRepresentation(for: type) { url, _, error in
            var failure: Error? = error ?? (url == nil ? CocoaError(.fileReadUnknown) : nil)
            if let url {
                do { try FileManager.default.copyItem(at: url, to: copy) } catch { failure = error }
            }
            let result = failure
            Task { @MainActor in
                if let result {
                    store.importFailed(droppedName, result)
                } else if let display = store.displays.first(where: { $0.id == displayID }) {
                    store.setVideo(from: copy, slot: slot, display: display, isTemporary: true)
                }
            }
        }
        return true
    }
}

import SwiftUI

struct Thumbnail: View {
    let url: URL?
    var placeholder = "Not set"
    var scaling = Scaling.fill
    /// The screen's size in pixels, to preview Center scaling.
    var screenPixels: CGSize?
    @State private var loaded: (url: URL, image: NSImage)?
    @State private var failed: URL?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        // Use an already-decoded preview straight away, so reopening the panel doesn't flash.
        let image = url.flatMap { url in loaded?.url == url ? loaded?.image : Thumbnails.shared.cached(for: url) }
        // The image fills whatever frame the caller gives, and never sizes the tile itself.
        Color.clear
            .overlay {
                if let image {
                    scaled(image, url: url)
                } else {
                    ZStack {
                        shape.fill(.quaternary)
                        if failed != nil && failed == url {
                            Text("No preview")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if url == nil {
                            if !placeholder.isEmpty {
                                Text(placeholder)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(.primary.opacity(0.08)))
            .animation(.easeOut(duration: 0.2), value: scaling)
            .task(id: url) {
                guard let url else { return }
                if let image = await Thumbnails.shared.image(for: url) {
                    loaded = (url, image)
                } else {
                    failed = url
                }
            }
    }

    /// The image laid out in the tile the way the screen will show it.
    @ViewBuilder
    private func scaled(_ image: NSImage, url: URL?) -> some View {
        let picture = Image(nsImage: image).resizable()
        switch scaling {
        case .fill:
            picture.scaledToFill()
        case .fit:
            ZStack {
                Color(nsColor: Scaling.fillColor)
                picture.scaledToFit()
            }
        case .stretch:
            picture
        case .center:
            GeometryReader { geometry in
                // Actual size: the image takes the same share of the tile as of the screen.
                let pixels = url.flatMap { Thumbnails.shared.pixelSize(for: $0) } ?? image.size
                let screen = screenPixels ?? CGSize(width: 2560, height: 1600)
                let factor = geometry.size.width / max(screen.width, 1)
                    * Scaling.centerScale(image: pixels, screen: screen)
                ZStack {
                    Color(nsColor: Scaling.fillColor)
                    picture.frame(width: pixels.width * factor, height: pixels.height * factor)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
        }
    }
}

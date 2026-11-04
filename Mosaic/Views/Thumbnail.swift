import SwiftUI

struct Thumbnail: View {
    let url: URL?
    var placeholder = "Not set"
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
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
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
            .task(id: url) {
                guard let url else { return }
                if let image = await Thumbnails.shared.image(for: url) {
                    loaded = (url, image)
                } else {
                    failed = url
                }
            }
    }
}

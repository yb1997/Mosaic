import SwiftUI

struct Thumbnail: View {
    let url: URL?
    var placeholder = "Not set"

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        // The image fills whatever frame the caller gives, and never sizes the tile itself.
        Color.clear
            .overlay {
                if let url, let image = Thumbnails.shared.image(for: url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        shape.fill(.quaternary)
                        Text(placeholder)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(.primary.opacity(0.08)))
    }
}

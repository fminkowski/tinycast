import SwiftUI

struct ScreenshotThumbnail: View {
    @Environment(PaletteState.self) private var palette
    @Environment(\.metrics) private var metrics
    let item: ScreenshotItem
    let maxPixel: CGFloat
    @State private var image: NSImage?
    @State private var unavailable = false

    private struct Request: Equatable {
        let item: ScreenshotItem
        let visible: Bool
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: metrics.radius.card, style: .continuous))
            } else {
                SymbolImage(name: unavailable ? "photo.badge.exclamationmark" : "photo", size: metrics.size.resultRowIcon)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(unavailable ? "Image is unreadable or unavailable" : "Image preview")
            }
        }
        .task(id: Request(item: item, visible: palette.isVisible)) {
            image = nil
            unavailable = false
            guard palette.isVisible else { return }
            let loaded = await ImageThumbnail.loadAsync(item.url, maxPixel: maxPixel, revision: item.revision)
            guard !Task.isCancelled else { return }
            image = loaded
            unavailable = loaded == nil
        }
    }
}

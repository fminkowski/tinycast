import SwiftUI

struct ScreenshotPreview: View {
    @Environment(\.metrics) private var metrics
    let item: ScreenshotItem?

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: metrics.spacing.md) {
                ScreenshotThumbnail(item: item, maxPixel: metrics.size.clipboardPreviewPixel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: metrics.spacing.xs) {
                    Text(item.name).font(metrics.typography.rowTitle).lineLimit(2)
                    Text(item.dateLabel).foregroundStyle(.secondary)
                    if item.pixelWidth > 0 {
                        Text("\(item.pixelWidth) × \(item.pixelHeight)").foregroundStyle(.secondary)
                    }
                    Text(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file))
                        .foregroundStyle(.secondary)
                }
                .font(metrics.typography.rowTrailing)
                .padding(.bottom, metrics.spacing.md)
            }
            .padding(.horizontal, metrics.spacing.md)
        } else {
            Color.clear
        }
    }
}

import SwiftUI

struct ScreenshotBrowser: View {
    @Environment(\.metrics) private var metrics
    @Environment(PaletteState.self) private var palette
    let coordinator: ScreenshotCoordinator
    let results: [ScreenshotItem]
    let selection: Int
    let scroll: ScrollIntent
    let onSelect: (ScreenshotItem) -> Void
    let onActions: (ScreenshotItem) -> Void

    private var selected: ScreenshotItem? { results.indices.contains(selection) ? results[selection] : nil }

    var body: some View {
        if coordinator.store.state == .failed {
            EmptyResults(text: "Screenshot folder is unavailable")
        } else if results.isEmpty {
            if coordinator.store.state == .loading {
                Color.clear
            } else {
                EmptyResults(text: palette.query.isEmpty ? "No screenshots in this folder" : "No matching screenshots")
            }
        } else {
            HStack(spacing: 0) {
                list.frame(width: metrics.size.clipboardListWidth)
                Rectangle().fill(Theme.Colors.separator).frame(width: Theme.Size.hairline)
                ScreenshotPreview(item: selected)
            }
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    SectionHeader(title: "Screenshots", isFirst: true)
                    ForEach(results) { item in
                        ScreenshotRow(item: item, selected: item.id == selected?.id)
                            .selectionFrame(item.id == selected?.id)
                            .contentShape(Rectangle())
                            .onTapGesture { coordinator.copy(item) }
                            .onRightClick { onActions(item) }
                            .onContinuousHover { phase in
                                if case .active = phase, palette.hoverHighlightArmed { onSelect(item) }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { coordinator.copy(item) }
                    }
                }
                .padding(.horizontal, metrics.spacing.md)
                .padding(.top, metrics.spacing.xs)
                .padding(.bottom, metrics.spacing.md)
                .hideNativeScrollers()
                .scrollOriginAnchor()
            }
            .edgeDissolve()
            .thinScrollbar()
            .scrollFollowsSelection(scroll, row: selected?.id, atOrigin: selection == 0, proxy: proxy)
        }
    }
}

private struct ScreenshotRow: View {
    @Environment(\.metrics) private var metrics
    let item: ScreenshotItem
    let selected: Bool

    var body: some View {
        HStack(spacing: metrics.spacing.lg) {
            ScreenshotThumbnail(item: item, maxPixel: metrics.size.resultRowIcon * 2)
                .frame(width: metrics.size.resultRowIcon, height: metrics.size.resultRowIcon)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: metrics.spacing.xxs) {
                Text(item.name).font(metrics.typography.rowTitle).lineLimit(1)
                Text(item.dateLabel).font(metrics.typography.rowTrailing).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, metrics.spacing.md)
        .padding(.vertical, metrics.spacing.sm)
        .background(selected ? Theme.Colors.selection : Color.clear,
                    in: RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

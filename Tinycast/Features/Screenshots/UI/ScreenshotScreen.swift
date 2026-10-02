import SwiftUI

struct ScreenshotScreen: PaletteScreen {
    let coordinator: ScreenshotCoordinator
    let vm: PaletteState
    let openActions: () -> Void

    var rows: [ScreenshotItem] { coordinator.store.search(vm.query) }
    var primaryActionTitle: String { "Copy Screenshot" }

    func activate(at selection: Int) {
        guard rows.indices.contains(selection) else { return }
        coordinator.copy(rows[selection])
    }

    func secondary(at selection: Int) -> Bool {
        guard rows.indices.contains(selection) else { return false }
        coordinator.reveal(rows[selection])
        return true
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        guard rows.indices.contains(selection) else { return nil }
        let item = rows[selection]
        return PopoverMenuContent(header: item.name, items: [
            PopoverMenuItem(title: "Copy Screenshot", systemImage: "doc.on.clipboard", shortcut: "↵") {
                coordinator.copy(item)
            },
            PopoverMenuItem(title: "Show in Finder", systemImage: "folder", shortcut: "⌘↵") {
                coordinator.reveal(item)
            }
        ])
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        AnyView(ScreenshotBrowser(
            coordinator: coordinator, results: rows, selection: selection, scroll: scroll,
            onSelect: { item in vm.selection = rows.firstIndex(where: { $0.id == item.id }) ?? 0 },
            onActions: { item in
                vm.selection = rows.firstIndex(where: { $0.id == item.id }) ?? 0
                openActions()
            }))
    }
}

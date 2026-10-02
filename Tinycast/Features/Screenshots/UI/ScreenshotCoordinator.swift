import AppKit
import ScreenCaptureKit

@MainActor
@Observable
final class ScreenshotCoordinator {
    enum CaptureMode { case area, window, screen }
    let store: ScreenshotStore
    private(set) var folder: URL
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private unowned let core: AppCore
    @ObservationIgnored private let selector = ScreenshotSelectionController()
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var copyTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(store: ScreenshotStore, settings: AppSettings, core: AppCore) {
        self.store = store
        self.settings = settings
        self.core = core
        folder = store.folder
        store.onFailure = { [weak core] in core?.showMessage("Couldn't index screenshot text", tone: .danger) }
        store.onResultsChanged = { [weak core] previous, current in
            guard let core, core.palette.isVisible, core.palette.mode == .screenshots,
                previous.indices.contains(core.palette.selection)
            else { return }
            let identity = previous[core.palette.selection].fileIdentity
            core.palette.selection = current.firstIndex(where: { $0.fileIdentity == identity }) ?? 0
        }
    }

    isolated deinit {
        captureTask?.cancel()
        copyTask?.cancel()
        refreshTask?.cancel()
    }

    func applyEnabled() {
        core.appIndex.setCommandsVisible(Set(SettingsTab.screenshots.ownedCommands), settings.screenshotsEnabled)
        applyFolder()
        if !settings.screenshotsEnabled, core.palette.mode == .screenshots {
            core.palette.prepare(mode: .launcher)
        }
    }

    func applyFolder() {
        captureTask?.cancel()
        selector.cancel()
        copyTask?.cancel()
        if core.palette.mode == .screenshots { core.palette.selection = 0 }
        folder = ScreenshotRepository.folder(
            chosen: settings.screenshotsFolder, home: FileManager.default.homeDirectoryForCurrentUser,
            bundleID: Bundle.main.bundleIdentifier ?? "com.tinycast.app")
        if settings.screenshotsEnabled {
            store.start(folder: folder)
        } else {
            stop()
        }
    }

    func stop() {
        captureTask?.cancel()
        copyTask?.cancel()
        selector.cancel()
        paletteDidHide()
        store.stop()
    }

    func show() {
        guard settings.screenshotsEnabled else { return }
        core.paletteCoordinator.togglePalette(mode: .screenshots)
    }

    func load() {
        guard settings.screenshotsEnabled else { return }
        store.refresh()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.core.palette.isVisible, self.core.palette.mode == .screenshots else { return }
                self.store.refresh()
            }
        }
    }

    func paletteDidHide() {
        refreshTask?.cancel()
        refreshTask = nil
        copyTask?.cancel()
    }

    func capture(_ mode: CaptureMode) {
        guard settings.screenshotsEnabled, !focusCapture() else { return }
        let screen = NSScreen.underCursor
        let folder = folder
        core.paletteCoordinator.hidePalette()
        captureTask = Task { [weak self] in
            guard let self else { return }
            defer { self.captureTask = nil }
            guard Permissions.ensureScreenRecording() else {
                await self.core.showNotice(
                    title: "Screen Recording Access Required",
                    message: "Allow Tinycast in System Settings › Privacy & Security › Screen Recording, then try again.",
                    symbol: "display", tone: .danger)
                return
            }
            do {
                try Task.checkCancellation()
                let png = try await self.takeScreenshot(mode, screen: screen)
                try Task.checkCancellation()
                guard let png, self.settings.screenshotsEnabled else { return }
                self.core.clipboardManager.copyImage(png)
                let worker = Task.detached(priority: .utility) {
                    try ScreenshotRepository.save(png, in: folder, at: Date(), identifier: UUID())
                }
                do {
                    _ = try await worker.value
                    self.store.refresh()
                    self.core.showMessage("Screenshot copied and saved")
                } catch {
                    self.core.showMessage("Screenshot copied, but couldn't save it: \(error.localizedDescription)", tone: .danger)
                }
            } catch is CancellationError {
                return
            } catch {
                self.core.showMessage("Couldn't capture screenshot: \(error.localizedDescription)", tone: .danger)
            }
        }
    }

    func focusCapture() -> Bool {
        guard captureTask != nil else { return false }
        if core.paletteCoordinator.isVisible { core.paletteCoordinator.hidePalette(restoreFocus: false) }
        _ = selector.focusExisting()
        return true
    }

    func copy(_ item: ScreenshotItem) {
        guard settings.screenshotsEnabled, copyTask == nil else { return }
        copyTask = Task { [weak self] in
            defer { self?.copyTask = nil }
            let worker = Task.detached(priority: .userInitiated) { try ScreenshotRepository.png(at: item.url) }
            do {
                let png = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.settings.screenshotsEnabled else { return }
                self.core.clipboardManager.copyImage(png)
                self.core.paletteCoordinator.hidePalette()
                self.core.showMessage("Screenshot copied")
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.core.showMessage("Couldn't copy screenshot: \(error.localizedDescription)", tone: .danger)
                self.store.refresh()
            }
        }
    }

    func chooseFolder() {
        guard let chosen = FolderPicker.choose(message: "Choose where screenshots are saved and searched.", startingAt: folder)
        else { return }
        settings.screenshotsFolder = (chosen.path as NSString).abbreviatingWithTildeInPath
    }

    func resetFolder() { settings.screenshotsFolder = nil }
    func openFolder() {
        if !NSWorkspace.shared.open(folder) {
            core.showMessage("Screenshot folder is unavailable. Capture an image to create it.", tone: .danger)
        }
    }
    func reveal(_ item: ScreenshotItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

    private func takeScreenshot(_ mode: CaptureMode, screen: NSScreen?) async throws -> Data? {
        let primaryTop = NSScreen.primary?.frame.maxY ?? 0
        if mode == .screen {
            guard let screen else { throw CocoaError(.featureUnsupported) }
            return try await ScreenshotCaptureService.capture(
                rectangle: ScreenshotGeometry.captureRectangle(screen.frame, primaryTop: primaryTop),
                scale: screen.backingScaleFactor)
        }
        let windows = mode == .window ? try await selectableWindows() : nil
        try Task.checkCancellation()
        let targets = windows?.map { ScreenshotSelectionController.WindowTarget(id: $0.windowID, frame: $0.frame) }
        guard let selection = await selector.select(windows: targets) else { return nil }
        try Task.checkCancellation()
        switch selection {
        case .area(let rectangle):
            let scale = NSScreen.screens.filter { $0.frame.intersects(rectangle) }
                .map(\.backingScaleFactor).max() ?? 1
            return try await ScreenshotCaptureService.capture(
                rectangle: ScreenshotGeometry.captureRectangle(rectangle, primaryTop: primaryTop), scale: scale)
        case .window(let id):
            guard let window = windows?.first(where: { $0.windowID == id }) else { return nil }
            return try await ScreenshotCaptureService.capture(window: window)
        }
    }

    private func selectableWindows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let byID = Dictionary(uniqueKeysWithValues: content.windows.filter { $0.windowLayer == 0 }.map { ($0.windowID, $0) })
        let ordered = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return ordered.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID else { return nil }
            return byID[id]
        }
    }
}

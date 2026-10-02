import AppKit

@main
@MainActor
struct ScreenshotSelectionTests {
    static var failures = 0
    static var passes = 0

    static func main() async {
        _ = NSApplication.shared
        let controller = ScreenshotSelectionController()
        let baseline = Set(NSApp.windows.map(\.windowNumber))
        let selection = Task { await controller.select(windows: nil) }
        await wait { NSApp.windows.contains { !baseline.contains($0.windowNumber) && $0.isVisible } }
        guard let panel = NSApp.windows.first(where: { !baseline.contains($0.windowNumber) && $0.isVisible }) else {
            controller.cancel()
            _ = await selection.value
            exit(1)
        }
        expect(panel.styleMask.contains(.nonactivatingPanel), "selector receives input without activating Tinycast")
        expect(panel.level == .screenSaver && !panel.isOpaque && !panel.hasShadow,
               "selector owns a transparent panel above application windows")
        expect(hasVisiblePrompt(panel), "area selection draws visible guidance before dragging")
        expect(panel.contentView?.acceptsFirstMouse(for: nil) == true,
               "the inactive selector accepts the first drag or click")
        expect(panel.contentView?.subviews.count == NSScreen.screens.count,
               "each display gets visible selection guidance")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            panel.appearance = NSAppearance(named: appearance)
            expect(hasVisiblePrompt(panel), "selection guidance remains visible in \(appearance.rawValue)")
        }
        panel.appearance = nil
        if let prompt = panel.contentView?.subviews.first {
            let point = CGPoint(x: prompt.frame.midX, y: prompt.frame.midY)
            expect(panel.contentView?.hitTest(point) === panel.contentView,
                   "instruction pills do not swallow selection clicks")
        } else { expect(false, "instruction pill is present") }
        let launcher = LauncherPanel(
            contentRect: CGRect(x: 100, y: 100, width: 300, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        launcher.makeKeyAndOrderFront(nil)
        await wait { launcher.isKeyWindow }
        expect(launcher.isKeyWindow, "another surface displaced the selector's keyboard focus")
        expect(controller.focusExisting(), "reopening raises an unfinished capture instead of another surface")
        await wait { panel.isKeyWindow }
        expect(panel.isKeyWindow, "reopening restores keyboard input to the selector")
        launcher.orderOut(nil)
        expect(await controller.select(windows: nil) == nil, "repeated selection cannot stack panels")
        send(.leftMouseDown, at: CGPoint(x: 100, y: 100), to: panel)
        send(.leftMouseDragged, at: CGPoint(x: 30, y: 40), to: panel)
        send(.leftMouseUp, at: CGPoint(x: 30, y: 40), to: panel)
        let result = await selection.value
        if case .area(let rectangle) = result {
            expect(rectangle.size == CGSize(width: 70, height: 60), "native drag normalizes its selection")
        } else { expect(false, "native drag returns an area") }
        expect(!panel.isVisible && panel.contentView == nil, "selector hides and releases its view before returning")
        expect(!controller.focusExisting(), "a completed capture does not intercept reopening")

        await windowClick(controller)

        let cancelled = Task { await controller.select(windows: []) }
        await wait { NSApp.windows.contains { $0.isVisible && $0.level == .screenSaver } }
        if let panel = NSApp.windows.first(where: { $0.isVisible && $0.level == .screenSaver }),
            let escape = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
            expect(hasVisiblePrompt(panel), "window selection draws visible guidance before hovering")
            panel.sendEvent(escape)
        } else { controller.cancel() }
        expect(await cancelled.value == nil, "Escape cancels a window selection")
        expect(!NSApp.windows.contains { $0.isVisible && $0.level == .screenSaver }, "cancel leaves no selector visible")

        let stopped = Task { await controller.select(windows: nil) }
        await wait { NSApp.windows.contains { $0.isVisible && $0.level == .screenSaver } }
        controller.cancel()
        expect(await stopped.value == nil, "disabling or switching folders resolves a pending selector")
        print("\(passes)/\(passes + failures) passed")
        if failures > 0 { exit(1) }
    }

    static func windowClick(_ controller: ScreenshotSelectionController) async {
        guard let screen = NSScreen.primary else { expect(false, "display is available"); return }
        let point = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        let frame = CGRect(x: point.x - 100, y: point.y - 100, width: 200, height: 200)
        let target = ScreenshotSelectionController.WindowTarget(
            id: 42, frame: ScreenshotGeometry.captureRectangle(frame, primaryTop: screen.frame.maxY))
        let selection = Task { await controller.select(windows: [target]) }
        await wait { NSApp.windows.contains { $0.isVisible && $0.level == .screenSaver } }
        guard let panel = NSApp.windows.first(where: { $0.isVisible && $0.level == .screenSaver }) else {
            controller.cancel()
            _ = await selection.value
            return
        }
        let local = panel.convertPoint(fromScreen: point)
        send(.mouseMoved, at: local, to: panel)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            panel.appearance = NSAppearance(named: appearance)
            panel.contentView?.needsDisplay = true
            panel.displayIfNeeded()
            await wait { NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == panel.windowNumber }
            let hit = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
            expect(hit == panel.windowNumber,
                   "highlight accepts clicks in \(appearance.rawValue) (hit \(hit), selector \(panel.windowNumber))")
        }
        send(.leftMouseDown, at: local, to: panel)
        if case .window(let id) = await selection.value {
            expect(id == target.id, "clicking the highlight selects its window ID")
        } else { expect(false, "window click completes selection") }
    }

    static func hasVisiblePrompt(_ panel: NSWindow) -> Bool {
        guard let view = panel.contentView,
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let background = bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else { return false }
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if abs(color.redComponent - background.redComponent) > 0.2 { return true }
            }
        }
        return false
    }

    static func send(_ type: NSEvent.EventType, at point: CGPoint, to panel: NSWindow) {
        guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else { expect(false, "mouse event created"); return }
        panel.sendEvent(event)
    }

    static func wait(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        expect(false, "native window state settled within one second")
    }

    static func expect(_ condition: Bool, _ message: String) {
        if condition { passes += 1 } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    private final class LauncherPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }
}

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
        let launcher = LauncherPanel(
            contentRect: CGRect(x: 100, y: 100, width: 300, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        launcher.makeKeyAndOrderFront(nil)
        expect(launcher.isKeyWindow, "another surface displaced the selector's keyboard focus")
        expect(controller.focusExisting(), "reopening raises an unfinished capture instead of another surface")
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

        let cancelled = Task { await controller.select(windows: []) }
        await wait { NSApp.windows.contains { $0.isVisible && $0.level == .screenSaver } }
        if let panel = NSApp.windows.first(where: { $0.isVisible && $0.level == .screenSaver }),
            let escape = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
            panel.contentView?.keyDown(with: escape)
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

    static func send(_ type: NSEvent.EventType, at point: CGPoint, to panel: NSWindow) {
        guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1), let view = panel.contentView
        else { expect(false, "mouse event created"); return }
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        default: break
        }
    }

    static func wait(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        expect(false, "selector became visible within one second")
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

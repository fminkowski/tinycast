import AppKit
import ScreenCaptureKit

@MainActor
final class ScreenshotSelectionController {
    enum Selection: Sendable {
        case area(CGRect)
        case window(CGWindowID)
    }
    private var panel: SelectionPanel?
    private var continuation: CheckedContinuation<Selection?, Never>?

    func select(windows: [SCWindow]?) async -> Selection? {
        guard panel == nil else { return nil }
        let desktop = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        guard !desktop.isNull else { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let panel = SelectionPanel(
                contentRect: desktop, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.animationBehavior = .none
            panel.isMovableByWindowBackground = false
            panel.isReleasedWhenClosed = false
            let view = SelectionView(frame: CGRect(origin: .zero, size: desktop.size), windows: windows)
            view.onFinish = { [weak self] selection in self?.finish(selection) }
            panel.contentView = view
            view.highlightWindow(at: NSEvent.mouseLocation)
            self.panel = panel
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
            panel.makeFirstResponder(view)
        }
    }

    func cancel() { finish(nil) }

    func focusExisting() -> Bool {
        guard let panel else { return false }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.makeFirstResponder(panel.contentView)
        return true
    }

    private func finish(_ selection: Selection?) {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: selection)
    }
}

private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class SelectionView: NSView {
    var onFinish: ((ScreenshotSelectionController.Selection?) -> Void)?
    private let windows: [SCWindow]?
    private var start: CGPoint?
    private var rectangle: CGRect?
    private var selectedWindow: SCWindow?
    private var tracking: NSTrackingArea?

    init(frame: CGRect, windows: [SCWindow]?) {
        self.windows = windows
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityLabel(
            windows == nil ? "Drag an area to capture. Escape cancels." : "Click a window to capture. Escape cancels.")
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: windows == nil ? .crosshair : .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        self.tracking = tracking
        window?.acceptsMouseMovedEvents = true
    }

    override func mouseMoved(with event: NSEvent) {
        highlightWindow(at: window?.convertPoint(toScreen: event.locationInWindow) ?? .zero)
    }

    func highlightWindow(at point: CGPoint) {
        guard let windows else { return }
        let capturePoint = ScreenshotGeometry.captureRectangle(
            CGRect(origin: point, size: .zero), primaryTop: NSScreen.primary?.frame.maxY ?? 0).origin
        selectedWindow = windows.first { $0.frame.contains(capturePoint) }
        if let selectedWindow {
            rectangle = ScreenshotGeometry.captureRectangle(
                selectedWindow.frame, primaryTop: NSScreen.primary?.frame.maxY ?? 0)
        } else {
            rectangle = nil
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if windows != nil {
            mouseMoved(with: event)
            if let selectedWindow { onFinish?(.window(selectedWindow.windowID)) }
        } else {
            start = window?.convertPoint(toScreen: event.locationInWindow)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start, let end = window?.convertPoint(toScreen: event.locationInWindow) else { return }
        rectangle = ScreenshotGeometry.rectangle(from: start, to: end)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard windows == nil else { return }
        mouseDragged(with: event)
        guard let rectangle, rectangle.width >= 1, rectangle.height >= 1 else {
            start = nil
            return
        }
        onFinish?(.area(rectangle))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let shade = NSBezierPath(rect: bounds)
        if let rectangle, let window {
            let local = window.convertFromScreen(rectangle)
            shade.append(NSBezierPath(rect: local))
            shade.windingRule = .evenOdd
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(rect: local.insetBy(dx: -1, dy: -1))
            outline.lineWidth = 2
            outline.stroke()
        }
        NSColor.black.withAlphaComponent(0.25).setFill()
        shade.fill()
    }
}

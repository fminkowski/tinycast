import AppKit

@MainActor
final class ScreenshotSelectionController {
    enum Selection: Sendable {
        case area(CGRect)
        case window(CGWindowID)
    }
    struct WindowTarget: Sendable {
        let id: CGWindowID
        let frame: CGRect
    }
    private var panel: SelectionPanel?
    private var continuation: CheckedContinuation<Selection?, Never>?

    func select(windows: [WindowTarget]?) async -> Selection? {
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
            view.installPrompts()
            view.highlightWindow(at: NSEvent.mouseLocation)
            self.panel = panel
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
            panel.makeFirstResponder(view)
            view.selectionCursor.set()
        }
    }

    func cancel() { finish(nil) }

    func focusExisting() -> Bool {
        guard let panel else { return false }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.makeFirstResponder(panel.contentView)
        (panel.contentView as? SelectionView)?.selectionCursor.set()
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
    private let windows: [ScreenshotSelectionController.WindowTarget]?
    private var start: CGPoint?
    private var rectangle: CGRect?
    private var selectedWindow: ScreenshotSelectionController.WindowTarget?
    private var tracking: NSTrackingArea?
    var selectionCursor: NSCursor { windows == nil ? .crosshair : .pointingHand }

    init(frame: CGRect, windows: [ScreenshotSelectionController.WindowTarget]?) {
        self.windows = windows
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityLabel(
            windows == nil ? "Drag an area to capture. Escape cancels." : "Click a window to capture. Escape cancels.")
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func installPrompts() {
        guard let window else { return }
        let instruction = windows == nil ? "Drag to select an area" : "Click a highlighted window"
        for screen in NSScreen.screens {
            let label = NSTextField(labelWithString: "\(instruction)  ·  Esc to cancel")
            label.font = Theme.Typography.chipNSFont
            label.textColor = NSColor(Theme.Colors.textPrimary)
            label.sizeToFit()
            let inset = Theme.Spacing.dialogInset
            let size = CGSize(width: label.frame.width + inset * 2, height: label.frame.height + inset * 2)
            let visible = window.convertFromScreen(screen.visibleFrame)
            let prompt = SelectionPrompt(frame: CGRect(
                x: visible.midX - size.width / 2, y: visible.minY + Theme.Size.hudEdgeOffset,
                width: size.width, height: size.height))
            prompt.cornerRadius = size.height / 2
            let content = NSView(frame: CGRect(origin: .zero, size: size))
            label.setFrameOrigin(CGPoint(x: inset, y: inset))
            content.addSubview(label)
            prompt.contentView = content
            addSubview(prompt)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: selectionCursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        self.tracking = tracking
        window?.acceptsMouseMovedEvents = true
    }

    override func cursorUpdate(with event: NSEvent) { selectionCursor.set() }

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
            if let selectedWindow { onFinish?(.window(selectedWindow.id)) }
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
            if windows != nil {
                NSColor(Theme.Colors.selection).setFill()
                NSBezierPath(rect: local).fill()
            }
        }
        NSColor.black.withAlphaComponent(0.25).setFill()
        shade.fill()
    }
}

private final class SelectionPrompt: NSGlassEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

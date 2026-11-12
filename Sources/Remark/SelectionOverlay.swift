import AppKit

/// Full-screen dimmed overlay (one window per display). Drag to select a region,
/// click once for the whole display, Esc to cancel.
final class SelectionOverlay {
    private var windows: [NSWindow] = []
    private var completion: ((CGRect?) -> Void)?

    var isActive: Bool { !windows.isEmpty }

    func begin(completion: @escaping (CGRect?) -> Void) {
        guard windows.isEmpty else { return }
        self.completion = completion

        NSApp.activate(ignoringOtherApps: true)

        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame,
                                       styleMask: .borderless,
                                       backing: .buffered,
                                       defer: false)
            window.setFrame(screen.frame, display: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.screenFrame = screen.frame
            view.onFinish = { [weak self] rect in self?.finish(rect) }
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
        }

        let mouse = NSEvent.mouseLocation
        let target = windows.first(where: { $0.frame.contains(mouse) }) ?? windows.first
        target?.makeKey()
        target?.makeFirstResponder(target?.contentView)
        NSCursor.crosshair.set()
    }

    private func finish(_ rect: CGRect?) {
        guard !windows.isEmpty else { return }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        NSCursor.arrow.set()
        let done = completion
        completion = nil
        done?(rect)
    }
}

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class SelectionView: NSView {
    var screenFrame: CGRect = .zero
    var onFinish: ((CGRect?) -> Void)?

    private var start: NSPoint?
    private var current: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.crosshair.set() }

    private var selection: NSRect? {
        guard let s = start, let c = current else { return nil }
        return NSRect(x: min(s.x, c.x), y: min(s.y, c.y),
                      width: abs(s.x - c.x), height: abs(s.y - c.y))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        guard var rect = selection else { return }
        if rect.width < 6 || rect.height < 6 {
            rect = bounds // simple click → whole display
        }
        onFinish?(rect.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            onFinish?(nil)
        case 36, 76: // Return → whole display
            onFinish?(screenFrame)
        default:
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()

        if let rect = selection, rect.width > 0, rect.height > 0 {
            NSColor.clear.setFill()
            rect.fill(using: .copy)

            let accent = NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.1, alpha: 1)
            accent.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
            path.lineWidth = 2
            path.stroke()

            let label = "\(Int(rect.width)) × \(Int(rect.height))"
            drawPill(label, at: NSPoint(x: rect.minX, y: max(rect.minY - 26, 4)))
        } else {
            let hint = "Drag to select  ·  Click or ↩ for whole screen  ·  Esc to cancel"
            let size = pillSize(hint)
            drawPill(hint, at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - 90))
        }
    }

    private let pillAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor.white
    ]

    private func pillSize(_ text: String) -> NSSize {
        let s = (text as NSString).size(withAttributes: pillAttrs)
        return NSSize(width: s.width + 20, height: s.height + 8)
    }

    private func drawPill(_ text: String, at origin: NSPoint) {
        let size = pillSize(text)
        let rect = NSRect(origin: origin, size: size)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: rect, xRadius: size.height / 2, yRadius: size.height / 2).fill()
        (text as NSString).draw(at: NSPoint(x: rect.minX + 10, y: rect.minY + 4), withAttributes: pillAttrs)
    }
}

//  HighlightOverlay.swift
//  MacSpy
//
//  A borderless, click-through window that draws a red rectangle around the
//  element currently selected or hovered, mirroring Spy++'s window highlight.

import Cocoa

private final class HighlightView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.withAlphaComponent(0.12).setFill()
        bounds.fill()
        let border = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(rect: border)
        path.lineWidth = 3
        NSColor.systemRed.setStroke()
        path.stroke()
    }
}

final class HighlightOverlay {
    private let window: NSWindow

    init() {
        window = NSWindow(contentRect: .zero,
                          styleMask: .borderless,
                          backing: .buffered,
                          defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = HighlightView()
    }

    func show(axFrame: CGRect) {
        guard axFrame.width > 0, axFrame.height > 0 else { hide(); return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaY = primaryHeight - axFrame.origin.y - axFrame.height
        let frame = CGRect(x: axFrame.origin.x, y: cocoaY,
                           width: axFrame.width, height: axFrame.height)
        window.setFrame(frame, display: true)
        window.contentView?.needsDisplay = true
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }
}

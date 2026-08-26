import Cocoa

final class LiveInspectorPanel {
    private let panel: NSPanel
    private let processValue = NSTextField(labelWithString: "Waiting for a target…")
    private let pidValue = NSTextField(labelWithString: "—")
    private let elementValue = NSTextField(labelWithString: "—")
    private let titleValue = NSTextField(labelWithString: "—")
    private let frameValue = NSTextField(labelWithString: "—")
    private let apiValue = NSTextField(labelWithString: "AXUIElementCopyElementAtPosition")

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 245),
            styleMask: [.titled, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.title = "MacSpy Live Inspector"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true

        let header = NSTextField(labelWithString: "LIVE TARGET PARAMETERS")
        header.font = .systemFont(ofSize: 11, weight: .bold)
        header.textColor = .secondaryLabelColor

        let rows = [
            makeRow(label: "Process", value: processValue),
            makeRow(label: "PID", value: pidValue),
            makeRow(label: "Element", value: elementValue),
            makeRow(label: "Title / Value", value: titleValue),
            makeRow(label: "Frame", value: frameValue),
            makeRow(label: "Latest API", value: apiValue),
        ]
        let stack = NSStackView(views: [header] + rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        guard let contentView = panel.contentView else { return }
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])
    }

    func showWaiting() {
        processValue.stringValue = "Move the pointer over Outlook"
        pidValue.stringValue = "—"
        elementValue.stringValue = "Waiting for Accessibility data"
        titleValue.stringValue = "—"
        frameValue.stringValue = "—"
        apiValue.stringValue = "AXUIElementCopyElementAtPosition"
        positionNearTopRight()
        panel.orderFrontRegardless()
    }

    func update(
        process: String,
        pid: pid_t,
        role: String,
        title: String,
        frame: CGRect?
    ) {
        processValue.stringValue = process
        pidValue.stringValue = "\(pid)"
        elementValue.stringValue = role
        titleValue.stringValue = title.isEmpty || title == "—" ? "Untitled" : title
        frameValue.stringValue = frame.map {
            "x \(Int($0.minX)), y \(Int($0.minY)), \(Int($0.width)) × \(Int($0.height))"
        } ?? "Unavailable"
        apiValue.stringValue = "AXUIElementCopyElementAtPosition → AXUIElementCopyAttributeValue"
        positionNearTopRight()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func makeRow(label: String, value: NSTextField) -> NSView {
        let name = NSTextField(labelWithString: label)
        name.font = .systemFont(ofSize: 11, weight: .semibold)
        name.textColor = .secondaryLabelColor
        name.alignment = .right
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: 88).isActive = true

        value.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        value.lineBreakMode = .byTruncatingMiddle
        value.maximumNumberOfLines = 1
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [name, value])
        row.orientation = .horizontal
        row.spacing = 10
        return row
    }

    private func positionNearTopRight() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: {
            NSMouseInRect(mouseLocation, $0.frame, false)
        }) ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }

        let origin = NSPoint(
            x: visibleFrame.maxX - panel.frame.width - 18,
            y: visibleFrame.maxY - panel.frame.height - 18)
        panel.setFrameOrigin(origin)
    }
}

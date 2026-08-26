//  MainWindowController.swift
//  MacSpy
//
//  The main Spy++-style window: a tree of running apps / AX elements on the
//  left, an attribute table on the right, a toolbar with Refresh and a
//  cursor "Pick" tool, and a live on-screen highlight.

import Cocoa
import ApplicationServices

final class MainWindowController: NSWindowController {
    private enum BrowserMode: Int {
        case windows
        case processes
    }

    private let inspector = Inspector()
    private let overlay = HighlightOverlay()
    private let eventMonitor = EventMonitor()
    private let liveInspectorPanel = LiveInspectorPanel()

    private var allProcesses: [ProcessRecord] = []
    private var roots: [AXNode] = []
    private var attrRows: [(String, String)] = []
    private var lastHoveredElement: AXUIElement?
    private var lastHoverUpdate = Date.distantPast
    private var hasAutoStartedLiveInspection = false

    private let outline = NSOutlineView()
    private let attrTable = NSTableView()
    private let eventTable = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let targetLabel = NSTextField(labelWithString: "No target selected")
    private let searchField = NSSearchField()
    private let browserModeControl = NSSegmentedControl(
        labels: ["Windows", "Processes"],
        trackingMode: .selectOne,
        target: nil,
        action: nil)
    private var pickButton: NSButton!

    private var pickMonitors: [Any] = []
    private var hoverTimer: Timer?
    private var isPicking = false

    // MARK: Init

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "MacSpy — UI Inspector"
        window.minSize = NSSize(width: 900, height: 560)
        window.center()
        window.setFrameAutosaveName("MacSpyMainWindow")
        self.init(window: window)
        buildUI()
        eventMonitor.onEventsChanged = { [weak self] in
            self?.eventTable.reloadData()
        }
        reloadApps()
        updateStatus()
        DispatchQueue.main.async { [weak self] in
            self?.startLiveInspectionIfPossible()
        }
    }

    // MARK: UI construction

    private func buildUI() {
        guard let window, let contentView = window.contentView else { return }

        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(reloadApps))
        refreshButton.bezelStyle = .rounded
        refreshButton.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: nil)

        pickButton = NSButton(title: "Inspect on Screen", target: self, action: #selector(togglePicking))
        pickButton.bezelStyle = .rounded
        pickButton.setButtonType(.pushOnPushOff)
        pickButton.image = NSImage(
            systemSymbolName: "scope",
            accessibilityDescription: nil)

        let clearEventsButton = NSButton(
            title: "Clear Events",
            target: self,
            action: #selector(clearEvents))
        clearEventsButton.bezelStyle = .rounded
        clearEventsButton.image = NSImage(
            systemSymbolName: "trash",
            accessibilityDescription: nil)

        let permissionButton = NSButton(
            title: "Permission",
            target: NSApp.delegate,
            action: #selector(AppDelegate.showAccessibilityPermissionGuide))
        permissionButton.bezelStyle = .rounded
        permissionButton.image = NSImage(
            systemSymbolName: "hand.raised",
            accessibilityDescription: nil)

        searchField.placeholderString = "Filter process name, PID, or path"
        searchField.target = self
        searchField.action = #selector(filterProcesses)
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 240).isActive = true

        browserModeControl.selectedSegment = BrowserMode.windows.rawValue
        browserModeControl.target = self
        browserModeControl.action = #selector(browserModeChanged)
        browserModeControl.setWidth(92, forSegment: 0)
        browserModeControl.setWidth(92, forSegment: 1)

        let hint = NSTextField(
            labelWithString: "Live Hover stays active while you use Outlook; press Esc or toggle the button to stop.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.lineBreakMode = .byTruncatingTail

        let toolbar = NSStackView(
            views: [
                refreshButton,
                pickButton,
                clearEventsButton,
                permissionButton,
                browserModeControl,
                searchField,
                hint,
            ])
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let treeColumn = NSTableColumn(identifier: .init("tree"))
        treeColumn.title = "System Windows"
        treeColumn.width = 650
        outline.addTableColumn(treeColumn)
        outline.outlineTableColumn = treeColumn
        outline.headerView = NSTableHeaderView()
        outline.dataSource = self
        outline.delegate = self
        outline.rowSizeStyle = .default
        outline.usesAlternatingRowBackgroundColors = true
        outline.autosaveExpandedItems = false

        let outlineScroll = NSScrollView()
        outlineScroll.documentView = outline
        outlineScroll.hasVerticalScroller = true
        outlineScroll.hasHorizontalScroller = true
        outlineScroll.autohidesScrollers = true

        let nameCol = NSTableColumn(identifier: .init("attr"))
        nameCol.title = "Property"
        nameCol.width = 200
        let valueCol = NSTableColumn(identifier: .init("value"))
        valueCol.title = "Value"
        valueCol.width = 360
        attrTable.addTableColumn(nameCol)
        attrTable.addTableColumn(valueCol)
        attrTable.dataSource = self
        attrTable.delegate = self
        attrTable.usesAlternatingRowBackgroundColors = true
        attrTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let attrScroll = NSScrollView()
        attrScroll.documentView = attrTable
        attrScroll.hasVerticalScroller = true
        attrScroll.autohidesScrollers = true

        targetLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        targetLabel.textColor = .labelColor
        targetLabel.lineBreakMode = .byTruncatingMiddle

        let detailsHeader = makeSectionHeader(
            title: "INSPECTOR",
            trailingView: targetLabel)
        let detailsPane = NSStackView(views: [detailsHeader, attrScroll])
        detailsPane.orientation = .vertical
        detailsPane.spacing = 0

        let timeColumn = NSTableColumn(identifier: .init("eventTime"))
        timeColumn.title = "Time"
        timeColumn.width = 86
        let eventColumn = NSTableColumn(identifier: .init("eventName"))
        eventColumn.title = "Call / Event"
        eventColumn.width = 190
        let sourceColumn = NSTableColumn(identifier: .init("eventSource"))
        sourceColumn.title = "Source"
        sourceColumn.width = 180
        let detailsColumn = NSTableColumn(identifier: .init("eventDetails"))
        detailsColumn.title = "Details"
        detailsColumn.width = 400
        [timeColumn, eventColumn, sourceColumn, detailsColumn].forEach {
            eventTable.addTableColumn($0)
        }
        eventTable.dataSource = self
        eventTable.delegate = self
        eventTable.usesAlternatingRowBackgroundColors = true
        eventTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let eventScroll = NSScrollView()
        eventScroll.documentView = eventTable
        eventScroll.hasVerticalScroller = true
        eventScroll.hasHorizontalScroller = true
        eventScroll.autohidesScrollers = true

        let eventsHeader = makeSectionHeader(
            title: "MACSPY APPLE API TRACE & TARGET EVENTS",
            trailingView: NSTextField(
                labelWithString: "MacSpy API calls + public AXObserver notifications · newest first"))
        let eventsPane = NSStackView(views: [eventsHeader, eventScroll])
        eventsPane.orientation = .vertical
        eventsPane.spacing = 0

        let rightSplit = NSSplitView()
        rightSplit.isVertical = false
        rightSplit.dividerStyle = .thin
        rightSplit.addArrangedSubview(detailsPane)
        rightSplit.addArrangedSubview(eventsPane)

        let browserHeader = makeSectionHeader(
            title: "SYSTEM WINDOWS",
            trailingView: NSTextField(labelWithString: "Desktop → Window → Accessibility element"))
        let browserPane = NSStackView(views: [browserHeader, outlineScroll])
        browserPane.orientation = .vertical
        browserPane.spacing = 0

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(browserPane)
        split.addArrangedSubview(rightSplit)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        let statusBar = NSStackView(views: [statusLabel])
        statusBar.orientation = .horizontal
        statusBar.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [toolbar, split, statusBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            split.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setPosition(650, ofDividerAt: 0)
        rightSplit.setPosition(300, ofDividerAt: 0)
    }

    private func makeSectionHeader(title: String, trailingView: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .bold)
        label.textColor = .secondaryLabelColor
        let spacer = NSView()
        let stack = NSStackView(views: [label, spacer, trailingView])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        trailingView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return stack
    }

    // MARK: App list

    @objc private func reloadApps() {
        inspector.reloadSystemSnapshot()
        allProcesses = inspector.processes().sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame ? $0.pid < $1.pid : comparison == .orderedAscending
        }
        filterProcesses()
    }

    @objc private func filterProcesses() {
        let query = searchField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? allProcesses : allProcesses.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || String($0.pid).contains(query)
                || $0.executablePath.localizedCaseInsensitiveContains(query)
        }
        if browserMode == .windows {
            roots = [
                AXNode.systemWindowsRoot(
                    processes: filtered,
                    inspector: inspector),
            ]
        } else {
            roots = filtered.map { AXNode.processRoot($0, inspector: inspector) }
        }
        outline.reloadData()
        if browserMode == .windows, let root = roots.first {
            outline.expandItem(root)
        }
        updateStatus()
    }

    private var browserMode: BrowserMode {
        BrowserMode(rawValue: browserModeControl.selectedSegment) ?? .windows
    }

    @objc private func browserModeChanged() {
        let windowsMode = browserMode == .windows
        outline.tableColumns.first?.title = windowsMode
            ? "System Windows"
            : "Processes / Threads / Windows / Elements"
        filterProcesses()
    }

    private func updateStatus() {
        let trusted = inspector.isTrusted
        let perm = trusted
            ? "Accessibility: granted"
            : "Accessibility: NOT granted — enable MacSpy in System Settings ▸ Privacy & Security ▸ Accessibility"
        let objectSummary = browserMode == .windows
            ? "\(roots.first?.children().count ?? 0) windows from \(allProcesses.count) processes"
            : "\(roots.count) of \(allProcesses.count) processes"
        statusLabel.stringValue = "\(objectSummary) · \(perm)"
        statusLabel.textColor = trusted ? .secondaryLabelColor : .systemRed
    }

    func accessibilityPermissionDidChange() {
        updateStatus()
        startLiveInspectionIfPossible()
    }

    private func startLiveInspectionIfPossible() {
        guard inspector.isTrusted,
              !isPicking,
              !hasAutoStartedLiveInspection else { return }
        hasAutoStartedLiveInspection = true
        startPicking()
    }

    // MARK: Attribute display

    private func showAttributes(for node: AXNode?) {
        attrRows = node?.attributes ?? []
        attrTable.reloadData()
        targetLabel.stringValue = node?.displayName ?? "No target selected"
        if let node, node.process.pid > 0 {
            eventMonitor.observe(
                pid: node.process.pid,
                applicationName: node.process.name)
            if let element = node.element {
                eventMonitor.observe(element: element)
            }
        }
        if let frame = node?.frame {
            overlay.show(axFrame: frame)
        } else {
            overlay.hide()
        }
    }

    // MARK: Picker

    @objc private func togglePicking() {
        isPicking ? stopPicking() : startPicking()
    }

    private func startPicking() {
        guard inspector.isTrusted else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
            pickButton.state = .off
            updateStatus()
            return
        }
        isPicking = true
        pickButton.state = .on
        lastHoveredElement = nil
        statusLabel.stringValue = "Live Hover active — move over Outlook to inspect continuously; press Esc to stop."

        let key = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            if e.keyCode == 53 { self?.stopPicking(); return nil }
            return e
        }
        pickMonitors = [key].compactMap { $0 }

        let timer = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in
            self?.highlightUnderCursor()
        }
        hoverTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        timer.fire()
        liveInspectorPanel.showWaiting()
    }

    private func stopPicking() {
        isPicking = false
        pickButton.state = .off
        pickMonitors.forEach { NSEvent.removeMonitor($0) }
        pickMonitors.removeAll()
        hoverTimer?.invalidate()
        hoverTimer = nil
        liveInspectorPanel.hide()
        updateStatus()
    }

    private func currentCursorAXPoint() -> CGPoint {
        if let event = CGEvent(source: nil) {
            return event.location
        }
        let loc = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: loc.x, y: primaryHeight - loc.y)
    }

    private func highlightUnderCursor() {
        let point = currentCursorAXPoint()
        guard isPicking, let el = inspector.element(at: point) else { return }
        let now = Date()
        guard now.timeIntervalSince(lastHoverUpdate) >= 0.08 else { return }
        lastHoverUpdate = now
        if let lastHoveredElement, CFEqual(lastHoveredElement, el) { return }
        lastHoveredElement = el

        let frame = inspector.frame(el)
        if let frame { overlay.show(axFrame: frame) }
        guard let pid = inspector.pid(of: el) else { return }
        var process = allProcesses.first(where: { $0.pid == pid })
        if process == nil {
            searchField.stringValue = ""
            reloadApps()
            process = allProcesses.first(where: { $0.pid == pid })
            statusLabel.stringValue = "Live Hover active — discovered a new process and refreshed the system snapshot."
        }
        guard let process else { return }

        let node = AXNode(kind: .element(el, process: process), inspector: inspector)
        let role = inspector.role(el)
        let title = inspector.title(el)
        showAttributes(for: node)
        liveInspectorPanel.update(
            process: process.name,
            pid: pid,
            role: role,
            title: title,
            frame: frame)
        eventMonitor.recordInspection(
            point: point,
            pid: pid,
            process: "\(process.name) [\(pid)]",
            role: role,
            title: title,
            frame: frame)
    }

    @objc private func clearEvents() {
        eventMonitor.clear()
    }
}

// MARK: - Outline data source / delegate

extension MainWindowController: NSOutlineViewDataSource, NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? AXNode else { return roots.count }
        return node.children().count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? AXNode else { return roots[index] }
        return node.children()[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? AXNode else { return false }
        return node.hasChildren
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? AXNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("treeCell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingTail
            c.addSubview(image)
            c.addSubview(text)
            c.imageView = image
            c.textField = text
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
                text.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            c.identifier = id
            return c
        }()
        cell.textField?.stringValue = node.displayName
        cell.imageView?.image = node.icon
        cell.toolTip = node.displayName
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outline.selectedRow
        let node = row >= 0 ? outline.item(atRow: row) as? AXNode : nil
        showAttributes(for: node)
    }
}

// MARK: - Attribute table data source / delegate

extension MainWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === eventTable ? eventMonitor.events.count : attrRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === eventTable {
            return eventCell(tableColumn: tableColumn, row: row)
        }
        let (name, value) = attrRows[row]
        let isName = tableColumn?.identifier.rawValue == "attr"
        let id = NSUserInterfaceItemIdentifier("attrCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let t = NSTextField(labelWithString: "")
            t.identifier = id
            t.lineBreakMode = .byTruncatingTail
            t.isSelectable = true
            return t
        }()
        cell.stringValue = isName ? name : value
        cell.font = isName ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12)
        cell.textColor = isName ? .labelColor : .secondaryLabelColor
        return cell
    }

    private func eventCell(tableColumn: NSTableColumn?, row: Int) -> NSView {
        let event = eventMonitor.events[row]
        let identifier = tableColumn?.identifier.rawValue ?? "event"
        let cellID = NSUserInterfaceItemIdentifier("eventCell-\(identifier)")
        let cell = (eventTable.makeView(withIdentifier: cellID, owner: self) as? NSTextField) ?? {
            let text = NSTextField(labelWithString: "")
            text.identifier = cellID
            text.lineBreakMode = .byTruncatingTail
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            text.isSelectable = true
            return text
        }()
        switch identifier {
        case "eventTime":
            cell.stringValue = Self.eventTimeFormatter.string(from: event.timestamp)
        case "eventName":
            cell.stringValue = event.name
        case "eventSource":
            cell.stringValue = event.source
        default:
            cell.stringValue = event.details
        }
        cell.toolTip = cell.stringValue
        return cell
    }

    private static let eventTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

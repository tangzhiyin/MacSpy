import Cocoa
import ApplicationServices

struct InspectionEvent {
    let timestamp: Date
    let name: String
    let source: String
    let details: String
}

final class EventMonitor {
    var onEventsChanged: (() -> Void)?

    private(set) var events: [InspectionEvent] = []
    private var observer: AXObserver?
    private var observedApplication: AXUIElement?
    private var observedElement: AXUIElement?
    private var observedPID: pid_t?

    private static let applicationNotifications: [String] = [
        kAXApplicationActivatedNotification,
        kAXApplicationDeactivatedNotification,
        kAXFocusedWindowChangedNotification,
        kAXFocusedUIElementChangedNotification,
        kAXWindowCreatedNotification,
    ]

    private static let elementNotifications: [String] = [
        kAXUIElementDestroyedNotification,
        kAXTitleChangedNotification,
        kAXValueChangedNotification,
        kAXMovedNotification,
        kAXResizedNotification,
        kAXSelectedChildrenChangedNotification,
    ]

    func observe(pid: pid_t, applicationName: String) {
        guard observedPID != pid else { return }
        stop()

        var newObserver: AXObserver?
        let error = AXObserverCreate(pid, Self.callback, &newObserver)
        guard error == .success, let newObserver else {
            append(
                name: "Observer unavailable",
                source: applicationName,
                details: "AXObserverCreate(pid: \(pid)) returned \(error.rawValue)")
            return
        }

        let application = AXUIElementCreateApplication(pid)
        observer = newObserver
        observedApplication = application
        observedPID = pid

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        for notification in Self.applicationNotifications {
            AXObserverAddNotification(
                newObserver,
                application,
                notification as CFString,
                context)
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(newObserver),
            .commonModes)
        append(
            name: "Observer attached",
            source: applicationName,
            details: "Listening for public Accessibility notifications from PID \(pid)")
    }

    func observe(element: AXUIElement) {
        guard let observer else { return }
        if let observedElement, CFEqual(observedElement, element) { return }
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        if let observedElement {
            for notification in Self.elementNotifications {
                AXObserverRemoveNotification(
                    observer,
                    observedElement,
                    notification as CFString)
            }
        }
        observedElement = element
        for notification in Self.elementNotifications {
            AXObserverAddNotification(
                observer,
                element,
                notification as CFString,
                context)
        }
    }

    func recordInspection(
        point: CGPoint,
        pid: pid_t,
        process: String,
        role: String,
        title: String,
        frame: CGRect?
    ) {
        let frameDescription = frame.map {
            "(\(Int($0.minX)), \(Int($0.minY)), \(Int($0.width))×\(Int($0.height)))"
        } ?? "unavailable"
        recordCall(
            api: "AXUIElementCopyAttributeNames",
            source: process,
            parameters: "element=\(role)",
            result: "attribute list loaded")
        recordCall(
            api: "AXUIElementCopyAttributeValue",
            source: process,
            parameters: "attributes=AXRole, AXTitle, AXPosition, AXSize",
            result: "role=\(role), title=“\(title)”, frame=\(frameDescription)")
        recordCall(
            api: "AXUIElementGetPid",
            source: process,
            parameters: "element=\(role)",
            result: "pid=\(pid)")
        recordCall(
            api: "AXUIElementCopyElementAtPosition",
            source: "System-wide AX element",
            parameters: "x=\(Int(point.x)), y=\(Int(point.y))",
            result: "\(role) “\(title)”")
    }

    private func recordCall(
        api: String,
        source: String,
        parameters: String,
        result: String
    ) {
        append(
            name: api,
            source: source,
            details: "\(parameters) → \(result)")
    }

    func clear() {
        events.removeAll()
        onEventsChanged?()
    }

    func stop() {
        if let observer, let application = observedApplication {
            if let observedElement {
                for notification in Self.elementNotifications {
                    AXObserverRemoveNotification(
                        observer,
                        observedElement,
                        notification as CFString)
                }
            }
            for notification in Self.applicationNotifications {
                AXObserverRemoveNotification(
                    observer,
                    application,
                    notification as CFString)
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes)
        }
        observer = nil
        observedApplication = nil
        observedElement = nil
        observedPID = nil
    }

    private func received(element: AXUIElement, notification: CFString) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        var roleValue: CFTypeRef?
        var titleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue)
        let role = roleValue as? String ?? "AXUIElement"
        let title = titleValue as? String ?? ""
        let suffix = title.isEmpty ? "" : " · “\(title)”"
        append(
            name: notification as String,
            source: "\(role) · PID \(pid)",
            details: "AXObserver callback\(suffix)")
    }

    private func append(name: String, source: String, details: String) {
        events.insert(
            InspectionEvent(
                timestamp: Date(),
                name: name,
                source: source,
                details: details),
            at: 0)
        if events.count > 500 {
            events.removeLast(events.count - 500)
        }
        onEventsChanged?()
    }

    private static let callback: AXObserverCallback = {
        _, element, notification, context in
        guard let context else { return }
        let monitor = Unmanaged<EventMonitor>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async {
            monitor.received(element: element, notification: notification)
        }
    }
}

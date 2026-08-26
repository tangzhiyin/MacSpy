//  Inspector.swift
//  MacSpy
//
//  Created by Crisp on 2026/6/13.
//


import Cocoa
import ApplicationServices

struct ProcessRecord {
    let pid: pid_t
    let parentPID: pid_t
    let name: String
    let executablePath: String
    let app: NSRunningApplication?
}

struct ThreadRecord {
    let id: UInt64
    let name: String
    let cpuPercent: Double
    let runState: String
    let priority: Int32
    let userTime: UInt64
    let systemTime: UInt64
}

struct WindowRecord {
    let number: Int
    let title: String
    let layer: Int
    let alpha: Double
    let isOnScreen: Bool
    let frame: CGRect
    let element: AXUIElement?
}

final class Inspector {
    private static let axWindowNumberAttribute = "AXWindowNumber"
    private let systemWide = AXUIElementCreateSystemWide()
    private var windowsByPID: [pid_t: [WindowRecord]] = [:]

    var isTrusted: Bool { AXIsProcessTrusted() }

    // MARK: System snapshot

    func reloadSystemSnapshot() {
        windowsByPID = Dictionary(grouping: Self.windowRecords(), by: \.pid)
            .mapValues { records in records.map(\.window) }
    }

    func processes() -> [ProcessRecord] {
        let capacity = max(Int(proc_listallpids(nil, 0)), 1) + 32
        var pids = [pid_t](repeating: 0, count: capacity)
        let returnedCount = pids.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }
        guard returnedCount > 0 else { return [] }

        let count = min(Int(returnedCount), pids.count)
        let apps = Dictionary(
            uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map {
                ($0.processIdentifier, $0)
            })

        return pids.prefix(count).filter { $0 > 0 }.compactMap { pid in
            var bsd = proc_bsdinfo()
            let copied = proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                &bsd,
                Int32(MemoryLayout<proc_bsdinfo>.size))
            guard copied == MemoryLayout<proc_bsdinfo>.size else { return nil }

            let app = apps[pid]
            let path = processPath(pid)
            let name = app?.localizedName
                ?? processName(pid)
                ?? URL(fileURLWithPath: path).lastPathComponent
            guard !name.isEmpty else { return nil }
            return ProcessRecord(
                pid: pid,
                parentPID: pid_t(bsd.pbi_ppid),
                name: name,
                executablePath: path,
                app: app)
        }
    }

    func threads(for pid: pid_t) -> [ThreadRecord] {
        let requiredBytes = proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, nil, 0)
        guard requiredBytes > 0 else { return [] }

        var ids = [UInt64](
            repeating: 0,
            count: (Int(requiredBytes) / MemoryLayout<UInt64>.stride) + 16)
        let copiedBytes = ids.withUnsafeMutableBytes {
            proc_pidinfo(
                pid,
                PROC_PIDLISTTHREADS,
                0,
                $0.baseAddress,
                Int32($0.count))
        }
        guard copiedBytes > 0 else { return [] }

        return ids.prefix(Int(copiedBytes) / MemoryLayout<UInt64>.stride).map { id in
            var info = proc_threadinfo()
            let copied = proc_pidinfo(
                pid,
                PROC_PIDTHREADID64INFO,
                id,
                &info,
                Int32(MemoryLayout<proc_threadinfo>.size))
            let hasInfo = copied == MemoryLayout<proc_threadinfo>.size
            return ThreadRecord(
                id: id,
                name: hasInfo ? Self.string(from: info.pth_name) : "",
                cpuPercent: hasInfo ? Double(info.pth_cpu_usage) / 10.0 : 0,
                runState: hasInfo ? Self.threadState(info.pth_run_state) : "Unavailable",
                priority: hasInfo ? info.pth_curpri : 0,
                userTime: hasInfo ? info.pth_user_time : 0,
                systemTime: hasInfo ? info.pth_system_time : 0)
        }
    }

    func windows(for pid: pid_t) -> [WindowRecord] {
        windowsByPID[pid] ?? []
    }

    func element(at point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(
            systemWide, Float(point.x), Float(point.y), &element)
        return err == .success ? element : nil
    }

    func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    func windowNumber(_ element: AXUIElement) -> Int? {
        rawAttribute(element, Self.axWindowNumberAttribute) as? Int
    }

    func windowAncestor(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<100 {
            guard let candidate = current else { return nil }
            if role(candidate) == (kAXWindowRole as String) { return candidate }
            current = parent(candidate)
        }
        return nil
    }

    // MARK: Accessibility attributes

    func attributeNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let arr = names as? [String] else { return [] }
        return arr.sorted()
    }

    func attributeValue(_ element: AXUIElement, _ name: String) -> String {
        guard let value = rawAttribute(element, name) else { return "—" }
        return Self.describe(value)
    }

    func allAttributes(_ element: AXUIElement) -> [(String, String)] {
        attributeNames(element).map { ($0, attributeValue(element, $0)) }
    }

    func actionNames(_ element: AXUIElement) -> [String] {
        var actions: CFArray?
        guard AXUIElementCopyActionNames(element, &actions) == .success,
              let names = actions as? [String] else { return [] }
        return names.sorted()
    }

    func role(_ element: AXUIElement) -> String { attributeValue(element, kAXRoleAttribute as String) }
    func title(_ element: AXUIElement) -> String { attributeValue(element, kAXTitleAttribute as String) }
    func value(_ element: AXUIElement) -> String { attributeValue(element, kAXValueAttribute as String) }

    func frame(_ element: AXUIElement) -> CGRect? {
        guard let posRef = rawAttribute(element, kAXPositionAttribute as String),
              let sizeRef = rawAttribute(element, kAXSizeAttribute as String),
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    func parent(_ element: AXUIElement) -> AXUIElement? {
        guard let ref = rawAttribute(element, kAXParentAttribute as String),
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    func children(_ element: AXUIElement) -> [AXUIElement] {
        guard let ref = rawAttribute(element, kAXChildrenAttribute as String),
              let arr = ref as? [AXUIElement] else { return [] }
        return arr
    }

    func ancestry(_ element: AXUIElement) -> [AXUIElement] {
        var chain: [AXUIElement] = []
        var current: AXUIElement? = element
        while let el = current, chain.count < 100 {
            chain.append(el)
            current = parent(el)
        }
        return chain.reversed()
    }

    private func rawAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &value) == .success else { return nil }
        return value
    }

    private func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    private func processPath(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : ""
    }

    private static func windowRecords() -> [(pid: pid_t, window: WindowRecord)] {
        guard let rawWindows = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID) as? [[CFString: Any]] else { return [] }

        let runningApps = Dictionary(
            uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map {
                ($0.processIdentifier, $0)
            })
        var axWindowsByPID: [pid_t: [Int: AXUIElement]] = [:]

        return rawWindows.compactMap { info in
            guard let pidNumber = info[kCGWindowOwnerPID] as? NSNumber,
                  let number = (info[kCGWindowNumber] as? NSNumber)?.intValue,
                  let boundsInfo = info[kCGWindowBounds] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary)
            else { return nil }

            let pid = pid_t(pidNumber.int32Value)
            if axWindowsByPID[pid] == nil, runningApps[pid] != nil {
                let appElement = AXUIElementCreateApplication(pid)
                var value: CFTypeRef?
                var indexed: [Int: AXUIElement] = [:]
                if AXUIElementCopyAttributeValue(
                    appElement,
                    kAXWindowsAttribute as CFString,
                    &value) == .success,
                   let elements = value as? [AXUIElement] {
                    for element in elements {
                        var numberValue: CFTypeRef?
                        if AXUIElementCopyAttributeValue(
                            element,
                            axWindowNumberAttribute as CFString,
                            &numberValue) == .success,
                           let windowNumber = numberValue as? Int {
                            indexed[windowNumber] = element
                        }
                    }
                }
                axWindowsByPID[pid] = indexed
            }

            return (
                pid,
                WindowRecord(
                    number: number,
                    title: info[kCGWindowName] as? String ?? "Untitled",
                    layer: (info[kCGWindowLayer] as? NSNumber)?.intValue ?? 0,
                    alpha: (info[kCGWindowAlpha] as? NSNumber)?.doubleValue ?? 1,
                    isOnScreen: (info[kCGWindowIsOnscreen] as? NSNumber)?.boolValue ?? false,
                    frame: frame,
                    element: axWindowsByPID[pid]?[number]))
        }
    }

    private static func string<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    private static func threadState(_ state: Int32) -> String {
        switch state {
        case 1: return "Running"
        case 2: return "Stopped"
        case 3: return "Waiting"
        case 4: return "Uninterruptible"
        case 5: return "Halted"
        default: return "Unknown (\(state))"
        }
    }

    private static func describe(_ value: CFTypeRef) -> String {
        let typeID = CFGetTypeID(value)
        switch typeID {
        case CFStringGetTypeID():
            return value as! String
        case CFBooleanGetTypeID():
            return (value as! Bool) ? "true" : "false"
        case CFNumberGetTypeID():
            return "\(value as! NSNumber)"
        case AXValueGetTypeID():
            return describeAXValue(value as! AXValue)
        case AXUIElementGetTypeID():
            return "<AXUIElement>"
        case CFArrayGetTypeID():
            return "[\((value as! NSArray).count) items]"
        default:
            return String(describing: value)
        }
    }

    private static func describeAXValue(_ value: AXValue) -> String {
        switch AXValueGetType(value) {
        case .cgPoint:
            var p = CGPoint.zero; AXValueGetValue(value, .cgPoint, &p)
            return "(\(Int(p.x)), \(Int(p.y)))"
        case .cgSize:
            var s = CGSize.zero; AXValueGetValue(value, .cgSize, &s)
            return "\(Int(s.width)) × \(Int(s.height))"
        case .cgRect:
            var r = CGRect.zero; AXValueGetValue(value, .cgRect, &r)
            return "(\(Int(r.minX)), \(Int(r.minY)), \(Int(r.width)) × \(Int(r.height)))"
        case .cfRange:
            var rng = CFRange(); AXValueGetValue(value, .cfRange, &rng)
            return "{loc \(rng.location), len \(rng.length)}"
        default:
            return "<AXValue>"
        }
    }
}

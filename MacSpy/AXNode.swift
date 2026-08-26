import Cocoa
import ApplicationServices

final class AXNode {
    enum Kind {
        case systemWindows(ProcessRecord, processes: [ProcessRecord])
        case process(ProcessRecord)
        case category(title: String, process: ProcessRecord, category: Category)
        case thread(ThreadRecord, process: ProcessRecord)
        case window(WindowRecord, process: ProcessRecord)
        case element(AXUIElement, process: ProcessRecord)
    }

    enum Category {
        case threads
        case windows
    }

    let kind: Kind
    private let inspector: Inspector
    private var loadedChildren: [AXNode]?

    init(kind: Kind, inspector: Inspector) {
        self.kind = kind
        self.inspector = inspector
    }

    static func processRoot(_ process: ProcessRecord, inspector: Inspector) -> AXNode {
        AXNode(kind: .process(process), inspector: inspector)
    }

    static func systemWindowsRoot(
        processes: [ProcessRecord],
        inspector: Inspector
    ) -> AXNode {
        let desktop = ProcessRecord(
            pid: 0,
            parentPID: 0,
            name: "Desktop",
            executablePath: "",
            app: nil)
        return AXNode(
            kind: .systemWindows(desktop, processes: processes),
            inspector: inspector)
    }

    var process: ProcessRecord {
        switch kind {
        case .systemWindows(let process, _),
             .process(let process),
             .category(_, let process, _),
             .thread(_, let process),
             .window(_, let process),
             .element(_, let process):
            return process
        }
    }

    var element: AXUIElement? {
        switch kind {
        case .window(let window, _): return window.element
        case .element(let element, _): return element
        default: return nil
        }
    }

    var windowNumber: Int? {
        switch kind {
        case .window(let window, _): return window.number
        case .element(let element, _): return inspector.windowNumber(element)
        default: return nil
        }
    }

    func children(reload: Bool = false) -> [AXNode] {
        if reload { loadedChildren = nil }
        if let loadedChildren { return loadedChildren }

        let result: [AXNode]
        switch kind {
        case .systemWindows(_, let processes):
            result = processes.flatMap { process in
                inspector.windows(for: process.pid).map {
                    AXNode(kind: .window($0, process: process), inspector: inspector)
                }
            }.sorted {
                guard case .window(let lhs, _) = $0.kind,
                      case .window(let rhs, _) = $1.kind else { return false }
                if lhs.isOnScreen != rhs.isOnScreen { return lhs.isOnScreen }
                if lhs.layer != rhs.layer { return lhs.layer < rhs.layer }
                return lhs.number < rhs.number
            }
        case .process(let process):
            result = [
                AXNode(
                    kind: .category(
                        title: "Threads",
                        process: process,
                        category: .threads),
                    inspector: inspector),
                AXNode(
                    kind: .category(
                        title: "Windows",
                        process: process,
                        category: .windows),
                    inspector: inspector),
            ]
        case .category(_, let process, .threads):
            result = inspector.threads(for: process.pid).map {
                AXNode(kind: .thread($0, process: process), inspector: inspector)
            }
        case .category(_, let process, .windows):
            result = inspector.windows(for: process.pid).map {
                AXNode(kind: .window($0, process: process), inspector: inspector)
            }
        case .window(let window, let process):
            result = window.element.map { element in
                inspector.children(element).map {
                    AXNode(kind: .element($0, process: process), inspector: inspector)
                }
            } ?? []
        case .element(let element, let process):
            result = inspector.children(element).map {
                AXNode(kind: .element($0, process: process), inspector: inspector)
            }
        case .thread:
            result = []
        }

        loadedChildren = result
        return result
    }

    var hasChildren: Bool {
        switch kind {
        case .systemWindows, .process, .category:
            return true
        case .window(let window, _):
            return window.element != nil && !children().isEmpty
        case .element:
            return !children().isEmpty
        case .thread:
            return false
        }
    }

    var displayName: String {
        switch kind {
        case .systemWindows:
            return "Desktop — System Windows (\(children().count))"
        case .process(let process):
            return "\(process.name)  [\(process.pid)]"
        case .category(let title, _, .threads):
            let count = children().count
            return "\(title) (\(count))"
        case .category(let title, _, .windows):
            let count = children().count
            return "\(title) (\(count))"
        case .thread(let thread, _):
            let name = thread.name.isEmpty ? "" : " — \(thread.name)"
            return "Thread \(thread.id)\(name)"
        case .window(let window, _):
            return "Window \(window.number) — \(window.title)"
        case .element(let element, _):
            let role = inspector.role(element)
            let title = inspector.title(element)
            let value = inspector.value(element)
            if title != "—", !title.isEmpty { return "\(role) “\(title)”" }
            if value != "—", !value.isEmpty, value.count < 60 {
                return "\(role) “\(value)”"
            }
            return role
        }
    }

    var icon: NSImage? {
        switch kind {
        case .systemWindows:
            return NSImage(
                systemSymbolName: "macbook.and.iphone",
                accessibilityDescription: nil)
        case .process(let process):
            return process.app?.icon
                ?? NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)
        case .category(_, _, .threads), .thread:
            return NSImage(systemSymbolName: "circle.grid.cross", accessibilityDescription: nil)
        case .category(_, _, .windows), .window:
            return NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        case .element:
            return NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil)
        }
    }

    var frame: CGRect? {
        switch kind {
        case .systemWindows:
            return nil
        case .window(let window, _): return window.frame
        case .element(let element, _): return inspector.frame(element)
        default: return nil
        }
    }

    var attributes: [(String, String)] {
        switch kind {
        case .systemWindows:
            return [
                ("Type", "System Windows root"),
                ("Relationship", "Desktop → Window → Accessibility hierarchy"),
                ("Window count", "\(children().count)"),
                ("API", "CGWindowListCopyWindowInfo"),
                ("Note", "Windows are ordered by on-screen state, layer, and window number."),
            ]
        case .process(let process):
            return [
                ("Type", "Process"),
                ("Name", process.name),
                ("PID", "\(process.pid)"),
                ("Parent PID", "\(process.parentPID)"),
                ("Executable", process.executablePath.isEmpty ? "Unavailable" : process.executablePath),
                ("Bundle ID", process.app?.bundleIdentifier ?? "Unavailable"),
            ]
        case .category(_, let process, .threads):
            return [
                ("Relationship", "Process \(process.pid) → Threads"),
                ("Thread count", "\(children().count)"),
                ("Note", "macOS does not publicly expose a reliable window-to-thread mapping."),
            ]
        case .category(_, let process, .windows):
            return [
                ("Relationship", "Process \(process.pid) → Windows"),
                ("Window count", "\(children().count)"),
            ]
        case .thread(let thread, let process):
            return [
                ("Type", "Thread"),
                ("Relationship", "Process \(process.pid) → Thread \(thread.id)"),
                ("Thread ID", "\(thread.id)"),
                ("Name", thread.name.isEmpty ? "Unnamed" : thread.name),
                ("State", thread.runState),
                ("CPU", String(format: "%.1f%%", thread.cpuPercent)),
                ("Priority", "\(thread.priority)"),
                ("User time", "\(thread.userTime) ns"),
                ("System time", "\(thread.systemTime) ns"),
            ]
        case .window(let window, let process):
            var rows: [(String, String)] = [
                ("Type", "Window"),
                ("Relationship", "Process \(process.pid) → Window \(window.number)"),
                ("Window number", "\(window.number)"),
                ("Title", window.title),
                ("Layer", "\(window.layer)"),
                ("On screen", window.isOnScreen ? "true" : "false"),
                ("Alpha", String(format: "%.2f", window.alpha)),
                ("Frame", Self.describe(window.frame)),
            ]
            if let element = window.element {
                rows.append(contentsOf: inspector.allAttributes(element))
            }
            return rows
        case .element(let element, let process):
            return [
                ("Type", "Accessibility element"),
                ("Relationship", "Process \(process.pid) → Window → AX hierarchy"),
                ("API trace", "See “MACSPY APPLE API TRACE & TARGET EVENTS” below"),
                ("Trace scope", "Apple APIs invoked by MacSpy plus public target AX notifications"),
                ("Supported actions", inspector.actionNames(element).joined(separator: ", ")),
            ] + inspector.allAttributes(element)
        }
    }

    private static func describe(_ rect: CGRect) -> String {
        "x \(Int(rect.minX)), y \(Int(rect.minY)), \(Int(rect.width)) × \(Int(rect.height))"
    }
}

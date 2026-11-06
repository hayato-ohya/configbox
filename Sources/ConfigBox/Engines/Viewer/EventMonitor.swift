import AppKit
import Combine

struct InputEventRecord: Identifiable {
    let id: Int
    let time: Date
    let type: String
    let keyCode: Int?
    let name: String
    let modifiers: String
    let flags: String
    let app: String
    let note: String
}

struct TouchPoint: Identifiable {
    let id: Int
    let x: CGFloat
    let y: CGFloat
    let size: CGFloat
    let state: Int
}

/// Karabiner-EventViewer equivalent: live feed of keyboard events, gestures and trackpad touches.
/// Recording only happens while a viewer is open, so the resident cost is a single boolean check.
final class EventMonitor: ObservableObject {
    static let shared = EventMonitor()

    @Published private(set) var records: [InputEventRecord] = []
    @Published var paused = false
    @Published var showKeyUp = true
    @Published private(set) var touches: [TouchPoint] = []
    @Published private(set) var lastGesture = "—"
    @Published private(set) var fingerCount = 0

    /// Toggled by the viewer window. Read from the event tap thread (main).
    var isActive = false
    var trackpadViewerActive = false { didSet { NotificationCenter.default.post(name: .configBoxReconcile, object: nil) } }

    private var counter = 0
    private let limit = 400
    private var lastTouchPublish: CFAbsoluteTime = 0

    private init() {}

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    static func format(_ d: Date) -> String { time.string(from: d) }

    func record(type: CGEventType, event: CGEvent, note: String) {
        guard isActive, !paused else { return }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let typeName: String
        switch type {
        case .keyDown: typeName = event.getIntegerValueField(.keyboardEventAutorepeat) != 0 ? "key_repeat" : "key_down"
        case .keyUp: if !showKeyUp { return }; typeName = "key_up"
        case .flagsChanged: typeName = "flags_changed"
        default: return
        }
        append(InputEventRecord(id: nextID(), time: Date(), type: typeName, keyCode: code,
                                name: KeyCodes.name(for: UInt16(truncatingIfNeeded: code)),
                                modifiers: KeyCodes.modifiers(for: UInt16(truncatingIfNeeded: code), flags: event.flags).symbols,
                                flags: String(format: "0x%llX", event.flags.rawValue),
                                app: NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
                                note: note))
    }

    func record(gesture: Gesture, handled: Bool) {
        lastGesture = gesture.display
        guard isActive, !paused else { return }
        append(InputEventRecord(id: nextID(), time: Date(), type: "gesture", keyCode: nil, name: gesture.display,
                                modifiers: "", flags: "", app: NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
                                note: handled ? "→ trigger" : "no trigger"))
    }

    func record(custom: String, note: String = "") {
        guard isActive, !paused else { return }
        append(InputEventRecord(id: nextID(), time: Date(), type: "info", keyCode: nil, name: custom, modifiers: "", flags: "", app: "", note: note))
    }

    /// Called from the multitouch thread.
    func publish(touches: [TouchPoint]) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastTouchPublish > 1.0 / 60 || touches.isEmpty else { return }
        lastTouchPublish = now
        DispatchQueue.main.async {
            self.touches = touches
            self.fingerCount = touches.count
        }
    }

    func clear() { records.removeAll() }

    private func nextID() -> Int { counter += 1; return counter }

    private func append(_ r: InputEventRecord) {
        records.append(r)
        if records.count > limit { records.removeFirst(records.count - limit) }
    }
}

extension Notification.Name {
    static let configBoxReconcile = Notification.Name("ConfigBoxReconcile")
}

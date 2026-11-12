import AppKit
import CoreGraphics

/// Moves a window along with the pointer through Accessibility, for drags the window server will not carry
/// on by itself (it only follows a real, held button), and keeps window snapping informed.
struct WindowFollower {
    let window: AXUIElement
    /// The window's position (Accessibility coordinates) when the pointer was at `cursor`.
    private let origin: CGPoint
    private let cursor: CGPoint
    private var lastMove: CFAbsoluteTime = 0
    private var pending: CGPoint?

    init?(window: AXUIElement, cursor: CGPoint) {
        guard let frame = AX.frame(of: window) else { return nil }
        self.window = window
        self.origin = frame.origin
        self.cursor = cursor
    }

    /// The pointer is at `loc` now. Each Accessibility call waits for the app, so at most ~90 a second are
    /// made; `finish()` applies what was left out.
    mutating func move(to loc: CGPoint) {
        let target = CGPoint(x: origin.x + loc.x - cursor.x, y: origin.y + loc.y - cursor.y)
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastMove >= 1.0 / 90 {
            lastMove = now
            pending = nil
            AX.setPoint(window, kAXPositionAttribute as String, target)
        } else {
            pending = target
        }
    }

    mutating func finish() {
        if let pending { AX.setPoint(window, kAXPositionAttribute as String, pending) }
        pending = nil
    }

    /// Brings the window to the front like a click on its title bar would.
    func raise() {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AX.set(window, kAXMainAttribute as String, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    private static let controls: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXPopUpButton", "AXMenuButton", "AXCheckBox", "AXRadioButton",
        "AXSlider", "AXComboBox", "AXLink", "AXTab", "AXIncrementor", "AXColorWell", "AXDisclosureTriangle",
        "AXScrollBar", "AXMenuBarItem", "AXMenuItem", "AXSegmentedControl", "AXWebArea", "AXCell", "AXRow",
    ]
    private static let passive: Set<String> = ["AXStaticText", "AXImage", "AXGroup", "AXUnknown", "AXSplitGroup", "AXTabGroup"]
    /// Height of a plain title bar: passive elements this close to the window's top edge count as part of it.
    private static let titleBarHeight: CGFloat = 32

    /// The window a press at `p` would drag: the pointer is on its title bar or on an empty part of its
    /// toolbar, not on a control or the content.
    static func windowDragTarget(at p: CGPoint) -> AXUIElement? {
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &found) == .success,
              let el = found else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        AXUIElementSetMessagingTimeout(el, 0.3)
        let role: String = AX.attr(el, kAXRoleAttribute as String) ?? ""
        let found2: AXUIElement? = role == "AXWindow" ? el : AX.attr(el, kAXWindowAttribute as String)
        guard let window = found2 else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.3)
        guard let frame = AX.frame(of: window) else { return nil }
        if role == "AXWindow" {
            // The window itself answers for its title bar, but in some apps also for empty content.
            return p.y - frame.minY <= 60 ? window : nil
        }
        if controls.contains(role) { return nil }
        if role == "AXToolbar" { return window }
        var current = el
        for _ in 0..<8 {
            guard let parent: AXUIElement = AX.attr(current, kAXParentAttribute as String) else { break }
            let parentRole: String = AX.attr(parent, kAXRoleAttribute as String) ?? ""
            if parentRole == "AXToolbar" { return window }
            if parentRole == "AXWindow" { break }
            if controls.contains(parentRole) { return nil }
            current = parent
        }
        return passive.contains(role) && p.y - frame.minY <= titleBarHeight ? window : nil
    }
}

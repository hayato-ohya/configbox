import AppKit
import ApplicationServices

/// Accessibility-based window geometry helpers. AX coordinates: origin top-left of the primary display, y grows downward.
enum AX {
    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
        return v as? T
    }
    static func attrValue<T>(_ el: AXUIElement, _ name: String, _ type: AXValueType, _ zero: T) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
        let value = v as! AXValue
        var out = zero
        guard AXValueGetType(value) == type else { return nil }
        let ok = withUnsafeMutablePointer(to: &out) { AXValueGetValue(value, type, UnsafeMutableRawPointer($0)) }
        return ok ? out : nil
    }
    static func set(_ el: AXUIElement, _ name: String, _ value: CFTypeRef) {
        AXUIElementSetAttributeValue(el, name as CFString, value)
    }
    static func setPoint(_ el: AXUIElement, _ name: String, _ p: CGPoint) {
        var p = p
        if let v = AXValueCreate(.cgPoint, &p) { set(el, name, v) }
    }
    static func setSize(_ el: AXUIElement, _ name: String, _ s: CGSize) {
        var s = s
        if let v = AXValueCreate(.cgSize, &s) { set(el, name, v) }
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        guard let p = attrValue(window, kAXPositionAttribute, .cgPoint, CGPoint.zero),
              let s = attrValue(window, kAXSizeAttribute, .cgSize, CGSize.zero) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func setFrame(_ window: AXUIElement, _ r: CGRect) {
        // Position first so a frame on another display is not clamped to the current screen's size,
        // then size, then position again for apps that re-anchor after resizing.
        setPoint(window, kAXPositionAttribute, r.origin)
        setSize(window, kAXSizeAttribute, r.size)
        setPoint(window, kAXPositionAttribute, r.origin)
        // Some apps settle their size asynchronously after a display change: check once more shortly after.
        if let now = frame(of: window), !close(now, r) {
            setSize(window, kAXSizeAttribute, r.size)
            setPoint(window, kAXPositionAttribute, r.origin)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let later = frame(of: window), !close(later, r) {
                setPoint(window, kAXPositionAttribute, r.origin)
                setSize(window, kAXSizeAttribute, r.size)
                setPoint(window, kAXPositionAttribute, r.origin)
            }
        }
    }

    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }

    static func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.5)
        guard let window: AXUIElement = attr(appEl, kAXFocusedWindowAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.5)   // the timeout is per element: the window needs its own
        return window
    }

    // Coordinate conversion between AppKit (bottom-left origin) and AX (top-left origin of primary screen).
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
    static func toAX(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height) }
    static func fromAX(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height) }
}

enum WindowManager {
    static func perform(_ action: WindowAction) {
        guard let win = AX.focusedWindow(), let axFrame = AX.frame(of: win) else { return }
        let current = AX.fromAX(axFrame)
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let screen = screens.max(by: { $0.frame.intersection(current).area < $1.frame.intersection(current).area }) ?? screens[0]

        var target: CGRect
        switch action {
        case .nextDisplay, .previousDisplay:
            guard screens.count > 1, let idx = screens.firstIndex(of: screen) else { return }
            let v = screen.visibleFrame
            let step = action == .nextDisplay ? 1 : screens.count - 1
            let other = screens[(idx + step) % screens.count].visibleFrame
            let rx = (current.minX - v.minX) / v.width, ry = (current.minY - v.minY) / v.height
            let rw = current.width / v.width, rh = current.height / v.height
            target = CGRect(x: other.minX + rx * other.width, y: other.minY + ry * other.height,
                            width: min(rw * other.width, other.width), height: min(rh * other.height, other.height))
        default:
            target = rect(for: action, in: screen.visibleFrame, current: current)
        }
        AX.setFrame(win, AX.toAX(target.integral))
    }

    /// Target frame (AppKit coordinates) for a tiling action inside a screen's visible frame.
    static func rect(for action: WindowAction, in v: CGRect, current: CGRect?) -> CGRect {
        func rect(_ fx: CGFloat, _ fy: CGFloat, _ fw: CGFloat, _ fh: CGFloat) -> CGRect {
            CGRect(x: v.minX + v.width * fx, y: v.minY + v.height * fy, width: v.width * fw, height: v.height * fh)
        }
        switch action {
        case .leftHalf: return rect(0, 0, 0.5, 1)
        case .rightHalf: return rect(0.5, 0, 0.5, 1)
        case .topHalf: return rect(0, 0.5, 1, 0.5)
        case .bottomHalf: return rect(0, 0, 1, 0.5)
        case .topLeft: return rect(0, 0.5, 0.5, 0.5)
        case .topRight: return rect(0.5, 0.5, 0.5, 0.5)
        case .bottomLeft: return rect(0, 0, 0.5, 0.5)
        case .bottomRight: return rect(0.5, 0, 0.5, 0.5)
        case .leftThird: return rect(0, 0, 1.0 / 3, 1)
        case .centerThird: return rect(1.0 / 3, 0, 1.0 / 3, 1)
        case .rightThird: return rect(2.0 / 3, 0, 1.0 / 3, 1)
        case .leftTwoThirds: return rect(0, 0, 2.0 / 3, 1)
        case .rightTwoThirds: return rect(1.0 / 3, 0, 2.0 / 3, 1)
        case .maximize, .nextDisplay, .previousDisplay: return v
        case .almostMaximize: return rect(0.05, 0.05, 0.9, 0.9)
        case .center:
            let c = current ?? rect(0.1, 0.1, 0.8, 0.8)
            return CGRect(x: v.midX - c.width / 2, y: v.midY - c.height / 2, width: c.width, height: c.height)
        }
    }

    /// Frame (AppKit coordinates) a step would give the window, given where the window is now.
    static func rect(for target: WindowTarget, current: CGRect) -> CGRect? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let screen = screens.max(by: { $0.frame.intersection(current).area < $1.frame.intersection(current).area }) ?? screens[0]
        switch target {
        case .area(let id):
            guard let area = ConfigStore.shared.config.snapAreas.first(where: { $0.id == id }) else { return nil }
            return area.targetRect(on: NSScreen.screen(withDisplayID: area.displayID) ?? screen)
        case .tile(let action):
            switch action {
            case .nextDisplay, .previousDisplay:
                guard screens.count > 1, let idx = screens.firstIndex(of: screen) else { return nil }
                let v = screen.visibleFrame
                let step = action == .nextDisplay ? 1 : screens.count - 1
                let other = screens[(idx + step) % screens.count].visibleFrame
                let rx = (current.minX - v.minX) / v.width, ry = (current.minY - v.minY) / v.height
                return CGRect(x: other.minX + rx * other.width, y: other.minY + ry * other.height,
                              width: min(current.width / v.width * other.width, other.width),
                              height: min(current.height / v.height * other.height, other.height))
            default:
                return rect(for: action, in: screen.visibleFrame, current: current)
            }
        }
    }

    /// Advances the focused window to the step after the one it currently occupies (or to the first step).
    static func cycle(_ steps: [WindowTarget]) {
        guard !steps.isEmpty, let win = AX.focusedWindow(), let axf = AX.frame(of: win) else { return }
        let current = AX.fromAX(axf)
        var nextIndex = 0
        for (i, step) in steps.enumerated() {
            if let r = rect(for: step, current: current), close(r.integral, current.integral, tolerance: 6) {
                nextIndex = (i + 1) % steps.count
                break
            }
        }
        // Skip steps that cannot be resolved (deleted area, single display) so the cycle never gets stuck.
        for offset in 0..<steps.count {
            let step = steps[(nextIndex + offset) % steps.count]
            if let r = rect(for: step, current: current) {
                AX.setFrame(win, AX.toAX(r.integral))
                return
            }
        }
    }

    private static func close(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
        abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// Moves the focused window into the window frame attached to a snap area (or the area itself).
    static func applySnapAreaFrame(_ id: UUID) {
        guard let area = ConfigStore.shared.config.snapAreas.first(where: { $0.id == id }) else { return }
        guard let screen = NSScreen.screen(withDisplayID: area.displayID) ?? NSScreen.main else { return }
        guard let win = AX.focusedWindow() else { return }
        AX.setFrame(win, AX.toAX(area.targetRect(on: screen).integral))
    }

    static func pressButton(_ attribute: String) {
        guard let win = AX.focusedWindow(), let button: AXUIElement = AX.attr(win, attribute) else { return }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

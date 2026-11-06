import Foundation
import CoreGraphics

/// Thin wrapper around a session-level CGEventTap for keyboard, mouse and scroll events.
final class EventTap {
    /// Return the event to pass it through (possibly modified), or nil to swallow it.
    typealias Handler = (CGEventType, CGEvent) -> CGEvent?

    var handler: Handler?
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { port != nil }

    @discardableResult
    func start() -> Bool {
        guard port == nil else { return true }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                tap.reenable()
                return Unmanaged.passUnretained(event)
            }
            guard let handler = tap.handler else { return Unmanaged.passUnretained(event) }
            if let out = handler(type, event) { return Unmanaged.passUnretained(out) }
            return nil
        }

        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                           place: .headInsertEventTap,
                                           options: .defaultTap,
                                           eventsOfInterest: mask,
                                           callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log.error("CGEventTap creation failed (Accessibility permission missing?)")
            return false
        }
        self.port = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        Log.info("Event tap started")
        return true
    }

    func stop() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(port)
        self.port = nil
        self.source = nil
    }

    func reenable() {
        if let port { CGEvent.tapEnable(tap: port, enable: true) }
    }
}

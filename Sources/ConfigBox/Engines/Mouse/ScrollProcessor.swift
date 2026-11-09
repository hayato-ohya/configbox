import AppKit
import CoreGraphics
import Foundation

/// Rewrites mouse-wheel scroll events: direction reversal, speed, Shift → horizontal, smooth scrolling.
/// Only discrete (non-continuous) events are touched, so trackpads and Magic Mouse keep behaving as macOS configures them.
final class ScrollProcessor {
    static let shared = ScrollProcessor()
    var settings = MouseSettings()
    var mouseEnabled = true
    var trackpadReverse = false
    var trackpadSpeed: Double = 1.0
    private var smoothWork: [DispatchWorkItem] = []
    private var hitCache: (point: CGPoint, time: CFAbsoluteTime, bundle: String?) = (.zero, 0, nil)

    private init() {}

    /// Returns the event to deliver (possibly modified) or nil to swallow it.
    func process(_ e: CGEvent) -> CGEvent? {
        if e.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 {              // trackpad / Magic Mouse
            guard trackpadReverse || trackpadSpeed != 1 else { return e }
            if !settings.scrollExcludedApps.isEmpty, let app = appUnderPointer(e.location), settings.scrollExcludedApps.contains(app) { return e }
            let f = (trackpadReverse ? -1.0 : 1.0) * trackpadSpeed
            // Writing the integer delta makes macOS recompute the point and fixed-point deltas from it, so
            // read everything first and write the integer fields before the others.
            let intKeys: [CGEventField] = [.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2]
            let doubleKeys: [CGEventField] = [.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2,
                                              .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2]
            let ints = intKeys.map { Int64((Double(e.getIntegerValueField($0)) * f).rounded()) }
            let doubles = doubleKeys.map { e.getDoubleValueField($0) * f }
            for (key, value) in zip(intKeys, ints) { e.setIntegerValueField(key, value: value) }
            for (key, value) in zip(doubleKeys, doubles) { e.setDoubleValueField(key, value: value) }
            return e
        }
        guard mouseEnabled else { return e }
        let app = appUnderPointer(e.location)
        if let app, settings.scrollExcludedApps.contains(app) {
            return e   // this window keeps the system's own scrolling
        }
        if app == Self.iPhoneMirroring { return processIPhoneMirroring(e) }
        guard settings.scrollActive else { return e }

        var (v, h) = deltas(e)
        if settings.reverseVertical { v = -v }
        if settings.reverseHorizontal { h = -h }
        v *= settings.scrollSpeed
        h *= settings.scrollSpeed

        if settings.smoothScrolling {
            smooth(v: v, h: h, at: e.location, flags: e.flags)
            return nil
        }
        write(e, v: v, h: h)
        return e
    }

    /// Wheel deltas in lines, with Shift + wheel turned horizontal when that option is on.
    private func deltas(_ e: CGEvent) -> (v: Double, h: Double) {
        var v = e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)   // lines (fixed point)
        var h = e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        if v == 0 && h == 0 {
            v = Double(e.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            h = Double(e.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        }
        let flags = e.flags
        if settings.shiftScrollsHorizontally, flags.contains(.maskShift), h == 0, v != 0 {
            h = v; v = 0
            e.flags = flags.subtracting(.maskShift)
        }
        return (v, h)
    }

    // MARK: iPhone Mirroring

    private static let iPhoneMirroring = "com.apple.ScreenContinuity"
    /// A pixel burst moves iPhone Mirroring less than a real wheel notch; this makes speed 1× feel right.
    private static let iPhoneMirroringBoost = 1.5

    /// iPhone Mirroring reads the HID event attached to a scroll event and ignores edited delta fields, and a
    /// fresh line-based event barely moves it. So it has its own reverse / speed settings, delivered as a phased
    /// pixel burst (what smooth scrolling sends), which it turns into a swipe. Reverse off at 1× passes the
    /// wheel through untouched.
    private func processIPhoneMirroring(_ e: CGEvent) -> CGEvent? {
        let reverse = settings.iPhoneMirroringReverse, speed = settings.iPhoneMirroringSpeed
        guard reverse || speed != 1 else { return e }
        var (v, h) = deltas(e)
        if reverse { v = -v; h = -h }
        let f = speed * Self.iPhoneMirroringBoost
        smooth(v: v * f, h: h * f, at: e.location, flags: e.flags)
        return nil
    }

    /// Bundle identifier of the app owning the topmost normal window under the pointer (cached ~150 ms).
    private func appUnderPointer(_ p: CGPoint) -> String? {
        let now = CFAbsoluteTimeGetCurrent()
        if now - hitCache.time < 0.15 && abs(p.x - hitCache.point.x) < 4 && abs(p.y - hitCache.point.y) < 4 { return hitCache.bundle }
        var bundle: String?
        if let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for w in info {
                guard (w["kCGWindowLayer"] as? Int) == 0,
                      let b = w["kCGWindowBounds"] as? [String: CGFloat],
                      let x = b["X"], let y = b["Y"], let wd = b["Width"], let ht = b["Height"],
                      CGRect(x: x, y: y, width: wd, height: ht).contains(p),
                      let pid = w["kCGWindowOwnerPID"] as? pid_t else { continue }
                bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                break
            }
        }
        hitCache = (p, now, bundle)
        return bundle
    }

    private func write(_ e: CGEvent, v: Double, h: Double) {
        // Integer deltas first: writing them resets the fixed-point and point deltas.
        e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(v.rounded(.towardZero) == 0 && v != 0 ? (v > 0 ? 1 : -1) : v.rounded()))
        e.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(h.rounded(.towardZero) == 0 && h != 0 ? (h > 0 ? 1 : -1) : h.rounded()))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: v)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: h)
        e.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: v * 10)
        e.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: h * 10)
    }

    /// Replaces one wheel notch with a short burst of pixel-based continuous scroll events (ease-out).
    private func smooth(v: Double, h: Double, at location: CGPoint, flags: CGEventFlags) {
        let steps = 8
        let totalV = v * 40, totalH = h * 40          // pixels per line
        var sent = (0.0, 0.0)
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let eased = 1 - pow(1 - t, 3)
            let targetV = totalV * eased, targetH = totalH * eased
            let dv = targetV - sent.0, dh = targetH - sent.1
            sent = (targetV, targetH)
            let work = DispatchWorkItem {
                guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dv.rounded()), wheel2: Int32(dh.rounded()), wheel3: 0) else { return }
                ev.location = location
                ev.flags = flags
                ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                ev.setIntegerValueField(.scrollWheelEventScrollPhase, value: i == 1 ? 1 : (i == steps ? 4 : 2))
                ev.setIntegerValueField(.eventSourceUserData, value: KeySynth.marker)
                ev.post(tap: .cghidEventTap)
            }
            smoothWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(12 * (i - 1)), execute: work)
        }
        if smoothWork.count > 64 { smoothWork.removeFirst(smoothWork.count - 64) }
    }
}

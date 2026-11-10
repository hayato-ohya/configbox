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
        // Looking up the window under the pointer costs a window-list query, so only do it when the answer
        // can matter: some app is excluded, or iPhone Mirroring is running and has settings of its own.
        let mirroring = (settings.iPhoneMirroringReverse || settings.iPhoneMirroringSpeed != 1) && iPhoneMirroringIsRunning()
        let app = !settings.scrollExcludedApps.isEmpty || mirroring ? appUnderPointer(e.location) : nil
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
    /// pixel burst per notch, which it turns into a swipe. Reverse off at 1× passes the
    /// wheel through untouched.
    private func processIPhoneMirroring(_ e: CGEvent) -> CGEvent? {
        let reverse = settings.iPhoneMirroringReverse, speed = settings.iPhoneMirroringSpeed
        guard reverse || speed != 1 else { return e }
        var (v, h) = deltas(e)
        if reverse { v = -v; h = -h }
        let f = speed * Self.iPhoneMirroringBoost
        burst(v: v * f, h: h * f, at: e.location, flags: e.flags)
        return nil
    }

    private var mirroringCheck: (time: CFAbsoluteTime, running: Bool) = (0, false)

    /// Whether iPhone Mirroring is running (checked at most every 2 s).
    private func iPhoneMirroringIsRunning() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if now - mirroringCheck.time > 2 {
            mirroringCheck = (now, !NSRunningApplication.runningApplications(withBundleIdentifier: Self.iPhoneMirroring).isEmpty)
        }
        return mirroringCheck.running
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

    // MARK: Smooth scrolling

    private static let pixelsPerLine = 40.0
    private var smoothScroll = SmoothScroll()
    private var smoothTimer: DispatchSourceTimer?
    private var smoothLocation = CGPoint.zero
    private var smoothFlags: CGEventFlags = []

    /// Turns wheel notches into one eased, pixel-based scroll gesture (see SmoothScroll). The events go to
    /// wherever the pointer was at the latest notch, with that notch's modifiers.
    private func smooth(v: Double, h: Double, at location: CGPoint, flags: CGEventFlags) {
        smoothScroll.add(v: v * Self.pixelsPerLine, h: h * Self.pixelsPerLine)
        smoothLocation = location
        smoothFlags = flags
        guard smoothTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.smoothTick() }
        smoothTimer = timer
        timer.resume()
    }

    private func smoothTick() {
        if let step = smoothScroll.step() {
            post(pixels: step.dv, step.dh, phase: step.phase.rawValue, at: smoothLocation, flags: smoothFlags)
        }
        if !smoothScroll.isActive {
            smoothTimer?.cancel()
            smoothTimer = nil
        }
    }

    /// Replaces one wheel notch with its own short burst of pixel events (began … ended). iPhone Mirroring
    /// turns exactly this shape into a swipe, so it keeps the burst instead of the merged gesture above.
    private func burst(v: Double, h: Double, at location: CGPoint, flags: CGEventFlags) {
        let steps = 8
        let totalV = v * Self.pixelsPerLine, totalH = h * Self.pixelsPerLine
        var sent = (0.0, 0.0)
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let eased = 1 - pow(1 - t, 3)
            // Round the running total, not each step, so the pixels sent add up to the total.
            let target = ((totalV * eased).rounded(), (totalH * eased).rounded())
            let dv = Int32(target.0 - sent.0), dh = Int32(target.1 - sent.1)
            sent = target
            let phase: Int64 = i == 1 ? 1 : (i == steps ? 4 : 2)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(12 * (i - 1))) { [weak self] in
                self?.post(pixels: dv, dh, phase: phase, at: location, flags: flags)
            }
        }
    }

    private func post(pixels dv: Int32, _ dh: Int32, phase: Int64, at location: CGPoint, flags: CGEventFlags) {
        guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dv, wheel2: dh, wheel3: 0) else { return }
        ev.location = location
        ev.flags = flags
        ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        ev.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        ev.setIntegerValueField(.eventSourceUserData, value: KeySynth.marker)
        ev.post(tap: .cghidEventTap)
    }
}

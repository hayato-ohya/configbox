import Foundation

/// The arithmetic of smooth scrolling, free of events and timers so it can be tested.
///
/// Wheel notches add a distance in pixels. Every tick hands out part of what is left, easing out, as
/// whole pixels. Notches that arrive while a scroll is still running extend it, so the receiving app sees
/// one gesture (began, changed …, ended) instead of overlapping ones, and fractions are carried over so
/// the pixels handed out always add up to the distance asked for.
struct SmoothScroll {
    enum Phase: Int64 { case began = 1, changed = 2, ended = 4 }   // kCGScrollPhase*
    struct Step: Equatable {
        var dv: Int32
        var dh: Int32
        var phase: Phase
    }

    /// Share of the remaining distance handed out per tick. At 8 ms a tick, 0.2 delivers 95 % of a notch
    /// in about 100 ms, like the fixed eight-step burst this replaces.
    static let share = 0.2

    private var remaining = (v: 0.0, h: 0.0)   // not handed out yet
    private var carry = (v: 0.0, h: 0.0)       // handed out, but still less than a whole pixel
    private var running = false                // a gesture was begun and not ended yet

    /// True while `step()` still has something to return.
    var isActive: Bool { running || remaining.v != 0 || remaining.h != 0 }

    mutating func add(v: Double, h: Double) {
        // Turning the wheel the other way drops what was left of the old direction, so it responds at once.
        if remaining.v * v < 0 { remaining.v = 0; carry.v = 0 }
        if remaining.h * h < 0 { remaining.h = 0; carry.h = 0 }
        remaining.v += v
        remaining.h += h
    }

    /// The next event to send, or nil when this tick has nothing to send (also once the scroll is over).
    mutating func step() -> Step? {
        if remaining.v == 0 && remaining.h == 0 {
            guard running else { return nil }
            // Everything was handed out: whatever fraction is left rounds into the closing event.
            let step = Step(dv: Int32(carry.v.rounded()), dh: Int32(carry.h.rounded()), phase: .ended)
            carry = (0, 0)
            running = false
            return step
        }
        let dv = Self.take(&remaining.v, &carry.v)
        let dh = Self.take(&remaining.h, &carry.h)
        if dv == 0 && dh == 0 { return nil }   // still collecting a first whole pixel
        defer { running = true }
        return Step(dv: dv, dh: dh, phase: running ? .changed : .began)
    }

    /// Moves this tick's share from `remaining` to `carry` and returns the whole pixels now in `carry`.
    private static func take(_ remaining: inout Double, _ carry: inout Double) -> Int32 {
        guard remaining != 0 else { return 0 }
        // At least one pixel per tick (or all that is left), so the tail does not crawl.
        var part = remaining * share
        if abs(part) < 1 { part = abs(remaining) <= 1 ? remaining : (remaining > 0 ? 1 : -1) }
        remaining -= part
        if abs(remaining) < 1e-9 { remaining = 0 }
        carry += part
        let whole = carry.rounded(.towardZero)
        carry -= whole
        return Int32(whole)
    }
}

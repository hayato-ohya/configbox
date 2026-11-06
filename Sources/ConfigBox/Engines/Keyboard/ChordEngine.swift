import CoreGraphics
import Foundation

/// Simultaneous-key chords (Karabiner "simultaneous"). Keys that belong to a chord are held back
/// for a short threshold; if the rest of the chord arrives, the action runs and the keys are
/// swallowed, otherwise the original key events are replayed in order.
final class ChordEngine {
    private var rules: [ChordRule] = []
    private var chordKeys: Set<UInt16> = []
    private var pending: [(code: UInt16, event: CGEvent)] = []
    private var consumed: Set<UInt16> = []
    private var timeout: DispatchWorkItem?

    func apply(rules: [ChordRule]) {
        self.rules = rules.filter { $0.enabled && $0.keys.count >= 2 }
        chordKeys = Set(self.rules.flatMap(\.keys))
        flush()
        consumed = []
        if self.rules.contains(where: { $0.device != nil }) { KeyDeviceTracker.shared.start() } else { KeyDeviceTracker.shared.stop() }
    }

    /// Rule whose key set equals `held` and whose device (if any) produced every held key.
    private func matchingRule(for held: Set<UInt16>) -> ChordRule? {
        for r in rules where Set(r.keys) == held {
            guard let dev = r.device else { return r }
            guard KeyDeviceTracker.shared.isRunning else { continue }
            let ok = held.allSatisfy { code in
                guard let d = KeyDeviceTracker.shared.device(forKeyCode: code) else { return false }
                return d.vendorId == dev.vendorId && d.productId == dev.productId
            }
            if ok { return r }
        }
        return nil
    }

    var isEmpty: Bool { rules.isEmpty }

    /// Returns true when the event was consumed.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard !rules.isEmpty else { return false }
        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .keyDown:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if consumed.contains(code) { return true }                  // repeats of a fired chord
            if isRepeat { return pending.contains { $0.code == code } }
            guard chordKeys.contains(code) else {
                flush()                                                  // unrelated key: release held keys first, in order
                return false
            }
            if let copy = event.copy() { pending.append((code, copy)) }
            let held = Set(pending.map(\.code))
            if let rule = matchingRule(for: held) {
                timeout?.cancel(); timeout = nil
                consumed.formUnion(held)
                pending = []
                let action = rule.action
                DispatchQueue.main.async { ActionRunner.run(action) }
                return true
            }
            if !rules.contains(where: { held.isStrictSubset(of: Set($0.keys)) }) {
                flush()                                                  // cannot become a chord any more (or wrong keyboard)
                return true                                              // (this key was replayed by flush)
            }
            if pending.count == 1 {
                let ms = rules.filter { $0.keys.contains(code) }.map(\.thresholdMs).max() ?? 60
                let work = DispatchWorkItem { [weak self] in self?.flush() }
                timeout = work
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms), execute: work)
            }
            return true
        case .keyUp:
            if consumed.remove(code) != nil { return true }
            if pending.contains(where: { $0.code == code }) {
                flush()                                                  // tapped alone before the threshold
                return false
            }
            return false
        default:
            return false
        }
    }

    /// Replays held-back key downs in their original order.
    private func flush() {
        timeout?.cancel(); timeout = nil
        let events = pending
        pending = []
        for p in events {
            p.event.setIntegerValueField(.eventSourceUserData, value: KeySynth.marker)
            p.event.post(tap: .cghidEventTap)
        }
    }
}

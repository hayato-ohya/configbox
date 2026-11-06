import Foundation
import IOKit.hid
import CBridge

/// Pointer speed (HID resolution) and acceleration for mice, applied through IOHIDEventSystemClient.
/// Values are re-applied when a mouse is (re)connected and after wake, since the HID system
/// resets them. Original values are remembered so turning the feature off restores them.
final class PointerSettings {
    static let shared = PointerSettings()

    struct DeviceState: Identifiable {
        let id: String
        let name: String
        let resolutionDPI: Double?
        let acceleration: Double?
    }

    private var client: UnsafeMutableRawPointer?
    private var originals: [String: (res: CFTypeRef?, acc: CFTypeRef?)] = [:]
    private var manager: IOHIDManager?
    private var current = MouseSettings()
    private(set) var lastError: String?

    private let keyResolution = "HIDPointerResolution" as CFString
    private let keyAcceleration = "HIDPointerAcceleration" as CFString
    private let keyMouseAcceleration = "HIDMouseAcceleration" as CFString
    private let defaultDPI: Double = 400

    private init() {}

    // MARK: Public

    func apply(_ settings: MouseSettings) {
        current = settings
        if settings.pointerSpeedEnabled || settings.acceleration != .system {
            startWatching()
            applyNow()
        } else {
            restore()
        }
    }

    func restore() {
        guard client != nil else { return }
        for (id, s) in services() {
            guard let o = originals[id] else { continue }
            if let r = o.res { cb_hid_service_set_property(s, keyResolution, r) }
            if let a = o.acc { cb_hid_service_set_property(s, keyAcceleration, a) }
        }
        originals = [:]
    }

    /// Current values of every connected mouse (for the settings UI).
    func devices() -> [DeviceState] {
        ensureClient()
        return services().map { id, s in
            let name = (cb_hid_service_copy_property(s, "Product" as CFString) as? String) ?? "Mouse"
            let res = fixed(cb_hid_service_copy_property(s, keyResolution))
            let acc = fixed(cb_hid_service_copy_property(s, keyAcceleration))
            return DeviceState(id: id, name: name, resolutionDPI: res, acceleration: acc)
        }
    }

    // MARK: Internals

    private func ensureClient() {
        if client == nil { client = cb_hid_client_create() }
    }

    /// Mouse services (usage page 1 / usage 2), excluding built-in trackpads.
    private func services() -> [(String, UnsafeMutableRawPointer)] {
        ensureClient()
        guard let client, let arr = cb_hid_client_copy_services(client) else { return [] }
        var out: [(String, UnsafeMutableRawPointer)] = []
        for i in 0..<CFArrayGetCount(arr) {
            guard let raw = CFArrayGetValueAtIndex(arr, i) else { continue }
            let s = UnsafeMutableRawPointer(mutating: raw)
            let page = (cb_hid_service_copy_property(s, "PrimaryUsagePage" as CFString) as? Int) ?? 0
            let usage = (cb_hid_service_copy_property(s, "PrimaryUsage" as CFString) as? Int) ?? 0
            guard page == 1, usage == 2 else { continue }
            let builtIn = (cb_hid_service_copy_property(s, "Built-In" as CFString) as? Bool) ?? false
            let product = (cb_hid_service_copy_property(s, "Product" as CFString) as? String) ?? ""
            if builtIn || product.localizedCaseInsensitiveContains("trackpad") { continue }
            // Skip pseudo mice (hub / KVM helpers, virtual devices) that expose no pointer resolution.
            guard let r = fixed(cb_hid_service_copy_property(s, keyResolution)), r > 0 else { continue }
            let vid = (cb_hid_service_copy_property(s, "VendorID" as CFString) as? Int) ?? 0
            let pid = (cb_hid_service_copy_property(s, "ProductID" as CFString) as? Int) ?? 0
            let loc = (cb_hid_service_copy_property(s, "LocationID" as CFString) as? Int) ?? i
            out.append(("\(vid):\(pid):\(loc)", s))
        }
        return out
    }

    private func fixed(_ v: CFTypeRef?) -> Double? {
        guard let n = v as? NSNumber else { return nil }
        return n.doubleValue / 65536.0
    }

    private func applyNow() {
        ensureClient()
        guard let client else { lastError = "IOHIDEventSystemClient unavailable"; return }
        var okCount = 0, total = 0
        for (id, s) in services() {
            total += 1
            if originals[id] == nil {
                originals[id] = (cb_hid_service_copy_property(s, keyResolution),
                                 cb_hid_service_copy_property(s, keyAcceleration))
            }
            if current.pointerSpeedEnabled {
                let dpi = defaultDPI / max(0.1, current.pointerSpeed)
                let v = NSNumber(value: Int(dpi * 65536))
                if cb_hid_service_set_property(s, keyResolution, v) != 0 { okCount += 1 }
            } else if let o = originals[id]?.res {
                cb_hid_service_set_property(s, keyResolution, o)
            }
            switch current.acceleration {
            case .system:
                if let o = originals[id]?.acc { cb_hid_service_set_property(s, keyAcceleration, o) }
            case .off:
                cb_hid_service_set_property(s, keyAcceleration, NSNumber(value: -65536))
            case .custom:
                cb_hid_service_set_property(s, keyAcceleration, NSNumber(value: Int(current.accelerationValue * 65536)))
            }
        }
        // Client-wide mouse acceleration (what System Settings' slider writes).
        switch current.acceleration {
        case .off: cb_hid_client_set_property(client, keyMouseAcceleration, NSNumber(value: -65536))
        case .custom: cb_hid_client_set_property(client, keyMouseAcceleration, NSNumber(value: Int(current.accelerationValue * 65536)))
        case .system: break
        }
        lastError = total == 0 ? "No external mouse connected" : nil
        Log.info("pointer settings applied to \(total) mouse service(s) (speed ok on \(okCount))")
    }

    /// Re-apply whenever a pointing device appears (HID resets properties per connection).
    private func startWatching() {
        guard manager == nil else { return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 2] as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(m, { _, _, _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { PointerSettings.shared.applyNow() }
        }, nil)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
    }
}

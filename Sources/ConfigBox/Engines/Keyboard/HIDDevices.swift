import Foundation
import IOKit.hid

struct HIDDeviceInfo: Identifiable, Hashable {
    enum Kind: String { case keyboard = "Keyboard", pointer = "Mouse / Pointer", touchpad = "Trackpad", other = "Other" }
    let name: String
    let manufacturer: String
    let vendorId: Int
    let productId: Int
    let transport: String
    let builtIn: Bool
    let kind: Kind
    var id: String { "\(vendorId):\(productId):\(kind.rawValue):\(name)" }
    var ref: DeviceRef { DeviceRef(vendorId: vendorId, productId: productId, name: name) }
    var idString: String { String(format: "0x%04X / 0x%04X", vendorId, productId) }
}

/// Lists HID input devices via IOHIDManager (no TCC permission needed for enumeration).
enum HIDDevices {
    static func list() -> [HIDDeviceInfo] {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x06], // keyboard
            [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x02], // mouse
            [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x01], // pointer
            [kIOHIDDeviceUsagePageKey: 0x0D, kIOHIDDeviceUsageKey: 0x05], // touch pad
        ]
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matches as CFArray)
        guard let set = IOHIDManagerCopyDevices(mgr) else { return [] }
        let devices = (set as NSSet).allObjects.map { $0 as! IOHIDDevice }

        func prop<T>(_ d: IOHIDDevice, _ key: String) -> T? { IOHIDDeviceGetProperty(d, key as CFString) as? T }

        var out: [HIDDeviceInfo] = []
        var seen = Set<String>()
        for d in devices {
            let name: String = prop(d, kIOHIDProductKey) ?? "Unknown device"
            let vendor: Int = prop(d, kIOHIDVendorIDKey) ?? 0
            let product: Int = prop(d, kIOHIDProductIDKey) ?? 0
            let page: Int = prop(d, kIOHIDPrimaryUsagePageKey) ?? 0
            let usage: Int = prop(d, kIOHIDPrimaryUsageKey) ?? 0
            let kind: HIDDeviceInfo.Kind
            switch (page, usage) {
            case (1, 6): kind = .keyboard
            case (1, 2), (1, 1): kind = .pointer
            case (0x0D, 5): kind = .touchpad
            default: kind = .other
            }
            let info = HIDDeviceInfo(name: name,
                                     manufacturer: prop(d, kIOHIDManufacturerKey) ?? "",
                                     vendorId: vendor, productId: product,
                                     transport: prop(d, kIOHIDTransportKey) ?? "",
                                     builtIn: (prop(d, kIOHIDBuiltInKey) as Bool?) ?? false,
                                     kind: kind)
            if seen.insert(info.id).inserted { out.append(info) }
        }
        return out.sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
    }

    static func keyboards() -> [HIDDeviceInfo] {
        // Apple silicon built-in keyboards report no vendor or product ID.
        list().filter { $0.kind == .keyboard && ($0.vendorId != 0 || $0.builtIn) && !$0.name.localizedCaseInsensitiveContains("Karabiner") }
    }

    /// True while Karabiner-Elements' virtual keyboard driver is active. Karabiner seizes the physical
    /// keyboards it manages and re-emits their keys from this virtual device, so per-device HID
    /// mappings on the physical keyboards never see any input.
    static var karabinerActive: Bool {
        list().contains { $0.name.localizedCaseInsensitiveContains("Karabiner") && $0.name.localizedCaseInsensitiveContains("VirtualHIDKeyboard") }
    }
}

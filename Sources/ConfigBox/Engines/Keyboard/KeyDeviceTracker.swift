import Foundation
import IOKit.hid

/// Learns which keyboard produced recent key presses by listening at the HID level
/// (needs the Input Monitoring permission). CGEvents carry no device identity, so features that
/// are limited to one keyboard look up the device here at decision time.
final class KeyDeviceTracker {
    static let shared = KeyDeviceTracker()

    private struct Record { let usage: UInt32; let time: CFAbsoluteTime; let device: DeviceRef }
    private var records: [Record] = []
    private let lock = NSLock()
    private var manager: IOHIDManager?
    private(set) var isRunning = false
    /// Set when opening the HID manager was refused: Input Monitoring is missing even if
    /// IOHIDCheckAccess claims otherwise (it reports "granted" for Accessibility-trusted apps).
    private(set) var denied = false
    private var retries = 0

    private init() {}

    static var hasPermission: Bool {
        if shared.isRunning { return true }
        if shared.denied { return false }
        return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }
    static func requestPermission() {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        shared.scheduleRetry()
    }

    /// Try again a few times after the user has (hopefully) flipped the switch in System Settings.
    private func scheduleRetry() {
        guard retries < 20 else { return }
        retries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.isRunning, self.wanted else { return }
            if !self.start() { self.scheduleRetry() }
        }
    }
    private var wanted = false

    @discardableResult
    func start() -> Bool {
        wanted = true
        if isRunning { return true }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 6] as CFDictionary)
        IOHIDManagerSetInputValueMatching(m, [kIOHIDElementUsagePageKey: 7] as CFDictionary)   // keyboard page only
        IOHIDManagerRegisterInputValueCallback(m, { _, _, _, value in
            let element = IOHIDValueGetElement(value)
            guard IOHIDElementGetUsagePage(element) == 7, IOHIDValueGetIntegerValue(value) == 1 else { return }
            let usage = IOHIDElementGetUsage(element)
            guard usage >= 4 else { return }
            let dev = IOHIDElementGetDevice(element)
            let vid = (IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
            let pid = (IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int) ?? 0
            let name = (IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String) ?? ""
            KeyDeviceTracker.shared.record(usage: usage, device: DeviceRef(vendorId: vid, productId: pid, name: name))
        }, nil)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            if !denied {
                denied = true
                Log.error("IOHIDManagerOpen refused (\(r)): Input Monitoring permission missing; requesting it")
                IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            }
            scheduleRetry()
            return false
        }
        denied = false
        retries = 0
        manager = m
        isRunning = true
        Log.info("key device tracker started")
        return true
    }

    func stop() {
        wanted = false
        guard let m = manager else { return }
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        manager = nil
        isRunning = false
    }

    private func record(usage: UInt32, device: DeviceRef) {
        lock.lock(); defer { lock.unlock() }
        records.append(Record(usage: usage, time: CFAbsoluteTimeGetCurrent(), device: device))
        if records.count > 32 { records.removeFirst(records.count - 32) }
    }

    /// Device that most recently pressed the key with this Mac key code (within `window` seconds).
    func device(forKeyCode code: UInt16, within window: CFAbsoluteTime = 0.5) -> DeviceRef? {
        guard let hid = KeyCodes.hidUsage(for: code), hid >> 32 == 7 else { return nil }
        let usage = UInt32(hid & 0xFFFF_FFFF)
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock(); defer { lock.unlock() }
        return records.last { $0.usage == usage && now - $0.time < window }?.device
    }
}

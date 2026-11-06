import Foundation
import IOKit.hid

struct HIDMapping: Hashable {
    let src: UInt64
    let dst: UInt64
    var display: String { "\(KeyCodes.name(forHID: src)) → \(KeyCodes.name(forHID: dst))" }
}

/// Applies system-level key remaps through Apple's `hidutil`.
/// This is the same mechanism System Settings uses for modifier keys: the remap happens in the
/// HID event system, below any app, so it costs nothing at runtime and keeps working while
/// ConfigBox is not running (optionally persisted at login through a LaunchAgent).
enum HIDUtil {
    private(set) static var installedGlobal: [HIDMapping] = []
    private(set) static var installedDevices: [DeviceRef: [HIDMapping]] = [:]
    static var isActive: Bool { !installedGlobal.isEmpty || !installedDevices.isEmpty }
    static let agentLabel = "com.hayato.configbox.hidmap"
    private static var watcher: IOHIDManager?
    private static var reapplyWork: DispatchWorkItem?

    // MARK: Apply / clear

    private static var firstApply = true

    static func apply(global: [HIDMapping], devices: [DeviceRef: [HIDMapping]]) {
        if !firstApply && global == installedGlobal && devices == installedDevices { return }
        var cmds: [[String]] = []
        if firstApply {
            // A previous instance may have died without cleaning up (crash, SIGKILL, logout):
            // reset every keyboard we are not about to configure so stale per-device routes disappear.
            firstApply = false
            for d in HIDDevices.keyboards() {
                let ref = DeviceRef(vendorId: d.vendorId, productId: d.productId, name: d.name)
                if devices[ref] == nil { cmds.append(command(global, matching: ref)) }
            }
        }
        // Devices that previously had a specific mapping but no longer do must be reset to the global set.
        for dev in installedDevices.keys where devices[dev] == nil { cmds.append(command(global, matching: dev)) }
        cmds.append(command(global, matching: nil))
        for (dev, maps) in devices { cmds.append(command(global + maps, matching: dev)) }
        installedGlobal = global
        installedDevices = devices
        DispatchQueue.global(qos: .userInitiated).async {
            for c in cmds { run(c) }
            if ConfigStore.shared.config.general.keepHIDMappingsAtLogin { writeLaunchAgent() }
        }
        if !devices.isEmpty { startWatching() } 
    }

    /// Per-device UserKeyMapping is a property of the live HID service: when a keyboard re-enumerates
    /// (sleep/wake, dongle reconnect, USB hub resets) the new service starts without it. Watch for
    /// keyboard services appearing and re-apply the device mappings shortly after.
    private static func startWatching() {
        guard watcher == nil else { return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 6] as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(m, { _, _, _, _ in
            HIDUtil.reapplyWork?.cancel()
            let w = DispatchWorkItem { HIDUtil.reapplyDevices() }
            HIDUtil.reapplyWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)
        }, nil)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))   // enumeration only; no event access needed
        watcher = m
    }

    static func reapplyDevices() {
        guard !installedDevices.isEmpty else { return }
        let cmds = installedDevices.map { command(installedGlobal + $0.value, matching: $0.key) }
        DispatchQueue.global(qos: .userInitiated).async {
            for c in cmds { run(c) }
            Log.info("re-applied per-device HID mappings for \(cmds.count) device(s)")
        }
    }

    static func clear() {
        var cmds: [[String]] = []
        for dev in installedDevices.keys { cmds.append(command([], matching: dev)) }
        cmds.append(command([], matching: nil))
        installedGlobal = []
        installedDevices = [:]
        for c in cmds { run(c) }
    }

    /// Clears UserKeyMapping on every keyboard, including mappings made by other tools.
    static func clearEverything() {
        installedGlobal = []
        installedDevices = [:]
        run(command([], matching: nil))
        for d in HIDDevices.list() where d.kind == .keyboard {
            run(command([], matching: DeviceRef(vendorId: d.vendorId, productId: d.productId, name: d.name)))
        }
    }

    // MARK: Status

    struct DeviceStatus: Identifiable {
        let device: DeviceRef?
        let mappings: [HIDMapping]
        var id: String { device.map { "\($0.vendorId):\($0.productId)" } ?? "global" }
    }

    /// Reads the mappings currently installed in the HID system (blocking; run off the main thread).
    static func currentStatus() -> [DeviceStatus] {
        var out: [DeviceStatus] = [DeviceStatus(device: nil, mappings: parse(output(["property", "--get", "UserKeyMapping"])))]
        var seen = Set<String>()
        for d in HIDDevices.list() where d.kind == .keyboard {
            let ref = DeviceRef(vendorId: d.vendorId, productId: d.productId, name: d.name)
            let key = "\(ref.vendorId):\(ref.productId)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let maps = parse(output(["property", "--matching", matchJSON(ref), "--get", "UserKeyMapping"]))
            out.append(DeviceStatus(device: ref, mappings: maps))
        }
        return out
    }

    private static func parse(_ text: String) -> [HIDMapping] {
        var result: [HIDMapping] = []
        let blocks = text.components(separatedBy: "{").dropFirst()
        for b in blocks {
            func num(_ key: String) -> UInt64? {
                guard let r = b.range(of: key) else { return nil }
                let rest = b[r.upperBound...]
                let digits = rest.drop { !$0.isNumber }.prefix { $0.isNumber }
                return UInt64(digits)
            }
            if let s = num("HIDKeyboardModifierMappingSrc"), let d = num("HIDKeyboardModifierMappingDst") {
                result.append(HIDMapping(src: s, dst: d))
            }
        }
        return result
    }

    // MARK: LaunchAgent persistence

    static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }
    static var launchAgentInstalled: Bool { FileManager.default.fileExists(atPath: launchAgentURL.path) }

    static func writeLaunchAgent() {
        var lines = [shellLine(command(installedGlobal, matching: nil))]
        for (dev, maps) in installedDevices { lines.append(shellLine(command(installedGlobal + maps, matching: dev))) }
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": ["/bin/sh", "-c", lines.joined(separator: "; ")],
            "RunAtLoad": true,
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try FileManager.default.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: launchAgentURL, options: .atomic)
            launchctl(["bootstrap", "gui/\(getuid())", launchAgentURL.path])
        } catch {
            Log.error("LaunchAgent write failed: \(error)")
        }
    }

    static func removeLaunchAgent() {
        launchctl(["bootout", "gui/\(getuid())/\(agentLabel)"])
        try? FileManager.default.removeItem(at: launchAgentURL)
    }

    // MARK: Helpers

    private static func matchJSON(_ d: DeviceRef) -> String {
        "{\"VendorID\":\(d.vendorId),\"ProductID\":\(d.productId)}"
    }

    private static func mappingJSON(_ maps: [HIDMapping]) -> String {
        let entries = maps.map { "{\"HIDKeyboardModifierMappingSrc\":\($0.src),\"HIDKeyboardModifierMappingDst\":\($0.dst)}" }
        return "{\"UserKeyMapping\":[\(entries.joined(separator: ","))]}"
    }

    private static func command(_ maps: [HIDMapping], matching: DeviceRef?) -> [String] {
        var args = ["property"]
        if let matching { args += ["--matching", matchJSON(matching)] }
        args += ["--set", mappingJSON(maps)]
        return args
    }

    private static func shellLine(_ args: [String]) -> String {
        "/usr/bin/hidutil " + args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    }

    @discardableResult
    private static func run(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { Log.error("hidutil failed: \(error)"); return -1 }
    }

    private static func output(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func launchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}

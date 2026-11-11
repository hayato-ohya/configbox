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
    /// All hidutil writes run here, in order, so an older mapping can never land after a newer one.
    private static let queue = DispatchQueue(label: "com.hayato.configbox.hidutil", qos: .userInitiated)

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
        for (dev, maps) in devices { cmds.append(command(merged(global, maps), matching: dev)) }
        installedGlobal = global
        installedDevices = devices
        let keepAtLogin = ConfigStore.shared.config.general.keepHIDMappingsAtLogin
        queue.async {
            for c in cmds { run(c) }
            if keepAtLogin { writeLaunchAgent(global: global, devices: devices) }
        }
        if !global.isEmpty || !devices.isEmpty { startWatching() }
    }

    /// UserKeyMapping is a property of the live HID service: when a keyboard re-enumerates (sleep/wake,
    /// Bluetooth or dongle reconnect, USB hub resets) the new service can start without it. This holds
    /// for the global mappings too (e.g. a Ctrl ⇄ Cmd swap on a Bluetooth keyboard that went to sleep),
    /// so watch for keyboard services appearing and re-apply everything shortly after.
    private static func startWatching() {
        guard watcher == nil else { return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 6] as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(m, { _, _, _, _ in
            HIDUtil.reapplyWork?.cancel()
            let w = DispatchWorkItem { HIDUtil.reapply(reason: "keyboard connected") }
            HIDUtil.reapplyWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)
        }, nil)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))   // enumeration only; no event access needed
        watcher = m
    }

    /// Re-installs the current mappings on every connected keyboard: its own list where it has
    /// device-specific rules, the global list otherwise. Logs keyboards whose mapping had been lost,
    /// so a reset by the system shows up in ConfigBox.log.
    static func reapply(reason: String) {
        guard isActive else { return }
        let global = installedGlobal, devices = installedDevices
        var targets: [(DeviceRef, [HIDMapping])] = []
        var seen = Set<String>()
        for d in HIDDevices.keyboards() {
            let ref = DeviceRef(vendorId: d.vendorId, productId: d.productId, name: d.name)
            guard seen.insert(matchJSON(ref)).inserted else { continue }
            let own = devices.first { sameDevice($0.key, ref) }
            targets.append((own?.key ?? ref, own.map { merged(global, $0.value) } ?? global))
        }
        // Configured keyboards that are not listed (e.g. matched by a name HIDDevices filters out).
        for (dev, maps) in devices where !targets.contains(where: { sameDevice($0.0, dev) }) {
            targets.append((dev, merged(global, maps)))
        }
        queue.async {
            var lost: [String] = []
            var applied = 0
            for (dev, maps) in targets {
                let text = output(["property", "--matching", matchJSON(dev), "--get", "UserKeyMapping"])
                // No service matched: the keyboard is not connected, so there is nothing to set or to have lost.
                guard text.contains("UserKeyMapping") else { continue }
                let now = installedMappings(text)
                if Set(now) != Set(maps) { lost.append("\(dev.name) (had \(now.count), expected \(maps.count))") }
                run(command(maps, matching: dev))
                applied += 1
            }
            Log.info("re-applied HID mappings to \(applied) connected keyboard(s) [\(reason)]"
                     + (lost.isEmpty ? "" : "; mapping had been lost on: " + lost.joined(separator: ", ")))
        }
    }

    private static func sameDevice(_ a: DeviceRef, _ b: DeviceRef) -> Bool {
        a.vendorId == b.vendorId && a.productId == b.productId && (a.vendorId != 0 || a.name == b.name)
    }

    static func clear() {
        var cmds: [[String]] = []
        for dev in installedDevices.keys { cmds.append(command([], matching: dev)) }
        cmds.append(command([], matching: nil))
        installedGlobal = []
        installedDevices = [:]
        queue.sync { for c in cmds { run(c) } }
    }

    /// Clears UserKeyMapping on every keyboard, including mappings made by other tools.
    static func clearEverything() {
        installedGlobal = []
        installedDevices = [:]
        var cmds = [command([], matching: nil)]
        for d in HIDDevices.list() where d.kind == .keyboard {
            cmds.append(command([], matching: DeviceRef(vendorId: d.vendorId, productId: d.productId, name: d.name)))
        }
        queue.sync { for c in cmds { run(c) } }
    }

    // MARK: Status

    struct DeviceStatus: Identifiable {
        let device: DeviceRef?
        let mappings: [HIDMapping]
        var id: String { device.map { "\($0.vendorId):\($0.productId)" } ?? "global" }
    }

    /// Reads the mappings currently installed in the HID system (blocking; run off the main thread).
    static func currentStatus() -> [DeviceStatus] {
        let global = installedMappings(output(["property", "--get", "UserKeyMapping"]))
        var out: [DeviceStatus] = [DeviceStatus(device: nil, mappings: global)]
        var seen = Set<String>()
        for d in HIDDevices.list() where d.kind == .keyboard {
            let ref = DeviceRef(vendorId: d.vendorId, productId: d.productId, name: d.name)
            let key = "\(ref.vendorId):\(ref.productId)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            // A keyboard's list repeats the global mappings; show only what is specific to it.
            let maps = installedMappings(output(["property", "--matching", matchJSON(ref), "--get", "UserKeyMapping"]))
            out.append(DeviceStatus(device: ref, mappings: maps.filter { !global.contains($0) }))
        }
        return out
    }

    /// `hidutil --get` prints one entry per HID service. They hold the same list apart from any
    /// per-device mappings, so report the most common non-empty one rather than concatenating them.
    private static func installedMappings(_ text: String) -> [HIDMapping] {
        let lists = text.components(separatedBy: "UserKeyMapping").dropFirst().map(parse).filter { !$0.isEmpty }
        var counts: [[HIDMapping]: Int] = [:]
        for list in lists { counts[list, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key ?? []
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
        writeLaunchAgent(global: installedGlobal, devices: installedDevices)
    }

    private static func writeLaunchAgent(global: [HIDMapping], devices: [DeviceRef: [HIDMapping]]) {
        var lines = [shellLine(command(global, matching: nil))]
        for (dev, maps) in devices { lines.append(shellLine(command(merged(global, maps), matching: dev))) }
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

    /// A keyboard's full list: its own mappings replace global ones with the same source key
    /// (hidutil honours only one mapping per source).
    private static func merged(_ global: [HIDMapping], _ device: [HIDMapping]) -> [HIDMapping] {
        let srcs = Set(device.map(\.src))
        return global.filter { !srcs.contains($0.src) } + device
    }

    private static func matchJSON(_ d: DeviceRef) -> String {
        guard d.vendorId == 0 else { return "{\"VendorID\":\(d.vendorId),\"ProductID\":\(d.productId)}" }
        // A built-in keyboard has no IDs, and matching on 0:0 also hits every internal sensor service.
        let name = d.name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"Product\":\"\(name)\",\"PrimaryUsagePage\":1,\"PrimaryUsage\":6}"
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

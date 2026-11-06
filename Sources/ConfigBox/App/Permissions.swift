import AppKit
import ApplicationServices
import ServiceManagement

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }
    static func requestScreenRecording() { CGRequestScreenCaptureAccess() }
    static var inputMonitoring: Bool { KeyDeviceTracker.hasPermission }
    static func requestInputMonitoring() {
        KeyDeviceTracker.requestPermission()
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    /// Removes this app's entry from the given TCC service and asks again. Needed when System Settings
    /// shows the toggle on but the grant belongs to a previous code signature (e.g. an ad-hoc build).
    static func resetAndRequest(service: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", service, Bundle.main.bundleIdentifier ?? "com.hayato.configbox"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        if service == "Accessibility" { requestAccessibility(); openAccessibilitySettings() }
        else if service == "ListenEvent" { requestInputMonitoring() }
        else { requestScreenRecording(); openScreenRecordingSettings() }
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }
    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }
    private static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    // Launch at login
    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.error("Launch at login change failed: \(error)")
            }
        }
    }
}

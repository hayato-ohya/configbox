import AppKit
import ApplicationServices
import ScreenCaptureKit
import CBridge

final class WindowItem: Identifiable, ObservableObject {
    let id: CGWindowID
    let app: NSRunningApplication
    let axWindow: AXUIElement
    let title: String
    let isMinimized: Bool
    let isHidden: Bool
    let aspect: CGFloat
    @Published var thumbnail: NSImage?

    init(id: CGWindowID, app: NSRunningApplication, axWindow: AXUIElement, title: String,
         isMinimized: Bool, isHidden: Bool, aspect: CGFloat) {
        self.id = id; self.app = app; self.axWindow = axWindow; self.title = title
        self.isMinimized = isMinimized; self.isHidden = isHidden; self.aspect = aspect
    }

    var appName: String { app.localizedName ?? "" }
    var icon: NSImage? { app.icon }

    func focus() {
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           let w = NSApp.windows.first(where: { $0.windowNumber > 0 && CGWindowID(truncatingIfNeeded: $0.windowNumber) == id }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
            // Fall through: the SkyLight path below is what reliably activates us from the background.
        }
        if isMinimized { AX.set(axWindow, kAXMinimizedAttribute, kCFBooleanFalse) }
        if app.isHidden { app.unhide() }
        // 1. SkyLight: brings the process and this exact window to the front, even from a background app.
        let err = cb_focus_window(app.processIdentifier, id)
        // 2. Accessibility: raise and make main (also handles windows on other Spaces when allowed by the system).
        let raise = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        AX.set(axWindow, kAXMainAttribute, kCFBooleanTrue)
        // 3. Fallback for anything the private API did not handle.
        if NSWorkspace.shared.frontmostApplication != app {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        Log.info("focus pid=\(app.processIdentifier) wid=\(id) '\(title)' skylight=\(err) raise=\(raise.rawValue) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
    }

    func close() {
        if let b: AXUIElement = AX.attr(axWindow, kAXCloseButtonAttribute) {
            AXUIElementPerformAction(b, kAXPressAction as CFString)
        }
    }
    func minimize() { AX.set(axWindow, kAXMinimizedAttribute, kCFBooleanTrue) }
    func hideApp() { app.hide() }
    func quitApp() { app.terminate() }
}

enum WindowEnumerator {
    /// Windows ordered front-to-back (the first element is the current window).
    static func windows(currentAppOnly: Bool, showMinimized: Bool, showHidden: Bool) -> [WindowItem] {
        // Front-to-back order is only guaranteed for the on-screen list. Windows that are not on
        // screen (minimized, hidden app, other Space) get a large index so they sort after visible ones.
        var zOrder: [CGWindowID: Int] = [:]
        if let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for (i, w) in info.enumerated() {
                guard (w["kCGWindowLayer"] as? Int) == 0,
                      let n = (w["kCGWindowNumber"] as? NSNumber)?.uint32Value else { continue }
                zOrder[n] = i
            }
        }
        if let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for (i, w) in info.enumerated() {
                guard (w["kCGWindowLayer"] as? Int) == 0,
                      let n = (w["kCGWindowNumber"] as? NSNumber)?.uint32Value, zOrder[n] == nil else { continue }
                zOrder[n] = 100_000 + i
            }
        }

        let front = NSWorkspace.shared.frontmostApplication
        let me = ProcessInfo.processInfo.processIdentifier
        var items: [WindowItem] = []

        for app in NSWorkspace.shared.runningApplications
        where (app.activationPolicy == .regular || app.processIdentifier == me) && !app.isTerminated {
            if currentAppOnly && app != front { continue }
            // Our own windows: only the real ones (settings, Event Viewer, HID manager, Manage Snap Areas),
            // never the switcher overlay, previews or snap-area editor windows.
            let ownIDs: Set<CGWindowID>? = app.processIdentifier == me
                ? Set(NSApp.windows.filter { $0.isVisible && $0.windowNumber > 0 && $0.identifier.map { MainWindowController.Kind(rawValue: $0.rawValue) != nil } ?? false }
                        .map { CGWindowID(truncatingIfNeeded: $0.windowNumber) })
                : nil
            if let ownIDs, ownIDs.isEmpty { continue }
            if app.isHidden && !showHidden { continue }
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appEl, 0.15)
            guard let wins: [AXUIElement] = AX.attr(appEl, kAXWindowsAttribute) else { continue }
            for w in wins {
                AXUIElementSetMessagingTimeout(w, 0.15)   // a hung app must not stall the event tap
                var wid: CGWindowID = 0
                guard cb_ax_window_id(w, &wid) == .success, wid != 0 else { continue }
                if let ownIDs, !ownIDs.contains(wid) { continue }
                let subrole: String? = AX.attr(w, kAXSubroleAttribute)
                guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else { continue }
                let minimized: Bool = AX.attr(w, kAXMinimizedAttribute) ?? false
                if minimized && !showMinimized { continue }
                let title: String = AX.attr(w, kAXTitleAttribute) ?? ""
                let size = AX.attrValue(w, kAXSizeAttribute, .cgSize, CGSize.zero) ?? CGSize(width: 16, height: 10)
                let aspect = size.height > 0 ? size.width / size.height : 1.6
                items.append(WindowItem(id: wid, app: app, axWindow: w,
                                        title: title.isEmpty ? (app.localizedName ?? "") : title,
                                        isMinimized: minimized, isHidden: app.isHidden, aspect: aspect))
            }
        }

        items.sort { a, b in
            let za = zOrder[a.id] ?? Int.max, zb = zOrder[b.id] ?? Int.max
            if za != zb { return za < zb }
            return a.title < b.title
        }
        // Minimized / hidden windows go last.
        let active = items.filter { !$0.isMinimized && !$0.isHidden }
        let inactive = items.filter { $0.isMinimized || $0.isHidden }
        return active + inactive
    }

    /// Fills in thumbnails using ScreenCaptureKit. Requires Screen Recording permission; silently skips otherwise.
    static func captureThumbnails(for items: [WindowItem], height: CGFloat) async {
        guard CGPreflightScreenCaptureAccess() else { return }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        let scale = NSScreen.main?.backingScaleFactor ?? 2

        await withTaskGroup(of: Void.self) { group in
            for item in items {
                guard let scw = byID[item.id] else { continue }
                group.addTask {
                    if Task.isCancelled { return }
                    let filter = SCContentFilter(desktopIndependentWindow: scw)
                    let cfg = SCStreamConfiguration()
                    let frame = scw.frame
                    let h = height, w = max(1, frame.width * (h / max(frame.height, 1)))
                    cfg.width = Int(w * scale)
                    cfg.height = Int(h * scale)
                    cfg.showsCursor = false
                    cfg.scalesToFit = true
                    guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) else { return }
                    let img = NSImage(cgImage: cg, size: NSSize(width: w, height: h))
                    await MainActor.run { item.thumbnail = img }
                }
            }
        }
    }
}

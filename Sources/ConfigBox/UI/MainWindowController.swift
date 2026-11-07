import AppKit
import SwiftUI

/// Owns every window of the app. Windows are created on demand and fully released when closed,
/// and the app only appears in the Dock while at least one window is open.
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()

    enum Kind: String { case main, eventViewer, hidManager, snapAreas }

    let state = UIState()
    private var windows: [Kind: NSWindow] = [:]
    private var viewerKeyMonitor: Any?

    func show(section: UISection? = nil) {
        if let section { state.section = section }
        show(.main)
    }

    func show(_ kind: Kind) {
        if windows[kind] == nil {
            let w: NSWindow
            switch kind {
            case .main:
                w = makeWindow(MainView(state: state), title: "ConfigBox", size: NSSize(width: 1040, height: 660), min: NSSize(width: 860, height: 520))
                w.styleMask.insert(.fullSizeContentView)
                w.titlebarAppearsTransparent = true
                w.titleVisibility = .hidden
            case .eventViewer:
                w = makeWindow(EventViewerView(), title: L("ConfigBox Event Viewer"), size: NSSize(width: 900, height: 560), min: NSSize(width: 640, height: 400))
            case .hidManager:
                w = makeWindow(HIDManagerView(), title: L("HID Device Manager"), size: NSSize(width: 640, height: 620), min: NSSize(width: 520, height: 420))
            case .snapAreas:
                w = makeWindow(SnapAreaManageView(), title: L("Manage Snap Areas"), size: NSSize(width: 860, height: 560), min: NSSize(width: 700, height: 420))
            }
            w.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
            windows[kind] = w
            if kind == .eventViewer { installViewerKeyMonitor(for: w) }
        }
        NSApp.setActivationPolicy(.regular)
        windows[kind]?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow<V: View>(_ root: V, title: String, size: NSSize, min: NSSize) -> NSWindow {
        let w = NSWindow(contentViewController: NSHostingController(rootView: root.environmentObject(ConfigStore.shared)))
        w.title = title
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(size)
        w.minSize = min
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        return w
    }

    /// While the Event Viewer is the key window, every key press would otherwise reach a window with
    /// no responder for it and macOS would beep. Swallow those locally; the global tap still logs them.
    /// Command shortcuts (⌘W, ⌘Q, ⌘C, …) are left alone.
    private func installViewerKeyMonitor(for window: NSWindow) {
        viewerKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak window] e in
            guard let window, e.window === window, window.isKeyWindow else { return e }
            if e.modifierFlags.contains(.command) { return e }
            if window.firstResponder is NSTextView { return e }   // let text fields work normally
            return nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, let id = w.identifier, let kind = Kind(rawValue: id.rawValue) else { return }
        if kind == .eventViewer, let m = viewerKeyMonitor { NSEvent.removeMonitor(m); viewerKeyMonitor = nil }
        windows[kind] = nil   // free the whole SwiftUI hierarchy while running in the background
        refreshActivationPolicy()
    }

    func refreshActivationPolicy() {
        if windows.isEmpty && !SnapAreaEditSession.shared.isActive { NSApp.setActivationPolicy(.accessory) }
    }
}

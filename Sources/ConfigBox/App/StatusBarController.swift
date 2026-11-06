import AppKit

final class StatusBarController: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private let store = ConfigStore.shared

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"), let img = NSImage(contentsOf: url) {
                // Template image: macOS tints it for light / dark menu bars and the active state.
                if let url2 = Bundle.main.url(forResource: "MenuBarIcon@2x", withExtension: "png"), let rep = NSImageRep(contentsOf: url2) { img.addRepresentation(rep) }
                img.isTemplate = true
                img.size = NSSize(width: 20, height: 20)
                it.button?.image = img
            } else {
                it.button?.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: "ConfigBox")
            }
            let menu = NSMenu()
            menu.delegate = self
            it.menu = menu
            item = it
        } else if !visible, let it = item {
            NSStatusBar.system.removeStatusItem(it)
            item = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let g = store.config.general
        menu.addItem(withTitle: "Open ConfigBox…", action: #selector(openWindow), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Event Viewer…", action: #selector(openEventViewer), keyEquivalent: "").target = self
        menu.addItem(withTitle: "HID Device Manager…", action: #selector(openHIDManager), keyEquivalent: "").target = self
        menu.addItem(.separator())
        add(menu, "Keyboard Shortcuts & Remapping", #selector(toggleKeyboard), g.keyboardEnabled)
        add(menu, "Trackpad Gestures", #selector(toggleTrackpad), g.trackpadEnabled)
        add(menu, "Mouse Triggers", #selector(toggleMouse), g.mouseEnabled)
        add(menu, "Window Switcher", #selector(toggleSwitcher), store.config.switcher.enabled)
        add(menu, "Window Snapping", #selector(toggleSnapping), store.config.snapping.enabled)
        menu.addItem(.separator())
        if !Permissions.accessibility {
            let i = menu.addItem(withTitle: "⚠︎ Accessibility permission required", action: #selector(openAccessibility), keyEquivalent: "")
            i.target = self
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Reload Config File", action: #selector(reload), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ConfigBox", action: #selector(quit), keyEquivalent: "q").target = self
    }

    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, _ on: Bool) {
        let i = menu.addItem(withTitle: title, action: sel, keyEquivalent: "")
        i.target = self
        i.state = on ? .on : .off
    }

    @objc private func openWindow() { MainWindowController.shared.show() }
    @objc private func openEventViewer() { MainWindowController.shared.show(.eventViewer) }
    @objc private func openHIDManager() { MainWindowController.shared.show(.hidManager) }
    @objc private func toggleSnapping() { store.config.snapping.enabled.toggle() }
    @objc private func toggleKeyboard() { store.config.general.keyboardEnabled.toggle() }
    @objc private func toggleTrackpad() { store.config.general.trackpadEnabled.toggle() }
    @objc private func toggleMouse() { store.config.general.mouseEnabled.toggle() }
    @objc private func toggleSwitcher() { store.config.switcher.enabled.toggle() }
    @objc private func openAccessibility() { Permissions.openAccessibilitySettings() }
    @objc private func reload() { store.load() }
    @objc private func quit() { NSApp.terminate(nil) }
}

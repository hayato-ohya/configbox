import AppKit
import SwiftUI

final class SwitcherModel: ObservableObject {
    @Published var items: [WindowItem] = []
    @Published var selected = 0
    @Published var settings = SwitcherSettings()
}

private final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// AltTab-style window switcher driven by the shared event tap.
final class SwitcherController {
    static let shared = SwitcherController()

    let model = SwitcherModel()
    private var settings = SwitcherSettings()
    private var panel: NSPanel?
    private var captureTask: Task<Void, Never>?
    private(set) var isActive = false
    private var holdMode = false
    /// Modifier released but the switcher is still open (release delay running).
    private var lingering = false
    private var shiftHeld = false
    private var pendingCommit: DispatchWorkItem?

    private init() {}

    func apply(settings: SwitcherSettings) {
        self.settings = settings
        if !settings.enabled && isActive { cancel() }
    }

    // MARK: Event handling (called on the event tap)

    /// Returns true if the event was consumed.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard settings.enabled || isActive else { return false }
        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let mods = KeyCodes.modifiers(for: code, flags: event.flags)
        let sc = settings.shortcut

        if !isActive {
            guard type == .keyDown, code == sc.keyCode, !sc.modifiers.isEmpty,
                  mods.subtracting(.shift) == sc.modifiers else { return false }
            show(holdMode: true, reverse: mods.contains(.shift))
            return true
        }

        if holdMode && !lingering && (type == .keyDown || type == .keyUp)
            && mods.intersection(sc.modifiers) != sc.modifiers {
            // The modifier is no longer held but we never saw its flagsChanged (e.g. the event tap timed out):
            // treat this as the release so the switcher cannot get stuck swallowing every key.
            shiftHeld = mods.contains(.shift)
            if settings.releaseDelayMs > 0 || shiftHeld {
                startLinger()
            } else {
                commit()
                return false   // let the key through to the newly focused window
            }
        }

        switch type {
        case .keyDown:
            let shift = mods.contains(.shift)
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            switch code {
            case sc.keyCode, 48:            // the shortcut key / Tab: forward, with ⇧ backward
                shift ? step(-1) : step(1)
                touchLinger()
            case 124, 125: step(1); touchLinger()
            case 123, 126: step(-1); touchLinger()
            case 53: cancel()
            case 36, 76: commit()
            case 12: withSelected { $0.quitApp(); refresh() }
            case 13: withSelected { $0.close(); refresh() }
            case 46: withSelected { $0.minimize(); refresh() }
            case 4: withSelected { $0.hideApp(); refresh() }
            default:
                if lingering && !isRepeat {
                    // The user started typing: switch now and let the key through to the new window.
                    commit()
                    return false
                }
            }
            return true
        case .keyUp:
            return !lingering || code == sc.keyCode || code == 48 || (123...126).contains(code)
        case .flagsChanged:
            guard holdMode else { return false }
            let held = mods.intersection(sc.modifiers) == sc.modifiers
            shiftHeld = mods.contains(.shift)
            if !held && !lingering {
                if settings.releaseDelayMs > 0 || shiftHeld { startLinger() } else { commit() }
            } else if held && lingering {
                // Modifier pressed again within the delay: back to hold mode.
                pendingCommit?.cancel(); pendingCommit = nil
                lingering = false
            } else if lingering {
                // ⇧ pressed: stay open while it is held (the user is stepping backwards); released: restart the timer.
                touchLinger()
            }
            return false // let modifier state flow so apps don't see a stuck modifier
        default:
            return false
        }
    }

    // MARK: Release delay

    private func startLinger() {
        lingering = true
        touchLinger()
    }

    /// (Re)starts the commit timer; every navigation key press gives the user the full delay again.
    private func touchLinger() {
        guard lingering else { return }
        pendingCommit?.cancel()
        pendingCommit = nil
        if shiftHeld { return }   // no countdown while ⇧ is held; it starts when ⇧ is released
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive, self.lingering else { return }
            self.commit()
        }
        pendingCommit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(0, settings.releaseDelayMs)), execute: work)
    }

    // MARK: Presentation

    func show(holdMode: Bool, reverse: Bool) {
        guard !isActive else { return }
        let items = WindowEnumerator.windows(currentAppOnly: settings.currentAppOnly,
                                             showMinimized: settings.showMinimized,
                                             showHidden: settings.showHidden)
        guard !items.isEmpty else { Log.info("switcher: no windows"); return }
        Log.info("switcher: show \(items.count) windows, holdMode=\(holdMode): " + items.prefix(6).map { "\($0.id):\($0.appName)" }.joined(separator: ", "))
        isActive = true
        self.holdMode = holdMode
        model.settings = settings
        model.items = items
        model.selected = items.count > 1 ? (reverse ? items.count - 1 : 1) : 0
        presentPanel()

        if settings.showThumbnails {
            let h = CGFloat(settings.thumbnailHeight)
            captureTask = Task { await WindowEnumerator.captureThumbnails(for: items, height: h) }
        }
    }

    private func presentPanel() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let p = SwitcherPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        let view = SwitcherView(model: model,
                                onHover: { [weak self] i in self?.model.selected = i },
                                onClick: { [weak self] i in self?.model.selected = i; self?.commit() },
                                onCancel: { [weak self] in self?.cancel() })
        p.contentView = NSHostingView(rootView: view)
        p.setFrame(screen.frame, display: false)
        p.orderFrontRegardless()
        panel = p
    }

    private func step(_ d: Int) {
        let n = model.items.count
        guard n > 0 else { return }
        model.selected = ((model.selected + d) % n + n) % n
    }

    private func withSelected(_ f: (WindowItem) -> Void) {
        guard model.items.indices.contains(model.selected) else { return }
        f(model.items[model.selected])
    }

    private func refresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.isActive else { return }
            let items = WindowEnumerator.windows(currentAppOnly: self.settings.currentAppOnly,
                                                 showMinimized: self.settings.showMinimized,
                                                 showHidden: self.settings.showHidden)
            if items.isEmpty { self.cancel(); return }
            let old = self.model.items
            // Reuse thumbnails already captured.
            for item in items { item.thumbnail = old.first { $0.id == item.id }?.thumbnail }
            self.model.items = items
            self.model.selected = min(self.model.selected, items.count - 1)
        }
    }

    func commit() {
        guard isActive else { return }
        let target = model.items.indices.contains(model.selected) ? model.items[model.selected] : nil
        Log.info("switcher: commit index=\(model.selected) target=\(target?.title ?? "nil")")
        hide()
        target?.focus()
    }

    func cancel() { hide() }

    private func hide() {
        isActive = false
        lingering = false
        shiftHeld = false
        pendingCommit?.cancel()
        pendingCommit = nil
        captureTask?.cancel()
        captureTask = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        model.items = []   // releases thumbnails
    }
}

import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ConfigStore.shared
    private let statusBar = StatusBarController()
    private var bag = Set<AnyCancellable>()
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SIGTERM (pkill, logout, launchd) should run the same cleanup as Quit: HID remaps and pointer
        // settings are restored in applicationWillTerminate.
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        termSource = src

        // Accessibility calls run on the main thread, which also serves the event tap. The default timeout
        // is 6 s per call, so an unresponsive app would freeze all input: cap it for every element.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)

        store.$config
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] cfg in self?.apply(cfg) }
            .store(in: &bag)
        apply(store.config)

        InputRouter.shared.start()
        TrackpadEngine.shared.onGesture = { [weak self] g in self?.handle(gesture: g) }
        TrackpadEngine.shared.onClick = { [weak self] g in self?.handleClick(gesture: g) ?? false }

        NotificationCenter.default.addObserver(forName: .configBoxReconcile, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.apply(self.store.config)
        }
        logDisplays()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.logDisplays()
            self?.relinkSnapAreas()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.store.config.general.trackpadEnabled { TrackpadEngine.shared.restart() }
            InputRouter.shared.apply(config: self.store.config)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { HIDUtil.reapplyDevices() }
        }

        // Debug / scripting aid: `ConfigBox --section trackpad|keyboard|remap|switcher|settings`
        let args = CommandLine.arguments
        // Debug: `--delete-first-area-after <seconds>` removes the first snap area through the normal code path.
        if let i = args.firstIndex(of: "--delete-first-area-after"), i + 1 < args.count, let secs = Double(args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in
                if let id = self?.store.config.snapAreas.first?.id { SnapAreaEditSession.shared.remove(id); Log.info("debug: removed area \(id)") }
            }
        }
        // Debug: `--attach-first-area` opens the attach HUD for the first area after 2 s and presses Attach after 5 s.
        if args.contains("--attach-first-area") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                if let id = self?.store.config.snapAreas.first?.id { WindowAttachSession.shared.begin(areaID: id) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { WindowAttachSession.shared.attach() }
        }
        // Debug: `--move-shortcut <from> <delta>` reorders the visible keyboard-shortcut list like the UI would.
        if let i = args.firstIndex(of: "--move-shortcut"), i + 2 < args.count, let from = Int(args[i + 1]), let delta = Int(args[i + 2]) {
            let visible = store.config.triggers.filter { $0.kind.isShortcut && $0.appBundleId == nil }.map(\.id)
            if visible.indices.contains(from) { store.moveTrigger(visible[from], visible: visible, by: delta) }
        }
        if let i = args.firstIndex(of: "--section"), i + 1 < args.count, let s = UISection(rawValue: args[i + 1]) {
            MainWindowController.shared.show(section: s)
            if args.contains("--mouse-settings") { MainWindowController.shared.state.mousePage = 1 }
            if args.contains("--trackpad-settings") { MainWindowController.shared.state.trackpadPage = 1 }
            if let j = args.firstIndex(of: "--remap-category"), j + 1 < args.count, let c = RemapCategory(rawValue: args[j + 1]) {
                let st = MainWindowController.shared.state
                st.remapCategory = c
                if args.contains("--select-first") {
                    switch c {
                    case .simple: st.selectedRemapID = store.config.simpleModifications.first?.id
                    case .macro: st.selectedRemapID = store.config.keyActionRules.first?.id
                    case .chord: st.selectedRemapID = store.config.chordRules.first?.id
                    case .modTap: st.selectedRemapID = store.config.complexRules.first?.id
                    }
                }
            }
            if args.contains("--select-first") {
                MainWindowController.shared.state.selectedTrigger = store.config.triggers.first {
                    switch s { case .trackpad: $0.kind.isGesture; case .mouse: $0.kind.isMouse; default: $0.kind.isShortcut }
                }?.id
            }
        } else if let i = args.firstIndex(of: "--edit-areas") {
            SnapAreaEditSession.shared.begin()
            if i + 1 < args.count, args[i + 1] == "frames" { SnapAreaEditSession.shared.editTarget = .frames }
        } else if args.contains("--create-area") {
            MainWindowController.shared.show(section: .snapping)
            SnapAreaEditSession.shared.addArea(on: NSScreen.main ?? .underMouse)
        } else if let i = args.firstIndex(of: "--window"), i + 1 < args.count, let k = MainWindowController.Kind(rawValue: args[i + 1]) {
            MainWindowController.shared.show(k)
        } else if !Permissions.accessibility {
            Permissions.requestAccessibility()
            MainWindowController.shared.show(section: .settings)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowController.shared.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flushPendingSave()
        // With login persistence on, the HID-level mappings intentionally outlive the app.
        if !store.config.general.keepHIDMappingsAtLogin { HIDUtil.clear() }
        PointerSettings.shared.restore()
        TrackpadEngine.shared.stop()
    }

    private func logDisplays() {
        Log.info("displays: " + NSScreen.screens.map { s in
            let d = s.displayIdentity
            return "\(s.displayID) “\(s.localizedName)” \(d.vendor)/\(d.model)/\(d.serial)"
        }.joined(separator: ", "))
    }

    /// Points snap areas at the right display after a restore on another Mac or a display change.
    private func relinkSnapAreas() {
        guard !SnapAreaEditSession.shared.isActive else { return }
        var areas = store.config.snapAreas
        if SnapArea.relink(&areas) { store.config.snapAreas = areas }
    }

    private func apply(_ cfg: Config) {
        relinkSnapAreas()
        statusBar.setVisible(cfg.general.showMenuBarIcon)
        InputRouter.shared.apply(config: cfg)
        let tp = TrackpadEngine.shared
        tp.swipeThreshold = Float(cfg.general.swipeThreshold)
        tp.tapMaxDuration = Double(cfg.general.tapMaxDurationMs) / 1000
        tp.tapMaxMovement = Float(cfg.general.tapMaxMovement)
        tp.cooldown = Double(cfg.general.gestureCooldownMs) / 1000
        tp.axisRatio = Float(cfg.general.swipeAxisRatio)
        tp.maxTouchSize = Float(cfg.general.maxTouchSize)
        tp.suppressScroll = cfg.general.suppressScrollAfterGesture
        tp.suppressTail = Double(cfg.general.scrollSuppressTailMs) / 1000
        tp.configuredFingerCounts = Set(cfg.triggers.compactMap { t -> Int? in
            guard t.enabled, cfg.general.trackpadEnabled, case .gesture(let g) = t.kind, g.fingers >= 3 else { return nil }
            return g.fingers
        })
        tp.clickFingerCounts = Set(cfg.triggers.compactMap { t -> Int? in
            guard t.enabled, cfg.general.trackpadEnabled, case .gesture(let g) = t.kind, g.kind == .click else { return nil }
            return g.fingers
        })
        let wantsTrackpad = (cfg.general.trackpadEnabled && cfg.triggers.contains { $0.enabled && $0.kind.isGesture })
            || EventMonitor.shared.trackpadViewerActive
        if wantsTrackpad && !tp.isRunning { tp.start() }
        if !wantsTrackpad && tp.isRunning { tp.stop() }
    }

    private func handle(gesture: Gesture) {
        guard store.config.general.trackpadEnabled else { EventMonitor.shared.record(gesture: gesture, handled: false); return }
        let match = trigger(for: gesture)
        EventMonitor.shared.record(gesture: gesture, handled: match != nil)
        if let match { ActionRunner.run(match.action) }
    }

    /// Runs on the event tap: only a click some trigger (for the frontmost app) wants is taken from the system.
    private func handleClick(gesture: Gesture) -> Bool {
        guard store.config.general.trackpadEnabled, let match = trigger(for: gesture) else { return false }
        EventMonitor.shared.record(gesture: gesture, handled: true)
        let action = match.action
        DispatchQueue.main.async { ActionRunner.run(action) }
        return true
    }

    private func trigger(for gesture: Gesture) -> Trigger? {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var match: Trigger?
        for t in store.config.triggers where t.enabled {
            guard case .gesture(let g) = t.kind, g == gesture else { continue }
            if let app = t.appBundleId {
                if app == front { return t }
            } else if match == nil {
                match = t
            }
        }
        return match
    }
}

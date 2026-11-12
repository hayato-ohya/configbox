import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ConfigStore.shared
    private let statusBar = StatusBarController()
    private var bag = Set<AnyCancellable>()
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two copies of the app (say /Applications and a fresh build) would each keep their own settings in
        // memory and save over each other, so a change made in one comes back from the other. Hand over to the
        // copy already running. exit() rather than terminate: willTerminate would clear its HID mappings.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != getpid() && !$0.isTerminated }
        if let other = others.first {
            Log.info("Another ConfigBox is already running (pid \(other.processIdentifier), \(other.bundleURL?.path ?? "?")); exiting")
            other.activate()
            exit(0)
        }
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
        TrackpadEngine.shared.onGesture = { [weak self] input in self?.handle(input) }
        TrackpadEngine.shared.onClick = { [weak self] input in self?.handleClick(input) ?? false }

        NotificationCenter.default.addObserver(forName: .configBoxReconcile, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.apply(self.store.config)
        }
        // Test aid: `--debug-hooks` lets a script run the Drag action and fake resting fingers.
        if CommandLine.arguments.contains("--debug-hooks") {
            let center = DistributedNotificationCenter.default()
            center.addObserver(forName: Notification.Name("ConfigBoxDebugDrag"), object: nil, queue: .main) { _ in
                DragLock.shared.toggle()
            }
            center.addObserver(forName: Notification.Name("ConfigBoxDebugFingers"), object: nil, queue: .main) { note in
                DragHold.shared.debugFingers(Int(note.object as? String ?? ""))
            }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { HIDUtil.reapply(reason: "wake") }
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
        } else if args.contains("--about") {
            statusBar.showAbout()
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
        let gestures: [Gesture] = cfg.general.trackpadEnabled ? cfg.triggers.compactMap { t in
            guard t.enabled, case .gesture(let g) = t.kind else { return nil }
            return g
        } : []
        tp.gestures = gestures
        tp.regionSize = cfg.general.touchRegionSize
        tp.configuredFingerCounts = Set(gestures.map(\.totalFingers).filter { $0 >= 3 })
        tp.clickFingerCounts = Set(gestures.filter { $0.kind == .click }.map(\.totalFingers))
        tp.doubleClickFingerCounts = Set(gestures.filter { $0.kind == .doubleClick }.map(\.totalFingers))
        tp.doubleTapInterval = NSEvent.doubleClickInterval
        let wantsTrackpad = (cfg.general.trackpadEnabled && (cfg.general.dragHoldEnabled || cfg.triggers.contains { $0.enabled && $0.kind.isGesture }))
            || EventMonitor.shared.trackpadViewerActive
        if wantsTrackpad && !tp.isRunning { tp.start() }
        if !wantsTrackpad && tp.isRunning { tp.stop() }
    }

    private func handle(_ input: GestureInput) {
        guard store.config.general.trackpadEnabled else { EventMonitor.shared.record(gesture: input.gesture, handled: false); return }
        let match = trigger(for: input)
        EventMonitor.shared.record(gesture: match?.gesture ?? input.gesture, handled: match != nil)
        if let match { ActionRunner.run(match.trigger.action) }
    }

    /// Runs on the event tap: only a click some trigger (for the frontmost app) wants is taken from the system.
    private func handleClick(_ input: GestureInput) -> Bool {
        guard store.config.general.trackpadEnabled, let match = trigger(for: input) else { return false }
        EventMonitor.shared.record(gesture: match.gesture, handled: true)
        let action = match.trigger.action
        DispatchQueue.main.async { ActionRunner.run(action) }
        return true
    }

    /// The trigger for what the trackpad saw: the most specific region / resting finger wins; between equally
    /// specific ones, a trigger for the frontmost app beats a global one, then the first in the list.
    private func trigger(for input: GestureInput) -> (trigger: Trigger, gesture: Gesture)? {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let size = store.config.general.touchRegionSize
        var best: (trigger: Trigger, gesture: Gesture, rank: Int)?
        for t in store.config.triggers where t.enabled {
            guard case .gesture(let g) = t.kind, let score = GestureMatcher.score(g, input, size: size) else { continue }
            if let app = t.appBundleId, app != front { continue }
            let rank = score * 2 + (t.appBundleId == nil ? 0 : 1)
            if best == nil || rank > best!.rank { best = (t, g, rank) }
        }
        return best.map { ($0.trigger, $0.gesture) }
    }
}

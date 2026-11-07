import AppKit

enum ActionRunner {
    /// Runs actions one after another with a short gap so key events land in order.
    static func runSequence(_ actions: [Action], index: Int = 0) {
        guard index < actions.count else { return }
        run(actions[index])
        guard index + 1 < actions.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) { runSequence(actions, index: index + 1) }
    }

    static func run(_ action: Action) {
        switch action {
        case .none:
            break
        case .keyboardShortcut(let combo):
            KeySynth.tap(combo)
        case .launchApp(let idOrPath):
            launch(idOrPath)
        case .openURL(let s):
            if let url = URL(string: s) { NSWorkspace.shared.open(url) }
        case .runShell(let script):
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", script]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
        case .typeText(let text):
            KeySynth.type(text)
        case .runAppleScript(let source):
            DispatchQueue.global(qos: .userInitiated).async {
                var err: NSDictionary?
                NSAppleScript(source: source)?.executeAndReturnError(&err)
                if let err { Log.error("AppleScript error: \(err)") }
            }
        case .window(let w):
            WindowManager.perform(w)
        case .snapAreaFrame(let id):
            WindowManager.applySnapAreaFrame(id)
        case .windowCycle(let steps):
            WindowManager.cycle(steps)
        case .system(let s):
            SystemActions.perform(s)
        case .showWindowSwitcher:
            SwitcherController.shared.show(holdMode: false, reverse: false)
        }
    }

    private static func launch(_ idOrPath: String) {
        let url: URL?
        if idOrPath.hasPrefix("/") {
            url = URL(fileURLWithPath: idOrPath)
        } else {
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: idOrPath)
        }
        guard let url else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    }
}

enum SystemActions {
    static func perform(_ a: SystemAction) {
        switch a {
        case .missionControl: openMissionControl(args: [])
        case .applicationWindows: openMissionControl(args: ["2"])
        case .showDesktop: openMissionControl(args: ["1"])
        case .launchpad:
            // macOS 26 replaced Launchpad with the Apps launcher.
            let launchpad = "/System/Applications/Launchpad.app"
            let path = FileManager.default.fileExists(atPath: launchpad) ? launchpad : "/System/Applications/Apps.app"
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
        case .moveSpaceLeft: KeySynth.tap(KeyCombo(keyCode: 123, modifiers: [.control]))
        case .moveSpaceRight: KeySynth.tap(KeyCombo(keyCode: 124, modifiers: [.control]))
        case .lockScreen: KeySynth.tap(KeyCombo(keyCode: 12, modifiers: [.control, .command]))
        case .sleepDisplay:
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            p.arguments = ["displaysleepnow"]
            try? p.run()
        case .volumeUp: KeySynth.mediaKey(.soundUp)
        case .volumeDown: KeySynth.mediaKey(.soundDown)
        case .mute: KeySynth.mediaKey(.mute)
        case .brightnessUp: KeySynth.mediaKey(.brightnessUp)
        case .brightnessDown: KeySynth.mediaKey(.brightnessDown)
        case .playPause: KeySynth.mediaKey(.play)
        case .nextTrack: KeySynth.mediaKey(.next)
        case .previousTrack: KeySynth.mediaKey(.previous)
        case .middleClick: KeySynth.middleClick()
        case .mouseBack: KeySynth.mouseButtonClick(3)
        case .mouseForward: KeySynth.mouseButtonClick(4)
        case .hideFrontApp: NSWorkspace.shared.frontmostApplication?.hide()
        case .quitFrontApp: NSWorkspace.shared.frontmostApplication?.terminate()
        case .closeWindow: WindowManager.pressButton(kAXCloseButtonAttribute)
        case .minimizeWindow: WindowManager.pressButton(kAXMinimizeButtonAttribute)
        case .zoomWindow: WindowManager.pressButton(kAXZoomButtonAttribute)
        case .toggleDarkMode:
            ActionRunner.run(.runAppleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"))
        }
    }

    private static func openMissionControl(args: [String]) {
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.arguments = args
        cfg.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    }
}

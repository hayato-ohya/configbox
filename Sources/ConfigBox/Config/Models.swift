import Foundation
import CoreGraphics

// MARK: - Modifiers

struct Modifiers: OptionSet, Hashable, Codable {
    let rawValue: UInt8
    init(rawValue: UInt8) { self.rawValue = rawValue }

    static let control  = Modifiers(rawValue: 1 << 0)
    static let option   = Modifiers(rawValue: 1 << 1)
    static let shift    = Modifiers(rawValue: 1 << 2)
    static let command  = Modifiers(rawValue: 1 << 3)
    static let function = Modifiers(rawValue: 1 << 4)

    static let all: [Modifiers] = [.control, .option, .shift, .command, .function]

    init(cgFlags: CGEventFlags) {
        var m: Modifiers = []
        if cgFlags.contains(.maskControl)     { m.insert(.control) }
        if cgFlags.contains(.maskAlternate)   { m.insert(.option) }
        if cgFlags.contains(.maskShift)       { m.insert(.shift) }
        if cgFlags.contains(.maskCommand)     { m.insert(.command) }
        if cgFlags.contains(.maskSecondaryFn) { m.insert(.function) }
        self = m
    }

    var cgFlags: CGEventFlags {
        var f: CGEventFlags = []
        if contains(.control)  { f.insert(.maskControl) }
        if contains(.option)   { f.insert(.maskAlternate) }
        if contains(.shift)    { f.insert(.maskShift) }
        if contains(.command)  { f.insert(.maskCommand) }
        if contains(.function) { f.insert(.maskSecondaryFn) }
        return f
    }

    var symbols: String {
        var s = ""
        if contains(.function) { s += "fn" }
        if contains(.control)  { s += "⌃" }
        if contains(.option)   { s += "⌥" }
        if contains(.shift)    { s += "⇧" }
        if contains(.command)  { s += "⌘" }
        return s
    }

    var name: String {
        var parts: [String] = []
        if contains(.function) { parts.append("fn") }
        if contains(.control)  { parts.append("Control") }
        if contains(.option)   { parts.append("Option") }
        if contains(.shift)    { parts.append("Shift") }
        if contains(.command)  { parts.append("Command") }
        return parts.isEmpty ? "None" : parts.joined(separator: " + ")
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UInt8.self)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

// MARK: - Key combo / Gesture

struct KeyCombo: Codable, Hashable {
    var keyCode: UInt16
    var modifiers: Modifiers = []

    var display: String { modifiers.symbols + KeyCodes.name(for: keyCode) }
}

enum GestureKind: String, Codable, CaseIterable, Identifiable {
    case tap, swipeUp, swipeDown, swipeLeft, swipeRight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tap: "Tap"
        case .swipeUp: "Swipe Up"
        case .swipeDown: "Swipe Down"
        case .swipeLeft: "Swipe Left"
        case .swipeRight: "Swipe Right"
        }
    }
    var symbol: String {
        switch self {
        case .tap: "hand.tap"
        case .swipeUp: "arrow.up"
        case .swipeDown: "arrow.down"
        case .swipeLeft: "arrow.left"
        case .swipeRight: "arrow.right"
        }
    }
}

struct Gesture: Codable, Hashable {
    var fingers: Int
    var kind: GestureKind
    var display: String { "\(fingers) Finger \(kind.title)" }
}

// MARK: - Mouse

enum MouseButton: Int, Codable, CaseIterable, Identifiable {
    case left = 0, right = 1, middle = 2, button4 = 3, button5 = 4, button6 = 5, button7 = 6, button8 = 7
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .middle: "Middle"
        default: "Button \(rawValue + 1)"
        }
    }
    /// Left and right *clicks* are only usable as triggers together with a modifier
    /// (gestures may use a bare right button; an unmoved press is replayed as a normal click).
    var needsModifier: Bool { self == .left || self == .right }
}

enum Direction: String, Codable, CaseIterable, Identifiable {
    case up, down, left, right
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String { "arrow.\(rawValue)" }
}

enum MouseTrigger: Codable, Hashable {
    case click(button: MouseButton, modifiers: Modifiers, clicks: Int)
    case scroll(direction: Direction, modifiers: Modifiers)
    case gesture(button: MouseButton, direction: Direction, modifiers: Modifiers)

    var display: String {
        switch self {
        case .click(let b, let m, let c):
            (m.symbols.isEmpty ? "" : m.symbols + " ") + (c >= 2 ? "Double " : "") + "\(b.title) Click"
        case .scroll(let d, let m):
            (m.symbols.isEmpty ? "" : m.symbols + " ") + "Scroll \(d.title)"
        case .gesture(let b, let d, let m):
            (m.symbols.isEmpty ? "" : m.symbols + " ") + "\(b.title) Button + Move \(d.title)"
        }
    }
    var symbol: String {
        switch self {
        case .click: "computermouse"
        case .scroll: "scroll"
        case .gesture(_, let d, _): d.symbol
        }
    }
    var modifiers: Modifiers {
        switch self {
        case .click(_, let m, _), .scroll(_, let m), .gesture(_, _, let m): m
        }
    }
}

enum TriggerKind: Codable, Hashable {
    case shortcut(KeyCombo)
    case gesture(Gesture)
    case mouse(MouseTrigger)

    var display: String {
        switch self {
        case .shortcut(let k): k.display
        case .gesture(let g): g.display
        case .mouse(let m): m.display
        }
    }
    var symbol: String {
        switch self {
        case .shortcut: "keyboard"
        case .gesture(let g): g.kind.symbol
        case .mouse(let m): m.symbol
        }
    }
    var isGesture: Bool { if case .gesture = self { return true } else { return false } }
    var isShortcut: Bool { if case .shortcut = self { return true } else { return false } }
    var isMouse: Bool { if case .mouse = self { return true } else { return false } }
}

// MARK: - Actions

enum WindowAction: String, Codable, CaseIterable, Identifiable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird, leftTwoThirds, rightTwoThirds
    case maximize, almostMaximize, center, nextDisplay, previousDisplay

    var id: String { rawValue }
    var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .topLeft: "Top Left Quarter"
        case .topRight: "Top Right Quarter"
        case .bottomLeft: "Bottom Left Quarter"
        case .bottomRight: "Bottom Right Quarter"
        case .leftThird: "Left Third"
        case .centerThird: "Center Third"
        case .rightThird: "Right Third"
        case .leftTwoThirds: "Left Two Thirds"
        case .rightTwoThirds: "Right Two Thirds"
        case .maximize: "Maximize"
        case .almostMaximize: "Almost Maximize"
        case .center: "Center"
        case .nextDisplay: "Move to Next Display"
        case .previousDisplay: "Move to Previous Display"
        }
    }
}

enum SystemAction: String, Codable, CaseIterable, Identifiable {
    case missionControl, applicationWindows, showDesktop
    case moveSpaceLeft, moveSpaceRight
    case lockScreen, sleepDisplay
    case volumeUp, volumeDown, mute
    case brightnessUp, brightnessDown
    case playPause, nextTrack, previousTrack
    case middleClick, mouseBack, mouseForward
    case hideFrontApp, quitFrontApp, closeWindow, minimizeWindow, zoomWindow
    case toggleDarkMode

    var id: String { rawValue }
    var title: String {
        switch self {
        case .missionControl: "Mission Control"
        case .applicationWindows: "Application Windows (App Exposé)"
        case .showDesktop: "Show Desktop"
        case .moveSpaceLeft: "Move Left a Space"
        case .moveSpaceRight: "Move Right a Space"
        case .lockScreen: "Lock Screen"
        case .sleepDisplay: "Sleep Display"
        case .volumeUp: "Volume Up"
        case .volumeDown: "Volume Down"
        case .mute: "Mute"
        case .brightnessUp: "Brightness Up"
        case .brightnessDown: "Brightness Down"
        case .playPause: "Play / Pause"
        case .nextTrack: "Next Track"
        case .previousTrack: "Previous Track"
        case .middleClick: "Middle Click"
        case .mouseBack: "Mouse Back (Button 4)"
        case .mouseForward: "Mouse Forward (Button 5)"
        case .hideFrontApp: "Hide Frontmost App"
        case .quitFrontApp: "Quit Frontmost App"
        case .closeWindow: "Close Window"
        case .minimizeWindow: "Minimize Window"
        case .zoomWindow: "Zoom Window"
        case .toggleDarkMode: "Toggle Dark Mode"
        }
    }
    var repeatsWhileHeld: Bool {
        switch self {
        case .volumeUp, .volumeDown, .brightnessUp, .brightnessDown: true
        default: false
        }
    }
}

enum Action: Codable, Hashable {
    case none
    case keyboardShortcut(KeyCombo)
    case launchApp(String)       // bundle id or path
    case openURL(String)
    case runShell(String)
    case runAppleScript(String)
    case typeText(String)        // types a string as if entered on the keyboard
    case window(WindowAction)
    case snapAreaFrame(UUID)     // move the focused window into a snap area's attached window frame
    case windowCycle([WindowTarget])   // each press advances to the next step the window is not already in
    case system(SystemAction)
    case showWindowSwitcher

    var display: String {
        switch self {
        case .none: "No Action"
        case .keyboardShortcut(let k): "Send \(k.display)"
        case .launchApp(let s): "Launch \(AppRef.displayName(for: s))"
        case .openURL(let s): "Open \(s)"
        case .runShell(let s): "Shell: \(s.prefix(40))"
        case .runAppleScript: "AppleScript"
        case .typeText(let t): "Type “\(t.prefix(24))\(t.count > 24 ? "…" : "")”"
        case .window(let w): w.title
        case .snapAreaFrame(let id): "Window frame of “\(ConfigStore.shared.config.snapAreas.first { $0.id == id }?.name ?? "deleted snap area")”"
        case .windowCycle(let steps): "Cycle: " + steps.map { $0.shortTitle }.joined(separator: " → ")
        case .system(let s): s.title
        case .showWindowSwitcher: "Show Window Switcher"
        }
    }
    var symbol: String {
        switch self {
        case .none: "circle.dashed"
        case .keyboardShortcut: "keyboard"
        case .launchApp: "app.badge"
        case .openURL: "link"
        case .runShell: "terminal"
        case .runAppleScript: "applescript"
        case .typeText: "character.cursor.ibeam"
        case .window, .snapAreaFrame: "macwindow"
        case .windowCycle: "arrow.triangle.2.circlepath"
        case .system: "gearshape"
        case .showWindowSwitcher: "rectangle.3.group"
        }
    }
}

/// One step of a window cycle: a tiling action or a snap area's window frame.
enum WindowTarget: Codable, Hashable {
    case tile(WindowAction)
    case area(UUID)

    var shortTitle: String {
        switch self {
        case .tile(let w): w.title
        case .area(let id): "“\(ConfigStore.shared.config.snapAreas.first { $0.id == id }?.name ?? "deleted area")”"
        }
    }
}

// MARK: - Trigger

struct Trigger: Codable, Identifiable, Hashable {
    var id = UUID()
    var enabled = true
    var name = ""
    var kind: TriggerKind
    var action: Action = .none
    var appBundleId: String? = nil   // nil = all apps
}

// MARK: - Key remapping

/// A physical HID device (keyboard) identified by vendor/product id.
struct DeviceRef: Codable, Hashable {
    var vendorId: Int
    var productId: Int
    var name: String
}

struct SimpleModification: Codable, Identifiable, Hashable {
    var id = UUID()
    var enabled = true
    var from: UInt16
    var to: UInt16
    var device: DeviceRef? = nil   // nil = all keyboards
}

struct ComplexRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var enabled = true
    var name = "Mod-Tap key"
    var from: UInt16                    // source key
    var aloneKey: KeyCombo?             // sent when tapped alone
    var heldModifiers: Modifiers = []   // acts as these modifiers while held with other keys
    var aloneTimeoutMs: Int = 300
    var device: DeviceRef? = nil        // nil = all keyboards
    /// When non-empty, a tap runs these actions in order instead of sending `aloneKey`.
    var tapActions: [Action] = []
}

/// Karabiner "to" with several events: one key (optionally with modifiers) runs a sequence of actions.
struct KeyActionRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var enabled = true
    var name = "Key macro"
    var from = KeyCombo(keyCode: 0xFFFF)
    var device: DeviceRef? = nil
    var repeats = false                 // run again while the key is held (auto-repeat)
    var actions: [Action] = [.keyboardShortcut(KeyCombo(keyCode: 0xFFFF))]
}

/// Karabiner "simultaneous": several keys pressed within `thresholdMs` of each other run an action.
struct ChordRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var enabled = true
    var name = "Simultaneous keys"
    var keys: [UInt16] = []
    var thresholdMs: Int = 60
    var action: Action = .keyboardShortcut(KeyCombo(keyCode: 53))
    var device: DeviceRef? = nil        // nil = all keyboards (device-specific rules need Input Monitoring)

    var keysDisplay: String { keys.isEmpty ? "Not set" : keys.map { KeyCodes.name(for: $0) }.joined(separator: " + ") }
}

// MARK: - Settings

struct AppRef: Codable, Hashable, Identifiable {
    var bundleId: String
    var name: String
    var id: String { bundleId }

    static func displayName(for idOrPath: String) -> String {
        if idOrPath.hasPrefix("/") {
            return (idOrPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        }
        return idOrPath.split(separator: ".").last.map(String.init) ?? idOrPath
    }
}

struct SwitcherSettings: Codable {
    var enabled = true
    var shortcut = KeyCombo(keyCode: 48, modifiers: [.option])   // ⌥Tab
    var showMinimized = true
    var showHidden = true
    var showThumbnails = true
    var showTitles = true
    var thumbnailHeight: Double = 150
    var currentAppOnly = false
    /// After the modifier is released the switcher stays open this long; Tab / ⇧Tab keep cycling, then it commits.
    var releaseDelayMs: Int = 300

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        releaseDelayMs = try c.decodeIfPresent(Int.self, forKey: .releaseDelayMs) ?? releaseDelayMs
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        shortcut = try c.decodeIfPresent(KeyCombo.self, forKey: .shortcut) ?? shortcut
        showMinimized = try c.decodeIfPresent(Bool.self, forKey: .showMinimized) ?? showMinimized
        showHidden = try c.decodeIfPresent(Bool.self, forKey: .showHidden) ?? showHidden
        showThumbnails = try c.decodeIfPresent(Bool.self, forKey: .showThumbnails) ?? showThumbnails
        showTitles = try c.decodeIfPresent(Bool.self, forKey: .showTitles) ?? showTitles
        thumbnailHeight = try c.decodeIfPresent(Double.self, forKey: .thumbnailHeight) ?? thumbnailHeight
        currentAppOnly = try c.decodeIfPresent(Bool.self, forKey: .currentAppOnly) ?? currentAppOnly
    }
}

/// What happens when a window is dropped at a screen edge.
/// Stored as a plain string for the built-in cases and as {"snapArea": "<uuid>"} for an area's window frame,
/// so older configs ("maximize", "half", …) keep decoding.
enum EdgeTarget: Codable, Hashable {
    case none, maximize, half, almostMaximize
    case snapArea(UUID)       // use the window frame attached to that snap area (or the area itself)

    static let builtIn: [EdgeTarget] = [.none, .half, .maximize, .almostMaximize]

    var builtInTitle: String {
        switch self {
        case .none: "Nothing"
        case .maximize: "Maximize"
        case .half: "Half of the screen"
        case .almostMaximize: "Almost maximize"
        case .snapArea: "Snap area window frame"
        }
    }

    func title(areas: [SnapArea]) -> String {
        if case .snapArea(let id) = self {
            return areas.first { $0.id == id }.map { "Frame of “\($0.name)”" } ?? "Frame of a deleted snap area"
        }
        return builtInTitle
    }

    init(from decoder: Decoder) throws {
        if let c = try? decoder.singleValueContainer(), let raw = try? c.decode(String.self) {
            switch raw {
            case "maximize": self = .maximize
            case "half": self = .half
            case "almostMaximize": self = .almostMaximize
            default: self = .none
            }
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = .snapArea(try c.decode(UUID.self, forKey: .snapArea))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .snapArea(let id):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .snapArea)
        default:
            var c = encoder.singleValueContainer()
            switch self {
            case .maximize: try c.encode("maximize")
            case .half: try c.encode("half")
            case .almostMaximize: try c.encode("almostMaximize")
            default: try c.encode("none")
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case snapArea }
}

struct SnappingSettings: Codable {
    var enabled = true
    var showPreview = true
    var edgeMargin: Double = 6      // pt from the screen edge that counts as "at the edge"
    var cornerSize: Double = 90     // pt along the edge that counts as a corner
    var topEdge: EdgeTarget = .maximize
    var bottomEdge: EdgeTarget = .none
    var leftEdge: EdgeTarget = .half
    var rightEdge: EdgeTarget = .half
    var corners = true
    var ignoreSharedEdges = false   // when on, edges adjacent to another display never snap
    var requireModifier: Modifiers = []   // snap only while these are held (empty = always)
    // Snap area appearance
    var areaOpacity: Double = 0.22
    var areaShowNames = true
    var areaShowDelayMs: Int = 0
    var areaBorderWidth: Double = 2

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        areaOpacity = try c.decodeIfPresent(Double.self, forKey: .areaOpacity) ?? areaOpacity
        areaShowNames = try c.decodeIfPresent(Bool.self, forKey: .areaShowNames) ?? areaShowNames
        areaShowDelayMs = try c.decodeIfPresent(Int.self, forKey: .areaShowDelayMs) ?? areaShowDelayMs
        areaBorderWidth = try c.decodeIfPresent(Double.self, forKey: .areaBorderWidth) ?? areaBorderWidth
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        showPreview = try c.decodeIfPresent(Bool.self, forKey: .showPreview) ?? showPreview
        edgeMargin = try c.decodeIfPresent(Double.self, forKey: .edgeMargin) ?? edgeMargin
        cornerSize = try c.decodeIfPresent(Double.self, forKey: .cornerSize) ?? cornerSize
        topEdge = try c.decodeIfPresent(EdgeTarget.self, forKey: .topEdge) ?? topEdge
        bottomEdge = try c.decodeIfPresent(EdgeTarget.self, forKey: .bottomEdge) ?? bottomEdge
        leftEdge = try c.decodeIfPresent(EdgeTarget.self, forKey: .leftEdge) ?? leftEdge
        rightEdge = try c.decodeIfPresent(EdgeTarget.self, forKey: .rightEdge) ?? rightEdge
        corners = try c.decodeIfPresent(Bool.self, forKey: .corners) ?? corners
        ignoreSharedEdges = try c.decodeIfPresent(Bool.self, forKey: .ignoreSharedEdges) ?? ignoreSharedEdges
        requireModifier = try c.decodeIfPresent(Modifiers.self, forKey: .requireModifier) ?? requireModifier
    }
}

/// Rectangle normalized to a screen's full frame (0...1, AppKit orientation: origin bottom-left).
struct NRect: Codable, Hashable {
    var x: Double, y: Double, w: Double, h: Double

    init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
    init(rect: CGRect, in screen: CGRect) {
        x = Double((rect.minX - screen.minX) / screen.width)
        y = Double((rect.minY - screen.minY) / screen.height)
        w = Double(rect.width / screen.width)
        h = Double(rect.height / screen.height)
    }
    func rect(in screen: CGRect) -> CGRect {
        CGRect(x: screen.minX + CGFloat(x) * screen.width, y: screen.minY + CGFloat(y) * screen.height,
               width: CGFloat(w) * screen.width, height: CGFloat(h) * screen.height)
    }
}

/// BetterTouchTool-style custom snap area: drop a dragged window inside `trigger` to resize it to `target`.
struct SnapArea: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = "Snap Area"
    var enabled = true
    var displayID: UInt32
    var displayName: String
    var trigger: NRect
    var target: NRect? = nil            // nil = same as trigger
    var requireModifier: Modifiers = []
    var appBundleId: String? = nil
    var colorIndex = 0
    var showWhileDragging = true

    static let colors: [(name: String, r: Double, g: Double, b: Double)] = [
        ("Blue", 0.20, 0.55, 1.00), ("Green", 0.20, 0.75, 0.40), ("Orange", 1.00, 0.60, 0.15),
        ("Pink", 0.95, 0.35, 0.60), ("Purple", 0.60, 0.40, 0.95), ("Teal", 0.20, 0.75, 0.80),
    ]
}

enum AccelerationMode: String, Codable, CaseIterable, Identifiable {
    case system, off, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System default"
        case .off: "Off (linear)"
        case .custom: "Custom"
        }
    }
}

/// Mouse behaviour beyond triggers: scrolling, pointer speed / acceleration, convenience buttons.
/// Everything here applies to mice only; trackpads are never touched.
struct MouseSettings: Codable {
    var reverseVertical = false
    var reverseHorizontal = false
    var scrollSpeed: Double = 1.0            // multiplier for wheel notches
    var smoothScrolling = false
    var shiftScrollsHorizontally = false
    var pointerSpeedEnabled = false
    var pointerSpeed: Double = 1.0           // 1.0 = system (400 dpi resolution), 2.0 = twice as fast
    var acceleration: AccelerationMode = .system
    var accelerationValue: Double = 0.6875   // macOS default
    var backForwardButtons = false           // buttons 4 / 5 → ⌘[ / ⌘]
    /// Bundle identifiers whose windows keep the system's scrolling (no reversal / speed / smoothing).
    /// Judged by the window under the pointer, not the frontmost app.
    var scrollExcludedApps: [String] = MouseSettings.defaultScrollExclusions

    static let defaultScrollExclusions = ["com.apple.ScreenContinuity"]   // iPhone Mirroring (touch-style scrolling)

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scrollExcludedApps = try c.decodeIfPresent([String].self, forKey: .scrollExcludedApps) ?? scrollExcludedApps
        reverseVertical = try c.decodeIfPresent(Bool.self, forKey: .reverseVertical) ?? reverseVertical
        reverseHorizontal = try c.decodeIfPresent(Bool.self, forKey: .reverseHorizontal) ?? reverseHorizontal
        scrollSpeed = try c.decodeIfPresent(Double.self, forKey: .scrollSpeed) ?? scrollSpeed
        smoothScrolling = try c.decodeIfPresent(Bool.self, forKey: .smoothScrolling) ?? smoothScrolling
        shiftScrollsHorizontally = try c.decodeIfPresent(Bool.self, forKey: .shiftScrollsHorizontally) ?? shiftScrollsHorizontally
        pointerSpeedEnabled = try c.decodeIfPresent(Bool.self, forKey: .pointerSpeedEnabled) ?? pointerSpeedEnabled
        pointerSpeed = try c.decodeIfPresent(Double.self, forKey: .pointerSpeed) ?? pointerSpeed
        acceleration = try c.decodeIfPresent(AccelerationMode.self, forKey: .acceleration) ?? acceleration
        accelerationValue = try c.decodeIfPresent(Double.self, forKey: .accelerationValue) ?? accelerationValue
        backForwardButtons = try c.decodeIfPresent(Bool.self, forKey: .backForwardButtons) ?? backForwardButtons
    }

    var scrollActive: Bool { reverseVertical || reverseHorizontal || scrollSpeed != 1 || smoothScrolling || shiftScrollsHorizontally }
}

struct GeneralSettings: Codable {
    var keyboardEnabled = true
    var trackpadEnabled = true
    var mouseEnabled = true
    var showMenuBarIcon = true
    var swipeThreshold: Double = 0.10   // normalized trackpad units
    var tapMaxDurationMs: Int = 250
    var keepHIDMappingsAtLogin = false  // install a LaunchAgent so hidutil mappings survive without ConfigBox
    /// After a swipe gesture fired, swallow trackpad scrolling until the fingers are up (+ this many ms),
    /// so lifting fingers one by one does not scroll the page underneath.
    var suppressScrollAfterGesture = true
    var scrollSuppressTailMs: Int = 300
    // More trackpad gesture tuning
    var gestureCooldownMs: Int = 150        // minimum gap between two fired gestures
    var swipeAxisRatio: Double = 1.5        // dominant axis must exceed the other by this factor (1 = any diagonal counts)
    var maxTouchSize: Double = 0            // ignore touches larger than this (0 = off); palms are typically > 3
    var trackpadReverseScroll = false       // reverse trackpad scrolling independently of the mouse
    var trackpadScrollSpeed: Double = 1.0   // multiplier for trackpad scrolling

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyboardEnabled = try c.decodeIfPresent(Bool.self, forKey: .keyboardEnabled) ?? keyboardEnabled
        trackpadEnabled = try c.decodeIfPresent(Bool.self, forKey: .trackpadEnabled) ?? trackpadEnabled
        mouseEnabled = try c.decodeIfPresent(Bool.self, forKey: .mouseEnabled) ?? mouseEnabled
        showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? showMenuBarIcon
        swipeThreshold = try c.decodeIfPresent(Double.self, forKey: .swipeThreshold) ?? swipeThreshold
        tapMaxDurationMs = try c.decodeIfPresent(Int.self, forKey: .tapMaxDurationMs) ?? tapMaxDurationMs
        keepHIDMappingsAtLogin = try c.decodeIfPresent(Bool.self, forKey: .keepHIDMappingsAtLogin) ?? keepHIDMappingsAtLogin
        suppressScrollAfterGesture = try c.decodeIfPresent(Bool.self, forKey: .suppressScrollAfterGesture) ?? suppressScrollAfterGesture
        scrollSuppressTailMs = try c.decodeIfPresent(Int.self, forKey: .scrollSuppressTailMs) ?? scrollSuppressTailMs
        gestureCooldownMs = try c.decodeIfPresent(Int.self, forKey: .gestureCooldownMs) ?? gestureCooldownMs
        swipeAxisRatio = try c.decodeIfPresent(Double.self, forKey: .swipeAxisRatio) ?? swipeAxisRatio
        maxTouchSize = try c.decodeIfPresent(Double.self, forKey: .maxTouchSize) ?? maxTouchSize
        trackpadReverseScroll = try c.decodeIfPresent(Bool.self, forKey: .trackpadReverseScroll) ?? trackpadReverseScroll
        trackpadScrollSpeed = try c.decodeIfPresent(Double.self, forKey: .trackpadScrollSpeed) ?? trackpadScrollSpeed
    }
}

struct Config: Codable {
    var general = GeneralSettings()
    var switcher = SwitcherSettings()
    var snapping = SnappingSettings()
    var snapAreas: [SnapArea] = []
    var mouse = MouseSettings()
    var triggers: [Trigger] = []
    var simpleModifications: [SimpleModification] = []
    var complexRules: [ComplexRule] = []
    var chordRules: [ChordRule] = []
    var keyActionRules: [KeyActionRule] = []
    var apps: [AppRef] = []

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        general = try c.decodeIfPresent(GeneralSettings.self, forKey: .general) ?? general
        switcher = try c.decodeIfPresent(SwitcherSettings.self, forKey: .switcher) ?? switcher
        snapping = try c.decodeIfPresent(SnappingSettings.self, forKey: .snapping) ?? snapping
        snapAreas = try c.decodeIfPresent([SnapArea].self, forKey: .snapAreas) ?? []
        mouse = try c.decodeIfPresent(MouseSettings.self, forKey: .mouse) ?? mouse
        triggers = try c.decodeIfPresent([Trigger].self, forKey: .triggers) ?? []
        simpleModifications = try c.decodeIfPresent([SimpleModification].self, forKey: .simpleModifications) ?? []
        complexRules = try c.decodeIfPresent([ComplexRule].self, forKey: .complexRules) ?? []
        chordRules = try c.decodeIfPresent([ChordRule].self, forKey: .chordRules) ?? []
        keyActionRules = try c.decodeIfPresent([KeyActionRule].self, forKey: .keyActionRules) ?? []
        apps = try c.decodeIfPresent([AppRef].self, forKey: .apps) ?? []
    }

    static var sample: Config {
        var c = Config()
        c.triggers = [
            Trigger(name: "Middle click", kind: .gesture(Gesture(fingers: 3, kind: .tap)), action: .system(.middleClick)),
            Trigger(name: "Mission Control", kind: .gesture(Gesture(fingers: 4, kind: .tap)), action: .system(.missionControl)),
            Trigger(name: "Left half", kind: .shortcut(KeyCombo(keyCode: 123, modifiers: [.control, .option])), action: .window(.leftHalf)),
            Trigger(name: "Right half", kind: .shortcut(KeyCombo(keyCode: 124, modifiers: [.control, .option])), action: .window(.rightHalf)),
            Trigger(name: "Maximize", kind: .shortcut(KeyCombo(keyCode: 36, modifiers: [.control, .option])), action: .window(.maximize)),
            Trigger(name: "Center", kind: .shortcut(KeyCombo(keyCode: 8, modifiers: [.control, .option])), action: .window(.center)),
            Trigger(name: "Next display", kind: .shortcut(KeyCombo(keyCode: 124, modifiers: [.control, .option, .command])), action: .window(.nextDisplay)),
        ]
        c.complexRules = [
            ComplexRule(enabled: false, name: "Caps Lock → Esc (tap) / Control (hold)",
                        from: KeyCodes.capsLock, aloneKey: KeyCombo(keyCode: 53), heldModifiers: [.control]),
        ]
        return c
    }
}

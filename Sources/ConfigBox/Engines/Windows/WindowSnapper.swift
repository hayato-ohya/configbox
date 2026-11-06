import AppKit

/// BetterTouchTool-style window snapping: drag a window to a screen edge or corner, a preview
/// shows the target area, release to resize. Driven by mouse events from the shared event tap.
final class WindowSnapper {
    static let shared = WindowSnapper()

    var settings = SnappingSettings()
    var areas: [SnapArea] = []
    /// Kept for the editor; snapping itself only ignores drags of ConfigBox's own windows.
    var editing = false
    private var overlayWork: DispatchWorkItem?
    private var shownAreaIDs: Set<UUID> = []
    /// Modifier state taken from the most recent mouse event (more reliable than the session
    /// flag state when virtual keyboards such as Karabiner are involved).
    private var currentFlags: Modifiers = []
    private var lastDragFlags: Modifiers = []

    private var stateName: String {
        switch state {
        case .idle: "idle"
        case .pending: "pending"
        case .dragging: "dragging"
        case .notAWindow: "notAWindow"
        }
    }

    /// Focused window of the frontmost app, unless that app is ConfigBox itself.
    private func candidateWindow() -> (AXUIElement, CGRect)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.3)
        guard let w: AXUIElement = AX.attr(appEl, kAXFocusedWindowAttribute), let f = AX.frame(of: w) else { return nil }
        return (w, f)
    }

    private func logMiss(_ cg: CGPoint) {
        let p = CGPoint(x: cg.x, y: AX.primaryHeight - cg.y)
        let screen = NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(p) }
        var parts: [String] = []
        for a in areas where a.enabled {
            let s = NSScreen.screen(withDisplayID: a.displayID)
            let r = s.map { a.triggerRect(on: $0) }
            let why: String
            if s == nil { why = "display not connected" }
            else if s != screen { why = "other display" }
            else if !a.requireModifier.isEmpty && !currentFlags.contains(a.requireModifier) { why = "needs \(a.requireModifier.symbols), held: \(currentFlags.symbols.isEmpty ? "none" : currentFlags.symbols)" }
            else if let app = a.appBundleId, app != draggedApp { why = "app mismatch" }
            else if let r, !r.contains(p) { why = "pointer outside" }
            else { why = "?" }
            parts.append("'\(a.name)' rect=\(r.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "-") → \(why)")
        }
        Log.debug("snapper: released at \(Int(p.x)),\(Int(p.y)) on \(screen?.localizedName ?? "no screen"); " + parts.joined(separator: "; "))
    }

    enum Zone: Equatable {
        case edge(WindowAction)
        case area(UUID)            // dropped inside a snap area
        case areaFrame(UUID)       // screen edge configured to use a snap area's window frame
    }

    private enum State {
        case idle
        case pending(window: AXUIElement, origin: CGPoint, at: CGPoint, since: CFAbsoluteTime)
        case dragging(window: AXUIElement)
        case notAWindow
    }

    private var state: State = .idle
    private var dragStart: CGPoint?
    private var currentZone: Zone?
    private var target: CGRect?      // AppKit coordinates
    private var preview: SnapPreviewPanel?
    private var overlays: [SnapAreaOverlayPanel] = []
    private var draggedApp: String?

    private init() {}

    func handle(_ type: CGEventType, _ event: CGEvent) {
        guard settings.enabled || !areas.isEmpty else { return }
        switch type {
        case .leftMouseDown:
            dragStart = event.location
            state = .idle
            currentZone = nil
            target = nil

        case .leftMouseDragged:
            guard let start = dragStart else { return }
            let loc = event.location
            if !settings.requireModifier.isEmpty,
               !Modifiers(cgFlags: event.flags).contains(settings.requireModifier) {
                if currentZone != nil { leaveZone() }
                return
            }
            switch state {
            case .idle:
                guard hypot(loc.x - start.x, loc.y - start.y) > 6 else { return }
                guard let (w, f) = candidateWindow() else { return }   // app may still be activating: try again on the next event
                state = .pending(window: w, origin: f.origin, at: loc, since: CFAbsoluteTimeGetCurrent())
            case .pending(let w, let origin, let at, let since):
                guard hypot(loc.x - at.x, loc.y - at.y) > 3 else { return }
                // The clicked app may have become frontmost only now: follow the current focused window.
                var window = w, base = origin
                if let (cw, cf) = candidateWindow(), !CFEqual(cw, w) { window = cw; base = cf.origin; }
                guard let f = AX.frame(of: window) else { state = .notAWindow; return }
                if abs(f.origin.x - base.x) > 1 || abs(f.origin.y - base.y) > 1 {
                    state = .dragging(window: window)
                    draggedApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    currentFlags = Modifiers(cgFlags: event.flags)
                    showOverlays()
                    update(location: loc)
                } else if CFAbsoluteTimeGetCurrent() - since > 0.6 {
                    state = .notAWindow           // mouse moved but no window did: text selection, scrollbar, …
                    Log.debug("snapper: not a window drag (focused window did not move)")
                } else {
                    state = .pending(window: window, origin: base, at: loc, since: since)
                }
            case .dragging:
                // Modifier-gated areas appear or disappear as soon as the set of visible areas changes.
                currentFlags = Modifiers(cgFlags: event.flags)
                lastDragFlags = currentFlags
                if !areas.isEmpty && visibleAreaIDs() != shownAreaIDs { showOverlays() }
                update(location: loc)
            case .notAWindow:
                break
            }

        case .leftMouseUp:
            if case .dragging = state {
                currentFlags = Modifiers(cgFlags: event.flags).union(currentFlags.intersection(lastDragFlags))
                update(location: event.location)      // evaluate the actual release point
                if currentZone == nil { logMiss(event.location) }
            }
            Log.debug("snapper: mouseUp state=\(stateName) zone=\(String(describing: currentZone))")
            if case .dragging(let w) = state, let zone = currentZone, let t = target {
                // Let the app finish its own drag handling first.
                let ax = AX.toAX(t.integral)
                // macOS's own edge tiling (and some apps) may re-tile the window right after the drop.
                // Apply, then re-check a few times and put the window back where the user asked.
                var attempt = 0
                func enforce() {
                    let current = AX.frame(of: w)
                    let off = current.map { abs($0.minX - ax.minX) > 2 || abs($0.minY - ax.minY) > 2 || abs($0.width - ax.width) > 2 || abs($0.height - ax.height) > 2 } ?? true
                    if attempt == 0 || off { AX.setFrame(w, ax) }
                    if attempt > 0 && off { Log.debug("snapper: frame was changed externally (\(current.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "?")); re-applied") }
                    attempt += 1
                    if attempt <= 3 { DispatchQueue.main.asyncAfter(deadline: .now() + [0.25, 0.4, 0.6][attempt - 1], execute: enforce) }
                    else { Log.debug("Snapped window to \(zone): \(Int(ax.minX)),\(Int(ax.minY)) \(Int(ax.width))x\(Int(ax.height))") }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: enforce)
            }
            leaveZone()
            hideOverlays()
            state = .idle
            dragStart = nil

        default:
            break
        }
    }

    // MARK: Zones

    private func update(location cg: CGPoint) {
        let p = CGPoint(x: cg.x, y: AX.primaryHeight - cg.y)   // AppKit coordinates
        guard let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(p) }) else { leaveZone(); return }
        let f = screen.frame
        let m = CGFloat(settings.edgeMargin)
        let c = CGFloat(settings.cornerSize)

        func edgeFree(_ probe: CGPoint) -> Bool {
            guard settings.ignoreSharedEdges else { return true }
            return !NSScreen.screens.contains { $0 != screen && $0.frame.contains(probe) }
        }
        let left = p.x <= f.minX + m && edgeFree(CGPoint(x: f.minX - 2, y: p.y))
        let right = p.x >= f.maxX - m && edgeFree(CGPoint(x: f.maxX + 2, y: p.y))
        let top = p.y >= f.maxY - m && edgeFree(CGPoint(x: p.x, y: f.maxY + 2))
        let bottom = p.y <= f.minY + m && edgeFree(CGPoint(x: p.x, y: f.minY - 2))
        let nearTop = p.y >= f.maxY - c, nearBottom = p.y <= f.minY + c
        let nearLeft = p.x <= f.minX + c, nearRight = p.x >= f.maxX - c

        // Custom snap areas take priority over screen edges.
        if let area = applicableAreas(on: screen).first(where: { $0.triggerRect(on: screen).contains(p) }) {
            let zone = Zone.area(area.id)
            if zone == currentZone { return }
            currentZone = zone
            target = area.targetRect(on: screen)
            overlays.forEach { $0.highlight(area.id) }
            if settings.showPreview {
                if preview == nil { preview = SnapPreviewPanel() }
                preview?.show(target!)
            }
            return
        }
        overlays.forEach { $0.highlight(nil) }
        guard settings.enabled else { leaveZone(); return }

        var zone: Zone?
        if left {
            zone = settings.corners && nearTop ? .edge(.topLeft) : settings.corners && nearBottom ? .edge(.bottomLeft) : edgeZone(settings.leftEdge, half: .leftHalf)
        } else if right {
            zone = settings.corners && nearTop ? .edge(.topRight) : settings.corners && nearBottom ? .edge(.bottomRight) : edgeZone(settings.rightEdge, half: .rightHalf)
        } else if top {
            if settings.corners && nearLeft { zone = .edge(.topLeft) }
            else if settings.corners && nearRight { zone = .edge(.topRight) }
            else { zone = edgeZone(settings.topEdge, half: .topHalf) }
        } else if bottom {
            if settings.corners && nearLeft { zone = .edge(.bottomLeft) }
            else if settings.corners && nearRight { zone = .edge(.bottomRight) }
            else { zone = edgeZone(settings.bottomEdge, half: .bottomHalf) }
        }

        guard let zone else { leaveZone(); return }
        if zone == currentZone { return }
        currentZone = zone
        let rect: CGRect
        switch zone {
        case .edge(let action):
            rect = WindowManager.rect(for: action, in: screen.visibleFrame, current: nil)
        case .areaFrame(let id):
            guard let area = areas.first(where: { $0.id == id }) else { leaveZone(); return }
            let areaScreen = NSScreen.screen(withDisplayID: area.displayID) ?? screen
            rect = area.targetRect(on: areaScreen)
        case .area:
            return
        }
        target = rect
        if settings.showPreview {
            if preview == nil { preview = SnapPreviewPanel() }
            preview?.show(rect)
        }
    }

    private func edgeZone(_ t: EdgeTarget, half: WindowAction) -> Zone? {
        switch t {
        case .none: nil
        case .maximize: .edge(.maximize)
        case .half: .edge(half)
        case .almostMaximize: .edge(.almostMaximize)
        case .snapArea(let id): areas.contains { $0.id == id } ? .areaFrame(id) : nil
        }
    }

    private func leaveZone() {
        currentZone = nil
        target = nil
        preview?.hide()
        preview = nil
        overlays.forEach { $0.highlight(nil) }
    }

    // MARK: Custom areas

    private func visibleAreaIDs() -> Set<UUID> {
        Set(NSScreen.screens.flatMap { applicableAreas(on: $0).filter(\.showWhileDragging).map(\.id) })
    }

    private func applicableAreas(on screen: NSScreen) -> [SnapArea] {
        let flags = currentFlags
        return areas.filter { a in
            a.enabled && a.displayID == screen.displayID
                && (a.requireModifier.isEmpty || flags.contains(a.requireModifier))
                && (a.appBundleId == nil || a.appBundleId == draggedApp)
        }
    }

    private func showOverlays() {
        hideOverlays()
        shownAreaIDs = visibleAreaIDs()
        Log.debug("snapper: showOverlays flags=\(currentFlags.symbols) visible=\(shownAreaIDs.count)/\(areas.count)")
        guard !shownAreaIDs.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            for screen in NSScreen.screens {
                let visible = self.applicableAreas(on: screen).filter(\.showWhileDragging)
                guard !visible.isEmpty else { continue }
                let p = SnapAreaOverlayPanel(screen: screen, areas: visible, settings: self.settings)
                p.orderFrontRegardless()
                self.overlays.append(p)
            }
            if case .area(let id) = self.currentZone { self.overlays.forEach { $0.highlight(id) } }
        }
        overlayWork = work
        if settings.areaShowDelayMs > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(settings.areaShowDelayMs), execute: work)
        } else {
            work.perform()
        }
    }

    private func hideOverlays() {
        if !overlays.isEmpty { Log.debug("snapper: hideOverlays") }
        shownAreaIDs = []
        overlayWork?.cancel()
        overlayWork = nil
        overlays.forEach { $0.orderOut(nil); $0.contentView = nil }
        overlays = []
    }
}

/// Translucent accent-colored rectangle shown over the snap target.
final class SnapPreviewPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isReleasedWhenClosed = false
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        v.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        v.layer?.borderWidth = 2
        v.layer?.cornerRadius = 10
        v.layer?.cornerCurve = .continuous
        contentView = v
    }

    override var canBecomeKey: Bool { false }

    func show(_ rect: CGRect) {
        let r = rect.insetBy(dx: 4, dy: 4)
        if isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                animator().setFrame(r, display: true)
            }
        } else {
            setFrame(r, display: true)
            alphaValue = 0
            orderFrontRegardless()
            animator().alphaValue = 1
        }
    }

    func hide() {
        orderOut(nil)
    }
}

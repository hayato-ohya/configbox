import AppKit

extension NSScreen {
    var displayID: UInt32 {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    static func screen(withDisplayID id: UInt32) -> NSScreen? { screens.first { $0.displayID == id } }
    var displayIdentity: DisplayIdentity {
        let id = displayID
        return DisplayIdentity(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id))
    }
    static var underMouse: NSScreen {
        let m = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(m) } ?? main ?? screens[0]
    }
}

extension SnapArea {
    mutating func link(to screen: NSScreen) {
        displayID = screen.displayID
        displayName = screen.localizedName
        display = screen.displayIdentity
    }

    /// Display IDs are assigned per Mac (and can change with the port), so a restored or older config may point at
    /// a display that is not connected, or at a different one that happens to have the same ID. Re-links each area
    /// to the connected display with the same vendor / model / serial, or else the same name when that is unique.
    /// Returns true if anything changed.
    static func relink(_ areas: inout [SnapArea], screens: [NSScreen] = NSScreen.screens) -> Bool {
        var changed = false
        for i in areas.indices {
            var a = areas[i]
            if let s = screens.first(where: { $0.displayID == a.displayID }),
               a.display.map({ $0 == s.displayIdentity }) ?? (s.localizedName == a.displayName) {
                if a.display == nil { a.display = s.displayIdentity }        // same display: just remember its identity
            } else if let want = a.display, let s = screens.first(where: { $0.displayIdentity == want }) {
                a.link(to: s)
            } else if case let named = screens.filter({ $0.localizedName == a.displayName }), named.count == 1 {
                a.link(to: named[0])
            }
            if a != areas[i] {
                Log.info("snap area “\(a.name)”: display \(areas[i].displayID) → \(a.displayID) (\(a.displayName))")
                areas[i] = a
                changed = true
            }
        }
        return changed
    }

    var nsColor: NSColor {
        let c = SnapArea.colors[min(max(colorIndex, 0), SnapArea.colors.count - 1)]
        return NSColor(calibratedRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }
    func triggerRect(on screen: NSScreen) -> CGRect { trigger.rect(in: screen.frame) }
    func targetRect(on screen: NSScreen) -> CGRect { (target ?? trigger).rect(in: screen.frame) }
}

/// Full-screen transparent panel that draws the snap areas of one display while a window is dragged.
final class SnapAreaOverlayPanel: NSPanel {
    private let view: AreaView

    init(screen: NSScreen, areas: [SnapArea], settings: SnappingSettings) {
        view = AreaView(screen: screen, areas: areas, settings: settings)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isReleasedWhenClosed = false
        contentView = view
        setFrame(screen.frame, display: false)
    }
    override var canBecomeKey: Bool { false }

    func highlight(_ id: UUID?) {
        guard view.highlighted != id else { return }
        view.highlighted = id
        view.needsDisplay = true
    }

    private final class AreaView: NSView {
        let screen: NSScreen
        let areas: [SnapArea]
        let settings: SnappingSettings
        var highlighted: UUID?
        init(screen: NSScreen, areas: [SnapArea], settings: SnappingSettings) {
            self.screen = screen; self.areas = areas; self.settings = settings; super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ dirtyRect: NSRect) {
            let alpha = CGFloat(settings.areaOpacity)
            for a in areas {
                let r = a.trigger.rect(in: CGRect(origin: .zero, size: screen.frame.size)).insetBy(dx: 2, dy: 2)
                let hl = a.id == highlighted
                let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
                a.nsColor.withAlphaComponent(hl ? min(alpha + 0.25, 0.9) : alpha).setFill()
                path.fill()
                a.nsColor.withAlphaComponent(hl ? 1 : 0.75).setStroke()
                path.lineWidth = CGFloat(settings.areaBorderWidth) * (hl ? 1.5 : 1)
                path.stroke()

                guard settings.areaShowNames else { continue }
                let text = NSAttributedString(string: a.name, attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white])
                let size = text.size()
                let pad: CGFloat = 8
                let box = CGRect(x: r.midX - size.width / 2 - pad, y: r.midY - size.height / 2 - 4,
                                 width: size.width + pad * 2, height: size.height + 8)
                NSColor.black.withAlphaComponent(0.55).setFill()
                NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
                text.draw(at: CGPoint(x: box.minX + pad, y: box.minY + 4))
            }
        }
    }
}

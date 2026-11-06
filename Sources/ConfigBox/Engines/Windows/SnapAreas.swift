import AppKit

extension NSScreen {
    var displayID: UInt32 {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    static func screen(withDisplayID id: UInt32) -> NSScreen? { screens.first { $0.displayID == id } }
    static var underMouse: NSScreen {
        let m = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(m) } ?? main ?? screens[0]
    }
}

extension SnapArea {
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

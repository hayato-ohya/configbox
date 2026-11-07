import AppKit
import SwiftUI
import Combine

/// BTT-style "attach window": the user arranges any window the way it should look after being
/// dropped on a snap area, then presses Attach. The HUD never takes focus, so the frontmost window
/// stays the one the user is arranging.
final class WindowAttachSession: NSObject, ObservableObject {
    static let shared = WindowAttachSession()

    @Published private(set) var areaID: UUID?
    @Published private(set) var frontTitle = ""
    @Published private(set) var frontApp = ""
    @Published private(set) var frontFrame: CGRect?
    @Published private(set) var frontIsSelf = false
    private var panel: NSPanel?
    private var timer: Timer?
    private let store = ConfigStore.shared

    var isActive: Bool { areaID != nil }
    var areaName: String { store.config.snapAreas.first { $0.id == areaID }?.name ?? "" }

    func begin(areaID: UUID) {
        cancel()
        self.areaID = areaID
        let screen = NSScreen.underMouse
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 150),
                        styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .hudWindow, .utilityWindow],
                        backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating + 2
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.contentView = NSHostingView(rootView: AttachHUDView().environmentObject(store))
        let f = screen.visibleFrame
        p.setFrameOrigin(NSPoint(x: f.midX - 260, y: f.maxY - 190))
        p.orderFrontRegardless()
        panel = p
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    private func poll() {
        let app = NSWorkspace.shared.frontmostApplication
        frontIsSelf = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        frontApp = app?.localizedName ?? ""
        if frontIsSelf {
            frontTitle = ""; frontFrame = nil; return
        }
        if let w = AX.focusedWindow(), let ax = AX.frame(of: w) {
            frontTitle = AX.attr(w, kAXTitleAttribute) ?? ""
            frontFrame = AX.fromAX(ax)
        } else {
            frontTitle = ""; frontFrame = nil
        }
    }

    /// Stores the frontmost window's frame as the area's attached window frame.
    func attach() {
        guard let id = areaID, let idx = store.config.snapAreas.firstIndex(where: { $0.id == id }) else { cancel(); return }
        poll()
        guard !frontIsSelf, let frame = frontFrame else { return }
        var a = store.config.snapAreas[idx]
        let screen = NSScreen.screen(withDisplayID: a.displayID) ?? NSScreen.underMouse
        a.target = NRect(rect: frame, in: screen.frame)
        store.config.snapAreas[idx] = a
        Log.info("snap area '\(a.name)': attached window frame \(frame.integral) from \(frontApp)")
        cancel()
        NSApp.activate(ignoringOtherApps: true)
    }

    func cancel() {
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil); panel?.contentView = nil; panel = nil
        areaID = nil
    }
}

struct AttachHUDView: View {
    @ObservedObject private var session = WindowAttachSession.shared
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "macwindow.badge.plus").font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Attach a window to “\(session.areaName)”").font(.headline)
                    Text("Move and resize any window to the position and size it should have after being dropped on this area, then click Attach.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                if session.frontIsSelf {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text("ConfigBox is frontmost. Click the window you want to attach.").font(.callout)
                } else if let f = session.frontFrame {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("\(session.frontApp): \(session.frontTitle.isEmpty ? L("window") : session.frontTitle)")
                        .font(.callout).lineLimit(1)
                    Spacer()
                    Text("\(Int(f.width)) × \(Int(f.height))").font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                    Text("No focused window found in \(session.frontApp).").font(.callout)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08)))
            HStack {
                Spacer()
                Button("Cancel") { session.cancel() }
                Button("Attach") { session.attach() }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.frontIsSelf || session.frontFrame == nil)
            }
        }
        .padding(14)
        .frame(width: 520)
    }
}

import AppKit
// Renders Resources/AppIcon.svg -> build/AppIcon.iconset -> Resources/AppIcon.icns, and the menu bar template PNGs.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let res = root.appendingPathComponent("Resources")
func png(_ img: NSImage, size: Int, to url: URL) {
    let out = NSImage(size: NSSize(width: size, height: size))
    out.lockFocus(); NSGraphicsContext.current?.imageInterpolation = .high
    img.draw(in: NSRect(x: 0, y: 0, width: size, height: size)); out.unlockFocus()
    guard let t = out.tiffRepresentation, let r = NSBitmapImageRep(data: t) else { return }
    r.size = NSSize(width: size, height: size)
    try! r.representation(using: .png, properties: [:])!.write(to: url)
}
let app = NSImage(contentsOf: res.appendingPathComponent("AppIcon.svg"))!
let set = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for s in [16, 32, 128, 256, 512] {
    png(app, size: s, to: set.appendingPathComponent("icon_\(s)x\(s).png"))
    png(app, size: s * 2, to: set.appendingPathComponent("icon_\(s)x\(s)@2x.png"))
}
let menu = NSImage(contentsOf: res.appendingPathComponent("MenuBarIcon.svg"))!
png(menu, size: 20, to: res.appendingPathComponent("MenuBarIcon.png"))
png(menu, size: 40, to: res.appendingPathComponent("MenuBarIcon@2x.png"))
print("iconset + menubar pngs written")

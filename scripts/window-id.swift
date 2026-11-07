// Prints the window number of ConfigBox's largest on-screen window, for `screencapture -l`.
import CoreGraphics

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
var best: (id: Int, area: Double) = (0, 0)
for w in windows where (w["kCGWindowOwnerName"] as? String) == "ConfigBox" && (w["kCGWindowLayer"] as? Int) == 0 {
    let bounds = w["kCGWindowBounds"] as! [String: Double]
    let area = bounds["Width"]! * bounds["Height"]!
    if area > best.area { best = (w["kCGWindowNumber"] as! Int, area) }
}
print(best.id)

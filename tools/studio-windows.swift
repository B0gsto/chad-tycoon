// Lists Roblox Studio's top-level (layer 0) windows as JSON for tools/studio_window.py.
// Window names are usually empty (macOS hides them without Screen Recording), so callers match by bounds.
import CoreGraphics
import Foundation

let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
var out: [[String: Any]] = []
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let layer = w[kCGWindowLayer as String] as? Int ?? -1
    guard owner == "Roblox Studio", layer == 0, let b = w[kCGWindowBounds as String] as? [String: Double] else { continue }
    out.append([
        "id": w[kCGWindowNumber as String] as? Int ?? 0,
        "x": b["X"] ?? 0, "y": b["Y"] ?? 0, "w": b["Width"] ?? 0, "h": b["Height"] ?? 0,
        "name": w[kCGWindowName as String] as? String ?? "",
        "onscreen": w[kCGWindowIsOnscreen as String] as? Bool ?? false,
    ])
}
let data = try JSONSerialization.data(withJSONObject: out)
print(String(data: data, encoding: .utf8)!)

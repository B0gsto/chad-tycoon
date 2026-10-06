import ApplicationServices
import AppKit
// Print every AX window of every RobloxStudio process, one per line: title \t x \t y \t w \t h \t pid.
// usage: studio-axwindows
// Processes are taken from NSWorkspace by pid, so several same-named "RobloxStudio" processes (one per open place)
// are each read exactly once; a process that quits mid-walk just yields no rows (the System Events walk raised
// -1728 "Can't get window N of item K of every process ..." in that case). Read-only: no focus change, no input.
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
var out = ""
for app in NSWorkspace.shared.runningApplications where app.executableURL?.lastPathComponent == "RobloxStudio" {
    let pid = app.processIdentifier
    let ax = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(ax, 2.0)
    for w in (attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
        var p = CGPoint.zero, s = CGSize.zero
        if let v = attr(w, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
        if let v = attr(w, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
        let t = (attr(w, kAXTitleAttribute) as? String ?? "").replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        out += "\(t)\t\(Int(p.x))\t\(Int(p.y))\t\(Int(s.width))\t\(Int(s.height))\t\(pid)\n"
    }
}
print(out, terminator: "")

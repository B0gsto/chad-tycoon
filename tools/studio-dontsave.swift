import ApplicationServices
import AppKit
// Answer the "Save changes to TestBench-*.rbxl?" prompt of ONE bench Studio process with Don't Save.
// usage: studio-dontsave <pid>
// The prompt is an untitled ~350x134 window whose buttons are not exposed to AX, so: activate that process, wait
// until it really is frontmost, AXRaise the prompt, verify the prompt is the topmost window at the click point,
// CGEvent-click Don't Save (right-anchored: x + w - 117.5, y + h - 24). The mouse position and the previously
// frontmost app are restored in a defer, whatever happens.
let args = CommandLine.arguments
guard args.count > 1, let pid = Int32(args[1]) else { print("usage: studio-dontsave <pid>"); exit(2) }
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
func title(_ e: AXUIElement) -> String { attr(e, kAXTitleAttribute) as? String ?? "" }
guard let app = NSRunningApplication(processIdentifier: pid), (app.localizedName ?? "").contains("Roblox") else {
    print("pid \(pid) is not a Roblox Studio process"); exit(2)
}
let ax = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(ax, 2.0)
let wins = (attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []
let places = wins.map(title).filter { $0.hasSuffix(" - Roblox Studio") }
// Bench only: the process must show a TestBench place title and no other place. Zero titles (e.g. an AX
// timeout) means refuse.
guard places.contains(where: { $0.contains("TestBench") }), !places.contains(where: { !$0.contains("TestBench") }) else {
    print("pid \(pid) is not a bench process: \(places)"); exit(3)
}

func frame(_ w: AXUIElement) -> CGRect {
    var p = CGPoint.zero, s = CGSize.zero
    if let v = attr(w, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    if let v = attr(w, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
    return CGRect(origin: p, size: s)
}
// The topmost on-screen window (front to back order) containing pt: (owner pid, bounds).
func topWindow(at pt: CGPoint) -> (Int32, CGRect)? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list {
        // Normal (0), floating (3) and modal-panel (8) layers: the prompt sits on layer 8 when its place window is the
        // process's only document (start-page-launched process); higher layers are menus / status items.
        guard (w[kCGWindowLayer as String] as? Int ?? 99) < 20, let b = w[kCGWindowBounds as String] as? [String: Double] else { continue }
        let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        if r.contains(pt) { return (w[kCGWindowOwnerPID as String] as? Int32 ?? 0, r) }
    }
    return nil
}

guard let prompt = wins.first(where: { title($0).isEmpty && abs(frame($0).width - 350) < 40 && abs(frame($0).height - 134) < 30 }) else {
    print("no save prompt on pid \(pid)"); exit(1)
}
// Fresh frontmost pid: the AX system-wide focused application (NSWorkspace.frontmostApplication goes stale in a CLI
// that never spins the main run loop).
let systemWide = AXUIElementCreateSystemWide()
func frontPid() -> pid_t {
    RunLoop.current.run(until: Date())
    guard let v = attr(systemWide, kAXFocusedApplicationAttribute) else { return NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1 }
    var p: pid_t = -1
    AXUIElementGetPid(v as! AXUIElement, &p)
    return p
}
let prevApp = NSWorkspace.shared.frontmostApplication
let prevMouse = CGEvent(source: nil)?.location ?? .zero
func restoreUser() {
    CGWarpMouseCursorPosition(prevMouse)
    if let p = prevApp, p.processIdentifier != pid { p.activate() }
}
// Own deadline (10 s, well under the Python timeout): if anything hangs, restore the mouse and focus, then quit.
DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
    print("deadline hit; restoring the mouse and focus")
    restoreUser()
    exit(4)
}
var clicked = false
do {
    defer { restoreUser() }
    app.activate()
    AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    var front = false
    for _ in 0..<30 {  // up to 3 s
        if frontPid() == pid { front = true; break }
        usleep(100_000)
    }
    if front {
        AXUIElementPerformAction(prompt, kAXRaiseAction as CFString)
        let f = frame(prompt)
        let pt = CGPoint(x: f.maxX - 117.5, y: f.maxY - 24)
        var topOK = false
        for _ in 0..<20 {  // up to 2 s for the raise to land
            if let (owner, r) = topWindow(at: pt), owner == pid, abs(r.width - f.width) < 2, abs(r.height - f.height) < 2 { topOK = true; break }
            usleep(100_000)
        }
        if topOK && frontPid() == pid {
            for t in [CGEventType.leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
                usleep(80_000)
            }
            clicked = true
            print("pid \(pid): clicked Don't Save at \(pt)")
            usleep(300_000)
        } else {
            print("prompt is not topmost at the click point; not clicking")
        }
    } else {
        print("pid \(pid) did not become frontmost; not clicking")
    }
}
exit(clicked ? 0 : 1)

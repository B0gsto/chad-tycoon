import ApplicationServices
import AppKit
// Press a button (by title) inside a dialog window (by title) of ONE Studio process, without changing focus.
// usage: studio-axpress <pid> "<window title>" "<button title>"
// The pid must be a bench process (tools/studio_window.py bench_pids); the caller enforces the TestBench rule and
// this helper re-checks that the process hosts a TestBench place and no other place.
let args = CommandLine.arguments
guard args.count > 3, let pid = Int32(args[1]) else { print("usage: studio-axpress <pid> <window> <button>"); exit(2) }
let winTitle = args[2], btnTitle = args[3]
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
func title(_ e: AXUIElement) -> String { attr(e, kAXTitleAttribute) as? String ?? "" }
func find(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
    if (attr(e, kAXRoleAttribute) as? String) == "AXButton" && title(e) == btnTitle { return e }
    if d > 12 { return nil }
    for k in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { if let f = find(k, d + 1) { return f } }
    return nil
}
guard let app = NSRunningApplication(processIdentifier: pid), (app.localizedName ?? "").contains("Roblox") else {
    print("pid \(pid) is not a Roblox Studio process"); exit(2)
}
let ax = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(ax, 2.0)
let wins = (attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []
let titles = wins.map(title)
let places = titles.filter { $0.hasSuffix(" - Roblox Studio") }
guard places.contains(where: { $0.contains("TestBench") }), !places.contains(where: { !$0.contains("TestBench") }) else {
    print("pid \(pid) is not a bench process: \(places)"); exit(3)
}
var pressed = 0
for w in wins where title(w) == winTitle {
    if let b = find(w, 0) {
        let r = AXUIElementPerformAction(b, kAXPressAction as CFString)
        print("pid \(pid): press -> \(r.rawValue)")
        if r == .success { pressed += 1 }
    }
}
print("pressed \(pressed)")
exit(pressed > 0 ? 0 : 1)

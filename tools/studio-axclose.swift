import ApplicationServices
import AppKit
// Press the close button of the TestBench place window titled exactly <title> in ONE Studio process, without focus
// change. usage: studio-axclose <pid> "<window title>"   (refuses titles without "TestBench")
let args = CommandLine.arguments
guard args.count > 2, let pid = Int32(args[1]) else { print("usage: studio-axclose <pid> <title>"); exit(2) }
let want = args[2]
guard want.contains("TestBench"), want.hasSuffix(" - Roblox Studio") else { print("refusing non-TestBench title"); exit(3) }
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
func title(_ e: AXUIElement) -> String { attr(e, kAXTitleAttribute) as? String ?? "" }
guard let app = NSRunningApplication(processIdentifier: pid), (app.localizedName ?? "").contains("Roblox") else {
    print("pid \(pid) is not a Roblox Studio process"); exit(2)
}
let ax = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(ax, 2.0)
var closed = 0
for w in (attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? [] where title(w) == want {
    if let c = attr(w, kAXCloseButtonAttribute) {
        let r = AXUIElementPerformAction(c as! AXUIElement, kAXPressAction as CFString)
        print("pid \(pid) close -> \(r.rawValue)")
        if r == .success { closed += 1 }
    }
}
exit(closed > 0 ? 0 : 1)

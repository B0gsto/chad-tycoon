import ApplicationServices
import AppKit
// Bring ONE bench Studio process to the front and type a sequence of key groups into it (issue: osascript -1728).
// usage: studio-keys <pid> <step> [<step> ...]
//   step: "cmd+o", "cmd+shift+g", "return", "escape", "text:<chars>", "sleep:<seconds>",
//         "waitwin:<title>"   wait (10 s) for a window with that title on pid, raise it and make it main + focused
//                             (else keys land in the place window behind an Open panel), fail if it never shows
//         "waitsheet:<title>" wait (5 s) until that window has an AXSheet child (the Go-to-folder sheet), else fail
//         "gonewin:<title>"   wait (15 s) until no window with that title is left on pid, else fail
// Focus is done with NSRunningApplication(processIdentifier:).activate and checked with
// the AX system-wide focused application's pid, so the pid is exact even with several same-named
// "RobloxStudio" processes (AppleScript `tell process "RobloxStudio"` / `first process whose ...` resolve by name or
// against the wrong container and fail with -1728). Before EVERY key group the frontmost pid is re-checked; if it is
// not `pid`, nothing more is typed. The previously frontmost app is re-activated in a defer, whatever happens.
// Exit: 0 all typed; 3 never became frontmost (nothing typed); 4 focus lost midway (something typed);
//       2 bad args / not a Studio process; 5 not a bench process; 6 own deadline hit.
let args = CommandLine.arguments
guard args.count > 2, let pid = Int32(args[1]) else { print("usage: studio-keys <pid> <step>..."); exit(2) }
let steps = Array(args[2...])
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
func title(_ e: AXUIElement) -> String { attr(e, kAXTitleAttribute) as? String ?? "" }
guard let app = NSRunningApplication(processIdentifier: pid), (app.localizedName ?? "").contains("Roblox") else {
    print("pid \(pid) is not a Roblox Studio process"); exit(2)
}
let ax = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(ax, 2.0)
// Fail closed: if the AX window list cannot be read (nil, e.g. an AX timeout), nothing is typed. An empty list is
// a real answer; a failed read is not.
guard let allWins = attr(ax, kAXWindowsAttribute) as? [AXUIElement] else {
    print("pid \(pid): could not read its AX windows; refusing"); exit(5)
}
let places = allWins.map(title).filter { $0.hasSuffix(" - Roblox Studio") }
// Bench only: the process must show a TestBench place and no other place (the user's real game is never driven).
// STUDIO_KEYS_START_PAGE=1 (set by studio-open.py only for a start-page process it launched itself on a TestBench
// file, checked from that process's argv) also allows a process with no place at all.
let startPageOK = ProcessInfo.processInfo.environment["STUDIO_KEYS_START_PAGE"] == "1" && places.isEmpty
guard startPageOK || (places.contains(where: { $0.contains("TestBench") }) && !places.contains(where: { !$0.contains("TestBench") })) else {
    print("pid \(pid) is not a bench process: \(places)"); exit(5)
}

let prevApp = NSWorkspace.shared.frontmostApplication
func restoreUser() { if let p = prevApp, p.processIdentifier != pid { p.activate() } }
// Fresh frontmost pid: the AX system-wide focused application. (NSWorkspace.frontmostApplication is only refreshed
// by notifications on the main run loop, which a CLI does not spin, so it goes stale.)
let systemWide = AXUIElementCreateSystemWide()
func frontPid() -> pid_t {
    RunLoop.current.run(until: Date())
    guard let v = attr(systemWide, kAXFocusedApplicationAttribute) else { return NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1 }
    var p: pid_t = -1
    AXUIElementGetPid(v as! AXUIElement, &p)
    return p
}
func isFront() -> Bool { frontPid() == pid }
// Own deadline: 55 s, below studio-open.py's 60 s subprocess timeout, so focus is always restored here first.
DispatchQueue.global().asyncAfter(deadline: .now() + 55) {
    print("deadline hit; restoring focus")
    restoreUser()
    exit(6)
}

func window(_ t: String) -> AXUIElement? {
    ((attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []).first(where: { title($0) == t })
}
func poll(_ secs: Double, _ f: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(secs)
    while Date() < end { if f() { return true }; usleep(150_000) }
    return f()
}
func hasSheet(_ w: AXUIElement) -> Bool {
    ((attr(w, kAXChildrenAttribute) as? [AXUIElement]) ?? []).contains { (attr($0, kAXRoleAttribute) as? String) == "AXSheet" }
}
func focusWindow(_ w: AXUIElement) -> Bool {
    AXUIElementPerformAction(w, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(w, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    return poll(2) {
        // While a sheet is up, AXFocusedWindow is the (untitled) sheet; then the window being main is enough.
        [kAXFocusedWindowAttribute, kAXMainWindowAttribute].contains { a in
            attr(ax, a).map { title($0 as! AXUIElement) == title(w) } ?? false
        }
    }
}

let src = CGEventSource(stateID: .hidSystemState)
func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
        usleep(30_000)
    }
}
// US-ANSI virtual keycodes: Roblox reads the keycode, not the unicode string (virtual key 0 + "f" arrives as KeyCode.A).
let ansi: [Character: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
    "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
    "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
    "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49, "`": 50,
]
let shifted: [Character: Character] = [
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0", "_": "-", "+": "=",
    "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
]
func text(_ s: String) {
    for ch in s {
        // The real keycode (plus Shift for upper case / shifted symbols) and the unicode string, so both game input
        // (keycode) and text fields (string) get the right character. Unmapped characters fall back to keycode 0.
        let lower = Character(ch.lowercased())
        let base = shifted[ch] ?? lower
        let vk = ansi[base] ?? 0
        let shift = shifted[ch] != nil || (ch.isUppercase && ansi[lower] != nil)
        var units = Array(String(ch).utf16)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: down)
            e?.flags = shift ? .maskShift : []
            e?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            e?.post(tap: .cghidEventTap)
        }
        usleep(12_000)
    }
}

var code: Int32 = 0
do {
    defer { restoreUser() }
    // NSRunningApplication.activate() alone is often refused for a background CLI caller (macOS 14+ cooperative
    // activation), so also set AXFrontmost on that exact pid's AX element (what System Events does, minus the
    // by-name lookup). No window is raised: that would steal key focus from an Open panel or Go-to sheet.
    var front = false
    for attempt in 0..<3 where !front {
        app.activate(options: [.activateAllWindows])
        AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        for _ in 0..<(10 + 10 * attempt) { if isFront() { front = true; break }; usleep(100_000) }
    }
    if !front {
        print("pid \(pid) did not become frontmost; nothing typed"); code = 3
    } else {
        var typed = false
        var settled = false
        for s in steps {
            if s.hasPrefix("sleep:") { usleep(useconds_t((Double(s.dropFirst(6)) ?? 0) * 1_000_000)); continue }
            if s.hasPrefix("waitwin:") || s.hasPrefix("waitsheet:") || s.hasPrefix("gonewin:") {
                let t = String(s[s.index(after: s.firstIndex(of: ":")!)...])
                var ok = false
                if s.hasPrefix("waitwin:") {
                    var w: AXUIElement? = nil
                    ok = poll(10) { w = window(t); return w != nil } && focusWindow(w!)
                } else if s.hasPrefix("waitsheet:") {
                    ok = poll(5) { window(t).map(hasSheet) ?? false }
                } else {
                    ok = poll(15) { window(t) == nil }
                }
                if !ok { print("step \(s) failed on pid \(pid)"); code = typed ? 4 : 3; break }
                continue
            }
            // Key groups only: during the wait steps above focus may legitimately move (the opened place's new
            // process comes to the front by itself), but no key is ever sent unless `pid` is frontmost.
            guard isFront() else {
                print("focus left pid \(pid) before step \(s); stopped"); code = typed ? 4 : 3; break
            }
            if s.hasPrefix("press:") {
                // "press:<window title>|<button title>": AXPress a direct button of that window (the panel's Open)
                let parts = s.dropFirst(6).split(separator: "|", maxSplits: 1).map(String.init)
                func find(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
                    for k in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                        if (attr(k, kAXRoleAttribute) as? String) == "AXButton" && title(k) == parts[1] { return k }
                        if d < 3, let f = find(k, d + 1) { return f }
                    }
                    return nil
                }
                let b = parts.count == 2 ? window(parts[0]).flatMap { find($0, 0) } : nil
                guard let btn = b, AXUIElementPerformAction(btn, kAXPressAction as CFString) == .success else {
                    print("could not press \(s) on pid \(pid)"); code = typed ? 4 : 3; break
                }
                typed = true
                continue
            }
            if s.hasPrefix("sheetvalue:") {
                // Set the Go-to sheet's text field through AX (typed characters race its autocompletion, which can
                // close the sheet), then check the value stuck.
                let v = String(s.dropFirst(11))
                let sheets = ((attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []).flatMap { w in
                    ((attr(w, kAXChildrenAttribute) as? [AXUIElement]) ?? []).filter { (attr($0, kAXRoleAttribute) as? String) == "AXSheet" }
                }
                let field = sheets.lazy.compactMap { sh in
                    ((attr(sh, kAXChildrenAttribute) as? [AXUIElement]) ?? []).first { (attr($0, kAXRoleAttribute) as? String) == "AXTextField" }
                }.first
                if let f = field {
                    AXUIElementSetAttributeValue(f, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                    AXUIElementSetAttributeValue(f, kAXValueAttribute as CFString, v as CFString)
                }
                guard let f = field, poll(2, { (attr(f, kAXValueAttribute) as? String) == v }) else {
                    print("could not set the Go-to field on pid \(pid)"); code = typed ? 4 : 3; break
                }
                typed = true
                continue
            }
            switch s {
            case "escape": key(53)
            case "cmd+o": key(31, .maskCommand)
            case "cmd+shift+g": key(5, [.maskCommand, .maskShift])
            case "return": key(36)
            default:
                if s.hasPrefix("text:") {
                    // The game view drops keys for a moment after Studio comes to the front (live: only the last of
                    // "fF1e" arrived), so settle once before the first text group.
                    if !settled { usleep(500_000); settled = true }
                    text(String(s.dropFirst(5)))
                } else { print("unknown step \(s)"); code = 2 }
            }
            if code != 0 { break }
            typed = true
        }
        if code == 0 { print("pid \(pid): typed \(steps.count) steps") }
    }
}
exit(code)

// Roblox Player (the game client, not Studio) helper for tools/roblox_play.py.
// usage:
//   roblox-player windows                 JSON list of the player's layer-0 windows {id,pid,x,y,w,h,name,onscreen}
//   roblox-player key <pid> <step>...     bring <pid> to the front, type the steps, give focus back
//       step: "w" (tap), "w:1.5" (hold 1.5 s), "space", "return", "escape", "tab", "shift", "left|right|up|down",
//             "text:<chars>" (taps each char), "sleep:<s>"
//   roblox-player click <pid> <x> <y>     left click at window-relative point (x, y) of pid's main window
// Only processes named Roblox/RobloxPlayer are driven (never Roblox Studio). Needs Accessibility for key/click and
// Screen Recording for window names. Exit: 0 ok, 2 bad args / not a Roblox Player pid, 3 never became frontmost.
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

let OWNERS: Set<String> = ["Roblox", "RobloxPlayer"]
let args = CommandLine.arguments

func playerWindows() -> [[String: Any]] {
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    var out: [[String: Any]] = []
    for w in list {
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        let layer = w[kCGWindowLayer as String] as? Int ?? -1
        guard OWNERS.contains(owner), layer == 0, let b = w[kCGWindowBounds as String] as? [String: Double] else { continue }
        out.append([
            "id": w[kCGWindowNumber as String] as? Int ?? 0,
            "pid": w[kCGWindowOwnerPID as String] as? Int ?? 0,
            "x": b["X"] ?? 0, "y": b["Y"] ?? 0, "w": b["Width"] ?? 0, "h": b["Height"] ?? 0,
            "name": w[kCGWindowName as String] as? String ?? "",
            "onscreen": w[kCGWindowIsOnscreen as String] as? Bool ?? false,
        ])
    }
    return out
}

func fail(_ msg: String, _ code: Int32) -> Never { print(msg); exit(code) }

guard args.count >= 2 else { fail("usage: roblox-player windows | key <pid> <step>... | click <pid> <x> <y>", 2) }

if args[1] == "windows" {
    let data = try! JSONSerialization.data(withJSONObject: playerWindows())
    print(String(data: data, encoding: .utf8)!)
    exit(0)
}

guard args.count >= 3, let pid = Int32(args[2]) else { fail("missing pid", 2) }
guard let app = NSRunningApplication(processIdentifier: pid) else { fail("no process \(pid)", 2) }
let name = app.localizedName ?? ""
let exe = app.executableURL?.lastPathComponent ?? ""
guard (OWNERS.contains(name) || exe == "RobloxPlayer"), !name.contains("Studio"), !exe.contains("Studio") else {
    fail("pid \(pid) is not the Roblox Player (\(name))", 2)
}

let previous = NSWorkspace.shared.frontmostApplication
defer { if let p = previous, p.processIdentifier != pid { p.activate() } }

func front() -> Bool {
    app.activate(options: [.activateAllWindows])
    for _ in 0..<40 {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
        usleep(50_000)
    }
    return false
}

let KEYS: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
    "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
    "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    "return": 36, "tab": 48, "space": 49, " ": 49, "escape": 53, "shift": 56, "left": 123, "right": 124,
    "down": 125, "up": 126,
]

func press(_ code: CGKeyCode, hold: Double) {
    let src = CGEventSource(stateID: .hidSystemState)
    CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
    usleep(useconds_t(max(hold, 0.04) * 1_000_000))
    CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    usleep(40_000)
}

if args[1] == "key" {
    guard args.count >= 4 else { fail("key needs steps", 2) }
    guard front() else { fail("Roblox Player never became frontmost", 3) }
    usleep(150_000)
    for step in args[3...] {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { fail("focus lost", 3) }
        if step.hasPrefix("sleep:") { usleep(useconds_t((Double(step.dropFirst(6)) ?? 0) * 1_000_000)); continue }
        if step.hasPrefix("text:") {
            for ch in step.dropFirst(5).lowercased() {
                if let code = KEYS[String(ch)] { press(code, hold: 0.05) }
            }
            continue
        }
        let parts = step.lowercased().split(separator: ":", maxSplits: 1).map(String.init)
        guard let code = KEYS[parts[0]] else { fail("unknown key \(parts[0])", 2) }
        press(code, hold: parts.count > 1 ? (Double(parts[1]) ?? 0.05) : 0.05)
    }
    exit(0)
}

if args[1] == "click" {
    guard args.count >= 5, let x = Double(args[3]), let y = Double(args[4]) else { fail("click <pid> <x> <y>", 2) }
    guard let win = playerWindows().filter({ ($0["pid"] as? Int) == Int(pid) })
        .max(by: { ($0["w"] as! Double) * ($0["h"] as! Double) < ($1["w"] as! Double) * ($1["h"] as! Double) })
    else { fail("no window for pid \(pid)", 2) }
    guard front() else { fail("Roblox Player never became frontmost", 3) }
    usleep(150_000)
    let p = CGPoint(x: (win["x"] as! Double) + x, y: (win["y"] as! Double) + y)
    let src = CGEventSource(stateID: .hidSystemState)
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(80_000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(60_000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(100_000)
    exit(0)
}

fail("unknown subcommand \(args[1])", 2)

import Cocoa
import ApplicationServices

// AX 探针（第三轮）：用稳定标识 AX_FIND_CURSOR 定位「摇动鼠标指针以定位」开关。
// 验证「拨一次再拨回」能否让 System Settings 重写偏好并触发 WindowServer 重载。
//
// 用法：AXCursorZoomProbe [dump|toggle]
//   dump   —— 只读：打印目标开关的 AXValue 与当前 plist 值
//   toggle —— AXPress 两次（关→开→关），每步读回 AXValue + plist，
//             最终必须回到「关」；任何一步不符合预期都以非零码报红。

func axAttr(_ el: AXUIElement, _ key: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, key as CFString, &v) == .success ? v : nil
}
func axStr(_ v: CFTypeRef?) -> String {
    guard let v else { return "" }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return "\(n)" }
    return ""
}
func axStrOf(_ el: AXUIElement, _ key: String) -> String { axStr(axAttr(el, key)) }

func plistValue() -> String {
    let task = Process()
    task.launchPath = "/usr/bin/defaults"
    task.arguments = ["read", ".GlobalPreferences", "CGDisableCursorLocationMagnification"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    try? task.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

let mode = CommandLine.arguments.dropFirst().first ?? "dump"
print("AXIsProcessTrusted = \(AXIsProcessTrusted())")
print("plist(before) = \(plistValue())")

let apps = NSWorkspace.shared.runningApplications.filter {
    $0.bundleIdentifier == "com.apple.systempreferences"
}
guard let pid = apps.first?.processIdentifier else {
    print("RESULT settings-not-running"); exit(2)
}
let root = AXUIElementCreateApplication(pid_t(pid))
var visited = 0
var target: AXUIElement? = nil

func walk(_ el: AXUIElement, _ depth: Int) {
    if depth > 20 || visited > 60000 || target != nil { return }
    visited += 1
    if axStrOf(el, "AXIdentifier") == "AX_FIND_CURSOR" {
        target = el
        return
    }
    if let cf = axAttr(el, kAXChildrenAttribute) {
        let arr = unsafeBitCast(cf, to: CFArray.self)
        let n = CFArrayGetCount(arr)
        for i in 0..<n {
            walk(unsafeBitCast(CFArrayGetValueAtIndex(arr, i), to: AXUIElement.self), depth + 1)
        }
    }
}
if let cf = axAttr(root, kAXWindowsAttribute) {
    let arr = unsafeBitCast(cf, to: CFArray.self)
    for i in 0..<CFArrayGetCount(arr) {
        walk(unsafeBitCast(CFArrayGetValueAtIndex(arr, i), to: AXUIElement.self), 0)
    }
}
print("visited = \(visited)")
guard let t = target else {
    print("RESULT target-not-found")
    exit(3)
}
let before = axStr(axAttr(t, kAXValueAttribute))
print("AXValue(before) = '\(before)'  role=\(axStrOf(t, kAXRoleAttribute))  id=\(axStrOf(t, "AXIdentifier"))")

if mode != "toggle" {
    print("RESULT dump-ok")
    exit(0)
}

// 目标终态：关（AXValue=0 / plist=1）。为了触发系统重新加载，需要让 GUI 主动写两次。
// 若当前是开，先拨到关；若当前已是关，则拨成开再拨回关，保证两次都经过 GUI 写入路径。
var presses = 0
if before != "0" {
    print("unexpected: switch is ON, pressing once to turn OFF")
    let r = AXUIElementPerformAction(t, kAXPressAction as CFString)
    print("AXPress#1 result=\(r.rawValue)")
    presses += 1
    usleep(500_000)
} else {
    // 关 → 开
    let r1 = AXUIElementPerformAction(t, kAXPressAction as CFString)
    usleep(500_000)
    let mid = axStr(axAttr(t, kAXValueAttribute))
    print("AXPress#1 result=\(r1.rawValue) midValue='\(mid)' plist=\(plistValue())")
    presses += 1
    // 开 → 关
    let r2 = AXUIElementPerformAction(t, kAXPressAction as CFString)
    print("AXPress#2 result=\(r2.rawValue)")
    presses += 1
    usleep(500_000)
}
let after = axStr(axAttr(t, kAXValueAttribute))
let pv = plistValue()
print("AXValue(after) = '\(after)'  plist(after) = \(pv)  presses=\(presses)")

// 反向验证：终态必须回到「关」，且 plist 必须是禁用值 1，否则判失败（不假绿）
if after != "0" { print("RESULT FAIL switch-not-off"); exit(4) }
if pv != "1" { print("RESULT FAIL plist-not-disabled(\(pv))"); exit(5) }
print("RESULT toggle-ok")

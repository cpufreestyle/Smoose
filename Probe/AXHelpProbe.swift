// AXHelpProbe — 用辅助功能 API 读回 Smoose 界面里每个控件真实挂上的 tooltip。
//
// 为什么需要它：`smooseHelp` 在源码里写没写、harness 的 T_W 段只做了文本断言，
// 都无法证明「运行中的 App 真的把 toolTip 设到了 NSView 上」—— SwiftUI 的
// `.help()` 在某些容器（Form / List 的某些版本）里会被吞掉，表现为源码全绿而
// 真机悬停毫无反应。这个探针直接从 WindowServer 读 AXHelp 属性，是唯一不依赖
// 「摇鼠标看画面」的客观证据。
//
// 用法（终端需已获辅助功能授权；只读，除了 --expand 会点开折叠分组）：
//   swiftc -O Probe/AXHelpProbe.swift -o /tmp/axhelp && /tmp/axhelp
//   /tmp/axhelp --all        连没有 tooltip 的控件也列出来（排查漏挂载）
//   /tmp/axhelp --panel      顺带打开菜单栏面板一起读
//   /tmp/axhelp --expand     先点开每应用的折叠行，再读「细节参数」里的轴向开关
//   /tmp/axhelp --confirm-interact  确认允许合成点击后再跑 --expand（默认 --expand 只读）
//
// 判定标准：PROBE-OK 只说明「读到了至少一个 tooltip」。要判断某个具体控件有没有
// 挂上，看输出里有没有它的标题 —— 没有就是没挂，别用总数糊过去。
import AppKit
import ApplicationServices

let bundleID = "app.smoose.macos"
let args = Set(CommandLine.arguments)
let verbose = args.contains("--all")
let wantPanel = args.contains("--panel")
let wantExpand = args.contains("--expand")
let allowInteraction = args.contains("--confirm-interact")

guard let app = NSWorkspace.shared.runningApplications
    .first(where: { $0.bundleIdentifier == bundleID }) else {
    print("PROBE-FAIL Smoose 没在运行"); exit(1)
}
let axApp = AXUIElementCreateApplication(app.processIdentifier)

func attr(_ e: AXUIElement, _ name: String) -> String {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success,
          let s = v as? String else { return "" }
    return s
}
func kids(_ e: AXUIElement) -> [AXUIElement] {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success,
          let a = v as? [AXUIElement] else { return [] }
    return a
}
func allWindows() -> [AXUIElement] {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &v) == .success,
          let a = v as? [AXUIElement] else { return [] }
    return a
}

// 切页：用 settings URL 带 ?tab=N，不靠 AX 点击，避免探针自己产生副作用。
// tab 索引与设置窗口 TabView 顺序一致（实测）：0 常规 1 指针 2 每应用 3 按键 4 游戏 5 关于。
// 索引与界面不一致时只会少读一页，不会把没挂的说成挂了。
func switchTab(_ n: Int) {
    if let u = URL(string: "smoose://settings?tab=\(n)") {
        NSWorkspace.shared.open(u)
        usleep(700_000)
    }
}

/// 点开标题含「细节参数」的折叠组（每应用的轴向开关默认折叠着，不点开读不到）。
func expandDetails() {
    guard allowInteraction else {
        print("PROBE-INFO --expand 需要同时传 --confirm-interact 才会合成点击；本次只读")
        return
    }
    func rec(_ e: AXUIElement, depth: Int) {
        if depth > 12 { return }
        for k in kids(e) {
            let role = attr(k, "AXRole")
            let title = attr(k, "AXTitle")
            if (role == "AXDisclosureTriangle" || role == "AXButton")
                && title.contains("细节参数") {
                AXUIElementPerformAction(k, kAXPressAction as CFString)
                print("PROBE-INFO 已点开折叠组「\(title)」")
            }
            rec(k, depth: depth + 1)
        }
    }
    for w in allWindows() { rec(w, depth: 0) }
    usleep(600_000)
}

/// 点开每应用列表里的行：SwiftUI List 的 DisclosureGroup 不单独暴露 AX 元素，
/// 折叠内容连 AX 树里都没有，只能整行 AXPress 让它展开。
func pressRows() {
    guard allowInteraction else {
        print("PROBE-INFO --expand 需要同时传 --confirm-interact 才会合成点击；本次只读")
        return
    }
    func rec(_ e: AXUIElement, depth: Int) {
        if depth > 12 { return }
        for k in kids(e) {
            if attr(k, "AXRole") == "AXRow" {
                AXUIElementPerformAction(k, kAXPressAction as CFString)
                print("PROBE-INFO 已点开列表行")
            }
            rec(k, depth: depth + 1)
        }
    }
    for w in allWindows() { rec(w, depth: 0) }
    usleep(600_000)
}

/// 深度上限 12：设置窗口控件树最深约 8 层，留余量防递归失控。
func walk(_ e: AXUIElement, depth: Int, into collect: inout [(String, String, String)]) {
    if depth > 12 { return }
    for k in kids(e) {
        let help = attr(k, "AXHelp")
        let role = attr(k, "AXRoleDescription")
        let title = attr(k, "AXTitle")
        let value = attr(k, "AXValue")
        let shown = title.isEmpty ? (value.isEmpty ? attr(k, "AXRole") : value) : title
        if !help.isEmpty || verbose { collect.append((role, shown, help)) }
        walk(k, depth: depth + 1, into: &collect)
    }
}

if wantPanel, let u = URL(string: "smoose://open") {
    NSWorkspace.shared.open(u)
    usleep(1_200_000)
}

/// 每个窗口都单独读一遍，并按「标题 + 尺寸」打印，避免把设置窗口和菜单栏面板
/// 混成一坨（两者 AXTitle 都可能带 Smoose，只靠标题分会漏读面板）。
func windowLabel(_ w: AXUIElement) -> String {
    var sz: CFTypeRef?
    var size = "尺寸未知"
    var s: CGSize = .zero
    if AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sz) == .success,
       AXValueGetType(sz as! AXValue) == .cgSize {
        AXValueGetValue(sz as! AXValue, .cgSize, &s)
        size = "\(Int(s.width))×\(Int(s.height))"
    }
    let t = attr(w, "AXTitle")
    return "\(t.isEmpty ? "（无标题）" : t) [\(attr(w, "AXRoleDescription")), \(size)]"
}

func probeWindow(_ w: AXUIElement, name: String) -> (Int, Int) {
    var rows: [(String, String, String)] = []
    walk(w, depth: 0, into: &rows)
    let hit = rows.filter { !$0.2.isEmpty }
    print("── \(name)：\(hit.count)/\(rows.count) 个控件带 tooltip")
    // --all 时把没有 tooltip 的控件也列出来：排查「该挂没挂」只能靠这个，
    // 只打有的那一半看不出漏了什么。
    for (role, title, help) in verbose ? rows : hit {
        let tag = help.isEmpty ? "（无 tooltip）" : "→ \(help.prefix(60))"
        print("   \(title.isEmpty ? "（无标题）" : title) [\(role)] \(tag)")
    }
    return (hit.count, rows.count)
}

var grand = 0
var enumerated = 0

// 先把当前所有窗口读一遍（菜单栏面板、设置窗口各一份）。
for w in allWindows() {
    let (h, t) = probeWindow(w, name: "窗口 \(windowLabel(w))")
    grand += h; enumerated += t
}

// 再逐页切设置窗口。每页都重取窗口列表，切页瞬间窗口树会重建。
for tab in [0, 1, 2, 3, 4, 5] {
    switchTab(tab)
    if tab == 2 && wantExpand { expandDetails(); pressRows() }
    let ws = allWindows()
    if ws.isEmpty {
        print("── tab \(tab)：PROBE-WARN 切页后没枚举到窗口（可能被系统延迟吃掉），跳过")
        continue
    }
    // 取控件最多的那个窗口：设置窗口远比菜单栏面板深，不会误取面板。
    let target = ws.max(by: { a, b in
        var ra: [(String, String, String)] = []; var rb: [(String, String, String)] = []
        walk(a, depth: 0, into: &ra); walk(b, depth: 0, into: &rb)
        return ra.count < rb.count
    })!
    let (h, t) = probeWindow(target, name: "tab \(tab) · 窗口 \(windowLabel(target))")
    grand += h; enumerated += t
}

print("PROBE-RESULT 带 tooltip 的控件 \(grand) 个（--all 模式下枚举到 \(enumerated) 个）")
if grand == 0 {
    print("PROBE-FAIL 一个都没读到：要么窗口没打开，要么 .help() 被容器吞了")
    exit(1)
}
print("PROBE-OK")

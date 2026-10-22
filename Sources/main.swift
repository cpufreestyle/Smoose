import AppKit

// 纯 AppKit 入口，不用 SwiftUI App 协议。
// 踩过的两个坑：
// 1. .accessory 策略（LSUIElement）下 App 无法被 LaunchServices 激活，
//    双击桌面图标完全没反应（不发 reopen、不触发任何回调）。
// 2. .regular 策略下 SwiftUI 的 Settings 场景会在启动时自动弹出一个空窗口。
// 所有 UI 由 AppDelegate 手动管理：NSStatusItem + NSPopover + 手动 NSWindow。

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

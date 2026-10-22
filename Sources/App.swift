import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// 自动更新的定时器：每天一次静默检查
    private var updateTimer: Timer?

    private var onboardingWindow: NSWindow?
    /// 手动管理的设置窗口。SwiftUI Settings 场景的窗口一关就永远死掉（showSettingsWindow: 失效），
    /// 所以改用 NSWindow + NSHostingView，关闭时只停留隐藏。
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例保护（myMouseMagic AppDelegate 的 alreadyRunning 模式）：
        // open -n 或手动双击会启动第二份；同 bundleID 已有实例时弹窗提醒后退出。
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let alreadyRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "app.smoose.macos" && $0.processIdentifier != selfPID
        }
        if alreadyRunning {
            let alert = NSAlert()
            alert.messageText = "Smoose 已在运行"
            alert.informativeText = "菜单栏已有一个 Smoose 实例。重复启动会导致事件 tap 冲突。"
            alert.addButton(withTitle: "退出这个副本")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        // .regular 而不是 .accessory：
        // 实测证明 LSUIElement agent App 已运行时，双击桌面图标（open bundle）
        // 完全是空操作：不发 reopen、不激活、不触发任何回调，窗口永远不出来。
        // 只有 .regular 才能被 LaunchServices 激活。代价是多一个 Dock 图标。
        NSApp.setActivationPolicy(.regular)
        // 纯 AppKit 入口下 SwiftUI 不再代为激活，必须自己 activate，
        // 否则 isActive 恒为 false，启动时的开窗判断会被门禁挡掉。
        NSApp.activate(ignoringOtherApps: true)
        StatusBarController.shared.install()
        registerURLEntry()
        ScrollEngine.shared.install(initial: Preferences.shared.stored)
        PointerController.shared.start()
        refreshActiveApp()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                ScrollEngine.shared.setActiveApp(app.bundleIdentifier)
                ActiveAppInfo.shared.bundleID = app.bundleIdentifier
                ActiveAppInfo.shared.name = app.localizedName
            }
        }
        observeWake()
        showOnboardingIfNeeded()
        syncCursorZoomFromSystem()
        openSettingsWindowOnLaunch()
        startUpdateChecker()
    }

    /// 每天一次静默检查更新。刻意延迟 5 秒再检查：
    /// 启动阶段正是 HID tap 安装、权限校准的忙点，别和网络请求抢主线程。
    private func startUpdateChecker() {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: Updater.checkInterval, repeats: true) { _ in
            Updater.shared.checkIfNeeded()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            Updater.shared.checkIfNeeded()
        }
    }

    /// 双击桌面图标 / Dock 图标（或别的方式激活 App）时打开设置窗口。
    /// LSUIElement=true 的菜单栏 App 没有 Dock 图标也不会自动开窗口，
    /// 不实现这个方法时，双击桌面别名只会把 App 启起来，屏幕上什么都不出来。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 备用路径：若系统通过 delegate 送了 reopen 也处理。
        // 主路径是 registerReopenEntry() 里的 kAEReopen 监听（见下面）。
        openSettingsWindow()
        return true
    }

    /// 打开设置窗口。
    /// 用手动 NSWindow 而不是 SwiftUI Settings 场景：后者的窗口关闭即销毁，
    /// showSettingsWindow: 再也叫不回来（实测）。这里关闭时只 orderOut，窗口对象一直活着。
    private func openSettingsWindow() {
        if let w = settingsWindow {
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Smoose"
        w.titleVisibility = .visible
        w.isMovableByWindowBackground = false
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = NSHostingView(rootView:
            SettingsWindow()
                .environmentObject(Preferences.shared)
                .environmentObject(ActiveAppInfo.shared)
                .environmentObject(Monitor.shared)
        )
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = w
    }

    /// 给 AnchorWindow 用的公开包裹。
    func openSettingsWindowForAnchor() {
        openSettingsWindow()
    }

    /// 点关闭按钮时只隐藏窗口，不销毁 —— 这样下次双击图标还能叫回来。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    /// 冷启动时判断是否打开设置窗口。
    /// 用户双击桌面图标启动时 LaunchServices 会激活 App；
    /// 而登录项启动（launchAtLogin=true）时 App 保持后台，不应弹窗口扔到用户脸上。
    /// 所以等 0.8s 看 isActive：激活了才证明是用户主动启动。
    private func openSettingsWindowOnLaunch() {
        // 冷启动总是打开设置窗口。
        // 之前用 NSApp.isActive 门禁想区分「用户双击」和「登录项启动」，
        // 但纯 AppKit 入口下 activate 时机不可靠，isActive 恒 false，窗口反而打不开。
        // 用户的核心诉求是「双击桌面图标能弹出窗口」，必须保证；
        // 登录时也弹窗是可接受的小代价。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.openSettingsWindow()
        }
    }

    private func refreshActiveApp() {
        let app = NSWorkspace.shared.frontmostApplication
        ScrollEngine.shared.setActiveApp(app?.bundleIdentifier)
        ActiveAppInfo.shared.bundleID = app?.bundleIdentifier
        ActiveAppInfo.shared.name = app?.localizedName
    }

    /// 睡眠唤醒后 HID 参数会被系统重置，需要重新套用
    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            PointerController.shared.refresh(force: true)
        }
    }

    /// 启动时以系统状态为准：用户可能在「系统设置」里改过这个开关，
    /// Smoose 的开兿只是一个入口，不应该把自己的值覆盖掉系统。
    private func syncCursorZoomFromSystem() {
        let on = CursorZoomController.shared.systemEnabled
        if Preferences.shared.cursorZoomEnabled != on {
            Preferences.shared.cursorZoomEnabled = on
        }
    }

    private func showOnboardingIfNeeded() {
        guard !ScrollEngine.trusted(prompt: false) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 460),
                                  styleMask: [.titled, .closable, .fullSizeContentView],
                                  backing: .buffered,
                                  defer: false)
            window.title = "Smoose 需要权限"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.contentViewController = NSHostingController(
                rootView: OnboardingView { [weak self] in self?.closeOnboarding() }
            )
            window.center()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            self.onboardingWindow = window
        }
    }

    private func closeOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    /// 关掉最后一个窗口不退出 App。
    /// 否则用户关掉设置窗口后 App 就死了，再双击图标是冷启动，
    /// 而且事件拥刺（event tap）也被干掉。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateTimer?.invalidate()
        ScrollEngine.shared.stop()
    }

    /// 兜底入口：多屏下 status item 被系统挂到副屏/幽灵屏时，用户仍可用
    ///   open smoose://open      —— 主屏中心弹出面板
    ///   open smoose://settings  —— 打开设置窗口
    private func registerURLEntry() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        registerReopenEntry()
    }

    /// 监听 kAEReopen（双击图标 / Finder 重新打开 App）。
    /// 必须走 NSAppleEventManager 而不是 NSApplicationDelegate：
    /// 实测证明 SwiftUI App + LSUIElement 组合下，
    /// applicationShouldHandleReopen / applicationDidBecomeActive 都不会送达，双击桌面图标就没反应。
    private func registerReopenEntry() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleReopenEvent(_:withReplyEvent:)),
            // kAECoreStandard = 'aevt', kAEReopen = 'rapp'
            // 用原始 FourCC：这两个常量属于 Carbon/AE，不企业 import 也能用。
            forEventClass: AEEventClass(0x61657674),
            andEventID: AEEventID(0x72617070)
        )
    }

    @objc private func handleReopenEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        NSLog("Smoose: kAEReopen received")
        openSettingsWindow()
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue ?? ""
        NSApp.activate(ignoringOtherApps: true)
        if url.contains("settings") {
            openSettingsWindow()
        } else {
            StatusBarController.shared.showAtCenter()
        }
    }
}

/// 主屏菜单栏常驻图标 + 点击弹出设置面板
final class StatusBarController: NSObject, NSPopoverDelegate {
    static let shared = StatusBarController()
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var monitor: Any?
    private var healTimer: Timer?

    func install() {
        guard item == nil else { return }
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        it.button?.image = NSImage(systemSymbolName: "arrow.up.and.down.circle", accessibilityDescription: "Smoose")
        it.button?.target = self
        it.button?.action = #selector(toggle)
        popover.contentSize = NSSize(width: 320, height: 420)
        popover.behavior = .transient
        popover.delegate = self
        let vc = NSHostingController(rootView:
            MenuBarPanel()
                .environmentObject(Preferences.shared)
                .environmentObject(ActiveAppInfo.shared)
                .environmentObject(Monitor.shared)
        )
        popover.contentViewController = vc
        item = it

        // 多屏/幽灵屏环境下 macOS 会把 status item 挂到不可见的屏（用户点不到）。
        // 注意：幽灵屏也会出现在 NSScreen.screens 里，所以不能用它判定；
        // 用 CGWindowList(.optionOnScreenOnly) 检查 button 的 window 是否真的在屏上。
        healTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            // 1) status item 自愈（原有逻辑）
            if let btn = self.item?.button, let win = btn.window, win.isVisible {
                let visible = Self.isOnscreen(windowID: win.windowNumber)
                if !visible {
                    self.reinstall()
                }
            }
            // 2) 设置窗口位置守护：SwiftUI Settings 场景会把位置持久化，一旦记的是副屏，
            //    每次打开都还原到副屏——用户在主屏看不到，即「界面打不开」。
            //    菜单栏图标固定在主屏，设置窗口也跟着在主屏。
            Task { @MainActor in
                for w in NSApp.windows where w.isVisible && w.styleMask.contains(.titled) && !w.title.isEmpty {
                    Self.moveSettingsWindowToMainScreenIfNeeded(w)
                }
            }
        }
    }

    /// window 是否真的出现在屏幕上（CGWindowList 的 on-screen 列表 = 用户可见的）
    private static func isOnscreen(windowID: Int) -> Bool {
        // CGWindowList 对 status bar window 恒报 on-screen（即使在幽灵屏），
        // 所以用 window frame 与活动显示器的实际区域求交
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(16, nil, &displayCount)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(16, &ids, &displayCount)
        let win = CGWindowListCopyWindowInfo([.optionIncludingWindow], kCGNullWindowID) as? [[String: Any]]
        guard let info = win?.first(where: { ($0[kCGWindowNumber as String] as? Int) == windowID }),
              let b = info[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] else { return true }
        let rect = CGRect(x: x, y: y, width: w, height: h)
        for i in 0..<Int(displayCount) {
            let db = CGDisplayBounds(ids[i])
            if db.intersects(rect) { return true }
        }
        return false
    }

    /// 若设置窗口不在主屏，移到主屏可见区域居中。
    /// 不是「不在任何屏」才移 —— 用户痛点是窗口在副屏（真实存在）上，主屏找不到。
    @MainActor static func moveSettingsWindowToMainScreenIfNeeded(_ win: NSWindow) {
        let main = NSScreen.screens.first { $0.frame.origin.x == 0 && $0.frame.origin.y == 0 }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let center = CGPoint(x: win.frame.midX, y: win.frame.midY)
        guard !main.frame.contains(center) else { return }
        let vf = main.visibleFrame
        win.setFrameOrigin(NSPoint(
            x: vf.origin.x + (vf.width - win.frame.width) / 2,
            y: vf.origin.y + (vf.height - win.frame.height) / 2
        ))
    }

    /// 重建 status item（自愈）
    private func reinstall() {
        if let old = item {
            NSStatusBar.system.removeStatusItem(old)
        }
        item = nil
        install()
    }

    @objc private func toggle() {
        guard let button = item?.button else { return }
        showPopover(from: button)
    }

    private func showPopover(from button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// URL 兜底入口：不依赖 status item 位置，直接在主屏中心弹面板
    func showAtCenter() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // 没有可见窗口做锚点时，popover 无法定位。先打开设置窗口（它会成为锚点并居中），
        // 再以它的标题栏为锚弹出面板 —— 这样用户看到的就是「面板浮在屏幕中央」。
        guard let host = AnchorWindow.shared.hostWindow() else { return }
        if let screen = NSScreen.main {
            let size = host.frame.size
            host.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2,
                                        y: screen.frame.midY - size.height / 2))
        }
        let anchorView = host.contentView ?? NSView()
        popover.show(relativeTo: NSRect(x: anchorView.bounds.midX, y: anchorView.bounds.maxY, width: 1, height: 1),
                     of: anchorView, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
    }
}

/// 锚点视图：popover.show(relativeTo:) 需要一个 view。
/// 用设置窗口（或隐藏窗口）里的 view 做锚点，**不再创建常驻顶层窗口** ——
/// 之前用一个 2x2 的 .popUpMenu 级 borderless window 常驻屏幕中心，会挡住点击且用户拖不动关不掉。
final class AnchorWindow {
    static let shared = AnchorWindow()

    /// 取一个可见窗口做锚点宿主；没有可见窗口就先让 App 打开设置窗口
    func hostWindow() -> NSWindow? {
        if let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) { return w }
        // 用手动管理的设置窗口，不要 showSettingsWindow:（那会弹出空的 Settings 场景窗口）
        if let d = NSApp.delegate as? AppDelegate {
            d.openSettingsWindowForAnchor()
        }
        return NSApp.windows.first(where: { $0.isVisible })
    }

    /// 返回一个可用的锚点 view：优先用主屏上已有的 NSWindow，没有就返回一个 1x1 的隐藏 NSView
    func ensureAnchorView() -> NSView {
        if let existing = NSApp.windows.first(where: { $0.isVisible && !$0.title.isEmpty }) {
            return existing.contentView ?? NSView()
        }
        return NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// 无可见窗口时，直接把 popover 定位到主屏中心（用屏幕坐标系锚点）
    func mainScreenCenterView() -> NSView {
        if let v = NSApp.windows.first(where: { $0.isVisible })?.contentView { return v }
        return NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }
}


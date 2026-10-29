import Foundation
import CoreGraphics
import CoreVideo
import QuartzCore
import AppKit
import ApplicationServices

/// 滚动引擎：在 HID 层拦截滚轮事件，用显示刷新率驱动的插值器重建滚动曲线。
final class ScrollEngine {

    static let shared = ScrollEngine()

    // CGEventField 的 raw value（避免不同 SDK 的命��差异）
    private enum F {
        static let lineY    = CGEventField(rawValue: 11)!
        static let lineX    = CGEventField(rawValue: 12)!
        static let fixedY   = CGEventField(rawValue: 93)!
        static let fixedX   = CGEventField(rawValue: 94)!
        static let pointY   = CGEventField(rawValue: 96)!
        static let pointX   = CGEventField(rawValue: 97)!
        static let phase    = CGEventField(rawValue: 99)!
        static let momentum = CGEventField(rawValue: 123)!
        static let cont     = CGEventField(rawValue: 88)!
        static let userData = CGEventField(rawValue: 42)!
        static let stateID  = CGEventField(rawValue: 45)!
        static let procID   = CGEventField(rawValue: 41)!
        static let buttonNo = CGEventField(rawValue: 3)!
        static let dX       = CGEventField(rawValue: 4)!
        static let dY       = CGEventField(rawValue: 5)!
    }

    private static let magic: Int64 = 0x5A5A_534D

    private var axisY = ScrollAxis()
    private var axisX = ScrollAxis()
    private var pointerRemX = 0.0
    private var pointerRemY = 0.0
    private var lastFrameTime: Double = 0

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var displayLink: CVDisplayLink?
    private let lock = NSLock()

    /// 失控保护：统计每秒投递像素量，异常时直接清空队列
    private var secondStart: Double = 0
    private var postedThisSecond: Double = 0
    private(set) var echoGuardCount: Int64 = 0

    private var config = StoredState()
    private var activeAppID: String?
    /// profile(for:) 的帧循环缓存：字典查找 + masterEnabled / enabled 链每帧都要跑，
    /// 120Hz 下每秒几百次。这个结果只在 apply()（配置变更）和 setActiveApp()（App 切换）
    /// 两个低频事件里才会变，在两处失效重建即可。
    private var cachedProfile: ScrollProfile?

    private var trustTimer: DispatchSourceTimer?
    // triggerOnMouseUp 模式下，已吞掉 DOWN 的按钮集合；
    // UP 到来时执行动作并同样吞掉，避免残留半边事件触发系统默认行为。
    private var suppressedButtons: Set<Int> = []

    // MARK: - 生命周期

    func apply(_ state: StoredState) {
        lock.lock(); defer { lock.unlock() }
        config = state
        cachedProfile = config.profile(for: activeAppID)
        // 配置热更新后重置亚像素累积，避免倍率切换瞬间出现一次跳变
        pointerRemX = 0
        pointerRemY = 0
        // 触发时机开关切换时清掉残留的半边按钮状态，否则某个键会卡在
        // 「DOWN 已吞、UP 不再认」的状态里直到重启
        suppressedButtons.removeAll()
    }

    func setActiveApp(_ id: String?) {
        lock.lock(); defer { lock.unlock() }
        activeAppID = id
        cachedProfile = config.profile(for: activeAppID)
    }

    func install(initial state: StoredState) {
        apply(state)
        ensureTap()
        ensureDisplayLink()
        // 常驻信任监测：授权被撤销时停 tap，恢复后自动重建（myMouseMagic 的
        // PermissionsService 模式：Revoked→stop，Granted→start）。
        startTrustPolling()
    }

    func stop() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.tap = nil
        }
        trustTimer?.cancel()
        trustTimer = nil
    }

    static func trusted(prompt: Bool) -> Bool {
        if prompt {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            return AXIsProcessTrustedWithOptions(opts)
        }
        return AXIsProcessTrusted()
    }

    // MARK: - 事件拦截

    private func ensureTap() {
        guard tap == nil else { return }
        // 不在这里触发系统弹窗：授权引导统一走 App 启动时的 Onboarding（只弹一次），
        // 未授权时由 startTrustPolling 每秒静默检测，检测到授权后自动装 tap。
        guard Self.trusted(prompt: false) else {
            startTrustPolling()
            return
        }
        let mask: CGEventMask = (1 << CGEventType.scrollWheel.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)
            | (1 << CGEventType.mouseMoved.rawValue)

        guard let port = CGEvent.tapCreate(tap: .cghidEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                                              guard let refcon else { return Unmanaged.passUnretained(event) }
                                              let engine = Unmanaged<ScrollEngine>.fromOpaque(refcon).takeUnretainedValue()
                                              return engine.handle(type: type, event: event)
                                          },
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            startTrustPolling()
            return
        }
        tap = port
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { return }
        runLoopSource = source
        Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }.start()
    }

    private func startTrustPolling() {
        guard trustTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        t.schedule(deadline: .now(), repeating: 1.0)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if Self.trusted(prompt: false) {
                if self.tap == nil {
                    // 授权后（重）装 tap；已装则无事可做
                    self.ensureTap()
                }
            } else if self.tap != nil {
                // 权限被系统撤销（myMouseMagic PermissionsService 的 Revoked 分支）：
                // 主动停 tap，避免带着无效 port 跑空转；恢复授权后由上面分支重建。
                self.stopTapOnly()
            }
        }
        trustTimer = t
        t.resume()
    }

    private func stopTapOnly() {
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.tap = nil
        }
        if let source = runLoopSource {
            // invalidate 可跨线程调用，source 解绑后 runloop 无源自动退出
            CFRunLoopSourceInvalidate(source)
        }
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if isSynthetic(event) { return Unmanaged.passUnretained(event) }

        switch type {
        case .scrollWheel:
            return handleWheel(event)
        case .otherMouseDown, .otherMouseUp:
            return handleButton(type: type, event: event)
        case .mouseMoved:
            return handlePointerMove(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - 指针速度

    private func handlePointerMove(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        lock.lock()
        let speedManaged = config.pointerSpeedManaged
        let factor = config.pointerSpeedFactor
        // 前台 App 用缓存，不在 tap 回调里查 NSWorkspace：
        // NSWorkspace.shared.frontmostApplication 是一次跨进程同步查询，
        // 而 mouseMoved 在 120Hz 屏上每秒能来几百次 —— 每次都查会直接把指针延迟顶上去
        // （2026-10-26 审核发现的 P1）。activeAppID 由 AppDelegate 监听
        // didActivateApplicationNotification 维护，tap 里只读不查。
        // Dock / MenuBar 等 UI 对 hover 判定很敏感：改写后的 delta 会丢失
        // 原始相对运动语义，导致图标不再放大。因此这些窗口在前台时不改写。
        let front = activeAppID
        if front == "com.apple.dock" || front == "com.apple.finder" {
            lock.unlock()
            return Unmanaged.passUnretained(event)
        }

        // 只在真的需要改速度时才改写 delta。接管加速度交给 IOHID 层
        // （PointerController 已把硬件加速度写成 0），这里不再吞事件重投，
        // 否则会造成 Dock 图标粘住等 UI 异常。
        let needRewrite = speedManaged && abs(factor - 1.0) > 0.0001
        guard needRewrite else {
            lock.unlock()
            return Unmanaged.passUnretained(event)
        }

        // rem 累积全程持锁：apply() 会在主线程锁内重置 rem，
        // 这里若先解锁再读写就是数据竞争（HANDOFF §7 挂了很久的「轻微」问题，
        // 实际是原 228-233 行整段无锁）。
        let inX = Double(event.getIntegerValueField(F.dX))
        let inY = Double(event.getIntegerValueField(F.dY))
        let scale = speedManaged ? max(0.05, factor) : 1.0

        pointerRemX += inX * scale
        pointerRemY += inY * scale
        let outX = pointerRemX.rounded(.towardZero)
        let outY = pointerRemY.rounded(.towardZero)
        pointerRemX -= outX
        pointerRemY -= outY
        lock.unlock()
        event.setIntegerValueField(F.dX, value: Int64(outX))
        event.setIntegerValueField(F.dY, value: Int64(outY))
        // 原地改写后放行，而不是吞掉再合成新事件。
        // 合成事件会被部分 UI（尤其是 Dock）当作异常输入，造成图标粘住。
        return Unmanaged.passUnretained(event)
    }

    private func isSynthetic(_ event: CGEvent) -> Bool {
        var hit = event.getIntegerValueField(F.userData) == Self.magic
            || event.getIntegerValueField(F.procID) == Int64(getpid())
        if !hit, let sid = thePrivateSourceStateID, event.getIntegerValueField(F.stateID) == sid { hit = true }
        if hit { echoGuardCount += 1 }
        return hit
    }

    private lazy var thePrivateSourceStateID: Int64? = {
        guard let s = CGEventSource(stateID: .privateState) else { return nil }
        return Int64(s.sourceStateID.rawValue)
    }()

    // MARK: - 滚轮

    private func handleWheel(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        // 触控板 / Magic Mouse 产生的连续滚动
        let continuous = event.getIntegerValueField(F.cont) != 0
            || event.getIntegerValueField(F.phase) != 0
            || event.getIntegerValueField(F.momentum) != 0

        // 取值策略：
        //  · 触控板/连续设备 → fixedPt 本身就是像素（16.16），保留亚像素精度
        //  · 滚轮鼠标 → pointDelta，即系统自己做的 line→pixel 换算，保证不同鼠标的"每格"语义一致
        let rawY = Self.raw(of: event, fixed: F.fixedY, point: F.pointY, line: F.lineY, continuous: continuous)
        let rawX = Self.raw(of: event, fixed: F.fixedX, point: F.pointX, line: F.lineX, continuous: continuous)

        lock.lock()
        guard let profile = cachedProfile else {
            lock.unlock()
            publishMonitor(rawY: rawY, continuous: continuous, handled: false)
            return Unmanaged.passUnretained(event)
        }
        if continuous && config.ignoreTrackpad {
            lock.unlock()
            publishMonitor(rawY: rawY, continuous: continuous, handled: false)
            return Unmanaged.passUnretained(event)
        }
        // 修饰键透传：按住时不对该次滚动做任何接管（精确操作场景）
        if profile.bypassModifiers != 0,
           (event.flags.rawValue & profile.bypassModifiers) != 0 {
            lock.unlock()
            publishMonitor(rawY: rawY, continuous: continuous, handled: false)
            return Unmanaged.passUnretained(event)
        }
        let pureForward = !profile.smoothVertical && !profile.smoothHorizontal
            && !profile.reverseVertical && !profile.reverseHorizontal
        if pureForward {
            lock.unlock()
            return Unmanaged.passUnretained(event)
        }

        // 滚轮行数（只对滚轮鼠标的离散格生效；触控板/Magic Mouse 连续滚动不受影响）
        let lineScale = continuous ? 1.0 : max(0.05, profile.wheelLines)
        let scaledY = rawY * lineScale
        let scaledX = rawX * lineScale

        if profile.smoothVertical {
            axisY.push(prepare(scaledY, profile: profile, reverse: profile.reverseVertical, continuous: continuous))
        } else {
            // 该轴不做平滑：直接跳到目标位置，下一帧立即投递
            axisY.jump(prepare(scaledY, profile: profile, reverse: profile.reverseVertical, continuous: continuous))
        }
        if profile.smoothHorizontal {
            axisX.push(prepare(scaledX, profile: profile, reverse: profile.reverseHorizontal, continuous: continuous))
        } else {
            axisX.jump(prepare(scaledX, profile: profile, reverse: profile.reverseHorizontal, continuous: continuous))
        }
        lock.unlock()

        publishMonitor(rawY: rawY, continuous: continuous, handled: true)
        return nil
    }

    private static func raw(of event: CGEvent,
                            fixed: CGEventField,
                            point: CGEventField,
                            line: CGEventField,
                            continuous: Bool) -> Double {
        if continuous {
            let f = event.getDoubleValueField(fixed)
            if f != 0 { return f }
            return Double(event.getIntegerValueField(point))
        }
        let p = Double(event.getIntegerValueField(point))
        if p != 0 { return p }
        let f = event.getDoubleValueField(fixed)
        if f != 0 { return f }
        return Double(event.getIntegerValueField(line)) * 10.0
    }

    /// 量化 + 反向 + 距离倍率
    private func prepare(_ raw: Double, profile: ScrollProfile, reverse: Bool, continuous: Bool = false) -> Double {
        guard raw != 0 else { return 0 }
        var v = raw
        // 最小步长只对离散滚轮生效：触控板/Magic Mouse 的连续滚动本身有亚像素精度，
        // 强制放大反而会让轻扫变得一卡一卡（对齐 BTT 对连续输入的处理）
        if !continuous {
            let step = max(0, profile.minStep)
            if step > 0 && abs(v) < step {
                v = (v > 0 ? step : -step)
            }
        }
        if reverse { v = -v }
        return v * max(0.05, profile.speed)
    }

    // MARK: - 按键

    private func handleButton(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let button = Int(event.getIntegerValueField(F.buttonNo))
        lock.lock()
        var btn = button
        // 交换后/前侧键（myMouseMagic 的 Swap Back/Forward）
        if config.swapBackForward {
            if btn == 4 { btn = 5 } else if btn == 5 { btn = 4 }
        }
        let table = config.bindings(for: activeAppID)
        let raw = table[String(btn)]
        let isUp = (type == .otherMouseUp)
        // 触发时机：默认按下触发；开启 triggerOnMouseUp 时抬起才触发
        var shouldTrigger = config.triggerOnMouseUp ? isUp : !isUp
        if config.triggerOnMouseUp {
            if isUp {
                // 只放行我们曾抑制过 DOWN 的那次 UP：保证 DOWN/UP 成对吞掉
                if suppressedButtons.contains(btn) {
                    suppressedButtons.remove(btn)
                } else {
                    shouldTrigger = false
                }
            } else if let rawAction = raw, let a = ButtonAction(rawValue: rawAction), a != .none {
                // 抑制 DOWN，等待 UP 到来时成对结算。
                // 必须先确认这个键真的绑了动作：早先这里是无条件吞 DOWN，
                // 结果未绑定的侧键变成「系统只收到 UP 收不到 DOWN」，浏览器前进/后退
                // 等原生侧键功能直接失效（2026-10-26 审核发现的 P1）。
                suppressedButtons.insert(btn)
                lock.unlock()
                return nil
            } else {
                // 没绑动作 → 原样放行，把按键完整交还系统
                lock.unlock()
                return Unmanaged.passUnretained(event)
            }
        }
        lock.unlock()
        guard shouldTrigger,
              let rawAction = raw, let action = ButtonAction(rawValue: rawAction), action != .none else {
            return Unmanaged.passUnretained(event)
        }
        DispatchQueue.main.async { ActionRunner.run(action) }
        return nil
    }

    // MARK: - 帧驱动插值

    private func ensureDisplayLink() {
        guard displayLink == nil else { return }
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }
        self.displayLink = link
        CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, outTime, _, _ in
            guard let self else { return kCVReturnSuccess }
            let scale = Int64(outTime.pointee.videoTimeScale)
            let time = Double(outTime.pointee.videoTime) / Double(max(1, scale))
            self.frame(at: time)
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(link)
    }

    private func frame(at hostTime: Double) {
        lock.lock()
        guard let profile = cachedProfile else {
            // 不拦截时保持状态干净
            axisY.reset()
            axisX.reset()
            lastFrameTime = hostTime
            lock.unlock()
            return
        }
        let dt = lastFrameTime == 0 ? 1.0 / 120.0 : min(0.05, max(0.0005, hostTime - lastFrameTime))
        lastFrameTime = hostTime

        let tauY = profile.smoothVertical ? profile.tau : 0
        let tauX = profile.smoothHorizontal ? profile.tau : 0
        let dy = axisY.advance(dt: dt, tau: tauY)
        let dx = axisX.advance(dt: dt, tau: tauX)
        lock.unlock()

        if dy != 0 || dx != 0 {
            post(dy: dy, dx: dx)
        }
    }

    private func post(dy: Int32, dx: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        event.setIntegerValueField(F.userData, value: Self.magic)
        event.setIntegerValueField(F.cont, value: 0)
        // 显式打时间戳（ns since startup）：合成事件不带 timestamp 时，
        // 消费端（游戏 / 高帧率 App 的动量计算）拿到的是 0 或不可信值，平滑会抖
        event.timestamp = CGEventTimestamp(CACurrentMediaTime() * 1_000_000_000)

        // 一秒内投递超过 ~40000px 视为回环失控，清空状态
        if secondStart == 0 { secondStart = CACurrentMediaTime() }
        postedThisSecond += Double(abs(dy)) + Double(abs(dx))
        let now = CACurrentMediaTime()
        if now - secondStart > 1.0 {
            secondStart = now
            postedThisSecond = 0
        } else if postedThisSecond > 40000 {
            axisY.reset()
            axisX.reset()
            postedThisSecond = 0
        }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - 调试监视器

    private var lastPush = Date.distantPast

    private func publishMonitor(rawY: Double, continuous: Bool, handled: Bool) {
        let now = Date()
        if now.timeIntervalSince(lastPush) < 0.25 { return }
        lastPush = now
        DispatchQueue.main.async {
            Monitor.shared.rawDelta = rawY
            Monitor.shared.isContinuous = continuous
            Monitor.shared.handled = handled
        }
    }
}

/// 实时状态（仅用于界面展示）
final class Monitor: ObservableObject {
    static let shared = Monitor()
    @Published var rawDelta: Double = 0
    @Published var isContinuous: Bool = false
    @Published var handled: Bool = false

    var sourceName: String {
        isContinuous ? "触控板 / Magic Mouse" : "滚轮鼠标"
    }
}

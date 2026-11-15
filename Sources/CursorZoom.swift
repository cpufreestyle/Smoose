import AppKit
import ApplicationServices
import Combine
import Foundation

/// 光标放大开关：控制系统「摇动鼠标指针以定位」
/// （快速来回移动鼠标指针时，光标图标放大，方便定位）。
///
/// 系统设置位置：系统设置 → 辅助功能 → 显示 → 摇动鼠标指针以定位。
/// 偏好键是 `.GlobalPreferences` 的 `CGDisableCursorLocationMagnification`，
/// 键名带 Disable，语义是反的：功能开 → false(0)，功能关 → true(1)。
///
/// **2026-11-07 修正「开启不生效」（不是键写错，是假绿）**：
/// 真机实测：系统设置里点这个开关时，全局域只有这一个键变化，GUI 同步变色；
/// 但第三方只写 plist 后，**系统设置 GUI 不刷新、切页重进也不刷新** ——
/// macOS 的 WindowServer 只在登录会话启动时加载这个偏好，
/// 社区资料（El Capitan 起）也一致：改完要注销 / 重新登录才生效。
/// 所以「写成功」≠「功能已生效」。旧实现 `apply()` 写完就返回、Toggle 立刻变蓝，
/// 既没有读回校验，也没有任何生效条件提示 —— 是典型的假绿。
///
/// 契约（不可回退）：
/// 1. 写后必须**独立读回**（`CFPreferencesCopyValue`，走 cfprefsd，不用进程内缓存）；
///    读不到 / 不一致都判失败，绝不能算「已开启」。
/// 2. 写入成功也必须明确标注「待重新登录生效」，不得写「已生效 / 立即生效」。
/// 3. 给出唯一能立刻生效的可操作路径：到系统设置里把开关关一次再打开。
/// 4. 写失败时开关回弹 + 带具体原因的红字 + 重试。
final class CursorZoomController {
    static let shared = CursorZoomController()

    static let key = "CGDisableCursorLocationMagnification"
    static let domain = ".GlobalPreferences"

    private var defaults: UserDefaults? {
        UserDefaults(suiteName: Self.domain)
    }

    /// 从 cfprefsd 读回**落盘后的**值：刻意不用 `defaults?.object(forKey:)`，
    /// 那是同一进程的缓存，写完立刻读必然是刚写的值 —— 又是假绿。
    private func readBack() -> Bool? {
        guard let raw = CFPreferencesCopyValue(
            Self.key as CFString,
            Self.domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) else { return nil }
        return (raw as? NSNumber)?.boolValue
    }

    /// 系统偏好里这个功能是否为开（注意：只是偏好值，不代表本次会话已生效）。
    var systemEnabled: Bool {
        CursorZoomPolicy.systemEnabled(stored: readBack())
    }

    /// 写入并校验。返回结果必须被 UI 使用；不允许「调用即成功」。
    func apply(_ enabled: Bool) -> CursorZoomApplyResult {
        guard let d = defaults else { return .suiteUnavailable }
        let expected = CursorZoomPolicy.storedValue(enabled: enabled)
        d.set(expected, forKey: Self.key)
        let writeOK = d.synchronize()
        return CursorZoomPolicy.verdict(
            writeOK: writeOK,
            readBack: readBack(),
            expected: expected
        )
    }
}

/// 写入结果分类：「写成功但还没生效」是独立一类，不能并进笼统的 success。
enum CursorZoomApplyResult: Equatable {
    /// 写入 + 读回一致；但 macOS 需重新登录（或由系统设置应用一次）才加载。
    case writtenPendingRelogin
    case suiteUnavailable
    case writeFailed
    /// 带期望值与实际读回值，断言能表达「为什么失败」。
    case readBackMismatch(expected: Bool, actual: Bool?)

    /// 只有这一类允许把开关留在用户选中的状态；其它都要回弹。
    var ok: Bool {
        if case .writtenPendingRelogin = self { return true }
        return false
    }
}

// MARK: - 会话级即时生效（2026-11-07 真机验证，不注销）

/// 为什么需要这一层：macOS 的 WindowServer 只在登录会话启动时读取
/// `CGDisableCursorLocationMagnification`，第三方写 plist 不改变运行中的会话
/// （Apple 开发者论坛 / Jamf 社区结论一致）。于是会出现「开关显示关、plist 也是关，
/// 但鼠标还在放大」—— 单一布尔开关表达不了这件事，是典型的假绿。
///
/// 真机实测（macOS 27.3）：系统设置 GUI 拨动「摇动鼠标指针以定位」时，
/// AXPress 会让 System Settings 同步改写 plist（1→0→1），说明它走的是系统写入通道
/// 并触发重载。Smoose 已持有 kTCCServiceAccessibility，可用 AXUIElement 代替用户完成。
/// 探针：Probe/AXCursorZoomProbe.swift（dump / toggle，含终态反向校验）。
///
/// **2026-11-09 修正「开启方向不生效」**：旧实现把终态写死为「关」（AXValue=0 / plist=1），
/// 于是用户打开功能后点「立即生效」，系统反被拨回关，文案还写「确认光标不再放大」；
/// 同时设置页 `.onAppear` 用系统值覆盖用户刚选的开关，看起来就是「打开了却没生效」。
/// 现在终态一律由用户当前开关（`desiredEnabled`）决定，开与关都走同一套硬门槛校验。

/// 同步结果。每个失败分支都必须带具体原因，禁止笼统的「失败」二字。
enum CursorZoomSyncResult: Equatable {
    /// 系统已按目标状态重新加载；但「光标是否放大」程序观测不到，须由用户确认。
    /// enabled 必须随目标状态走：开启方向绝不能套用「确认不再放大」的关闭文案。
    case applied(enabled: Bool)
    case notTrusted
    case launchFailed(String)
    case targetNotFound
    case pressFailed(Int32)
    /// 拨了但值没变 —— 防「AXPress 返回 0 就假绿」。
    case pressNoEffect(before: String, after: String)
    /// 终态没回到关，或落盘值不是禁用；绝不宣称生效。
    case finalStateMismatch(ax: String, stored: String)

    var ok: Bool {
        if case .applied = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .applied(let enabled):
            let expect = enabled ? "光标会变大" : "光标不再放大"
            return "已让系统按「\(enabled ? "开启" : "关闭")」重新加载设置 ✓ 请摇动鼠标确认\(expect)（画面效果程序无法代你观测）。"
        case .notTrusted:
            return "缺少辅助功能授权：请到 系统设置 → 隐私与安全性 → 辅助功能 勾选 Smoose 后重试。"
        case .launchFailed(let reason):
            return "打开系统设置失败（\(reason)）。请手动打开后重试。"
        case .targetNotFound:
            return "没找到「摇动鼠标指针以定位」开关：请停留在 辅助功能 → 显示 页后重试。"
        case .pressFailed(let code):
            return "操作系统设置开关失败（AXPress \(code)）。请重试或手动把该开关关一次再打开。"
        case .pressNoEffect(let before, let after):
            return "开关没有响应（拨动前后同为 \(before)/\(after)），未宣称生效。请手动到 系统设置 → 辅助功能 → 显示 操作。"
        case .finalStateMismatch(let ax, let stored):
            return "终态校验失败：开关=\(ax)、系统偏好=\(stored)。未宣称生效，请检查后重试。"
        }
    }
}

/// 纯逻辑判定，供 harness 离线断言 + 反向验证（构造负例必须变红）。
enum CursorZoomSyncPolicy {
    /// 系统设置「显示」页里那个开关的稳定 AXIdentifier（真机实测）。
    static let targetIdentifier = "AX_FIND_CURSOR"

    /// 目标状态对应的 AXValue 与落盘值（反相键）。开与关共用同一套判定，
    /// 禁止把「关」写死成唯一终态 —— 那会把用户刚打开的功能拨回去。
    static func desiredAX(_ enabled: Bool) -> String { enabled ? "1" : "0" }
    static func desiredStored(_ enabled: Bool) -> String { enabled ? "0" : "1" }

    /// 已是目标态时必须「离开再回来」拨两次才能强制系统重写一次；
    /// 不是目标态时拨一次即到位。抽成纯函数，让 harness 能直接断言两个方向。
    static func needsDoublePress(before: String?, desiredEnabled: Bool) -> Bool {
        before == desiredAX(desiredEnabled)
    }

    /// - before/afterFirst/afterFinal：开关的 AXValue（"0"=关 / "1"=开）
    /// - press2Needed：当前已是目标态时需拨两次（离开再回来）强制系统重写一次
    /// - stored：落盘的 CGDisableCursorLocationMagnification（"1"=禁用 / "0"=启用）
    /// - desiredEnabled：用户当前开关的目标状态，决定终态校验的方向
    ///
    /// 四条硬门槛，缺一不算成功：两次 AXPress 都成功、拨动后值确实变了、
    /// 终态等于目标态、落盘值等于目标态的反相值。
    static func verdict(before: String?, afterFirst: String?, afterFinal: String?,
                        press1Code: Int32, press2Needed: Bool, press2Code: Int32,
                        stored: String?, desiredEnabled: Bool) -> CursorZoomSyncResult {
        guard let before, let afterFirst, let afterFinal, let stored else {
            return .finalStateMismatch(ax: afterFinal ?? "读不到", stored: stored ?? "读不到")
        }
        guard press1Code == 0 else { return .pressFailed(press1Code) }
        if press2Needed && press2Code != 0 { return .pressFailed(press2Code) }
        guard afterFirst != before else {
            return .pressNoEffect(before: before, after: afterFirst)
        }
        guard afterFinal == desiredAX(desiredEnabled) else {
            return .finalStateMismatch(ax: afterFinal, stored: stored)
        }
        guard stored == desiredStored(desiredEnabled) else {
            return .finalStateMismatch(ax: afterFinal, stored: stored)
        }
        return .applied(enabled: desiredEnabled)
    }
}

// MARK: - 调度加固（2026-11-10：冷启动 / 重入 / 首压 / 落盘 / 焦点）

extension CursorZoomSyncPolicy {
    /// 系统设置第一次被拉起时，AX 树实测可能要 ~20 秒才出现 AX_FIND_CURSOR；
    /// 进程本来就在跑时通常 2~3 秒即可。轮询次数固定 16 次不变，只按「打开前
    /// 系统设置是否已经在运行」分配每次的等待间隔，避免冷启动必然假失败。
    static let pollAttempts = 16
    static func isColdLaunch(systemSettingsRunning: Bool) -> Bool { !systemSettingsRunning }
    static func pollDelaysMilliseconds(coldLaunch: Bool) -> [Int] {
        Array(repeating: coldLaunch ? 1600 : 250, count: pollAttempts)
    }

    /// 只有首压确实把开关拨离了原值，才允许「离开再回来」的第二压。
    /// 首压无响应（AXPress 非 0 或值没变）时再按一下，会把开关留在非目标态、
    /// 系统偏好也被写成反相，而 UI 只回一句失败 —— 必须禁止。
    static func shouldPerformSecondPress(press1Code: Int32, before: String?,
                                         afterFirst: String?, needsDoublePress: Bool) -> Bool {
        guard needsDoublePress, press1Code == 0,
              let before, let afterFirst, afterFirst != before else { return false }
        return true
    }

    /// 系统设置在 AXPress 后异步写盘，300ms 时读到的可能还是旧值。
    /// 最多再等 8×125ms，读到目标态就提前结束；没等到也不得宣称成功（verdict 照旧判）。
    static let storedPollAttempts = 8
    static let storedPollDelayMilliseconds = 125
    static func shouldKeepWaitingForStored(stored: String?, desired: String, attempt: Int) -> Bool {
        guard attempt < storedPollAttempts else { return false }
        return stored != desired
    }

    /// 只有前台仍是我们打开的系统设置时才把用户拽回原 App。
    /// 冷启动最长可跑 25 秒，期间用户主动切到别的应用，无条件 activate 会把人硬拉回来。
    static let systemSettingsBundleID = "com.apple.systempreferences"
    static func shouldRestoreFocus(currentFrontBundleID: String?) -> Bool {
        currentFrontBundleID == systemSettingsBundleID
    }
}

/// 串行队列：正在跑时又来了新目标，不取消、不丢弃，记下「最后一次」，
/// 当前跑完后再补一次。取消已开始的 AX 操作只会留下半截状态，
/// 直接跳过又会让最后一次开关方向丢失（两个方向都要真的生效）。
struct CursorZoomSyncQueue {
    private(set) var isRunning = false
    private(set) var queued: Bool?

    /// 返回本次应立即执行的目标；nil 表示已排队，等当前跑完补跑。
    mutating func submit(_ desired: Bool) -> Bool? {
        if isRunning {
            queued = desired
            return nil
        }
        isRunning = true
        return desired
    }

    /// 当前任务结束：返回要补跑的目标；nil 表示队列已空。
    mutating func finish() -> Bool? {
        let next = queued
        queued = nil
        if next == nil { isRunning = false }
        return next
    }
}

// MARK: - 自动重载（2026-11-09：拨完开关不再手动点按钮）

/// 为什么单独抽策略：自动路径和手动按钮必须走**同一套**四条硬门槛，
/// 不能因为「自动」就跳过终态校验、失败提示或用户确认。
/// 自动触发只在「写盘成功」时发生；写入失败时开关会回弹，
/// 若此时还去拨系统设置，等于把系统拨到没有用户意图的方向 —— 必须禁止。
enum CursorZoomAutoSyncPolicy {
    /// 连续拨开关只跑最后一次。0 会变成拨一次抢一次焦点，太长又让「拨完立刻摇鼠标」扑空。
    static let debounceMilliseconds = 600

    /// 只有写盘成功才自动重载。绝不能加「方向变了才跑」这个条件：prefs 是本地缓存，
    /// 可能与系统真值不一致，用户拨到「看起来没变」的值恰恰是会话滞后最需要重载的一次。
    /// 连续拨动由 debounce 合并，不会重复抢焦点。
    static func shouldTrigger(writeOK: Bool) -> Bool { writeOK }

    /// ledger 只表达「上次成功触发的重载是哪个方向」，不推断系统当前画面状态。
    enum LedgerDisplay: Equatable {
        case never
        case upToDate(enabled: Bool)
        case stale(previous: Bool, desired: Bool)
    }

    static func display(ledgerEnabled: Bool?, desired: Bool) -> LedgerDisplay {
        guard let ledgerEnabled else { return .never }
        return ledgerEnabled == desired
            ? .upToDate(enabled: desired)
            : .stale(previous: ledgerEnabled, desired: desired)
    }

    /// 旧文案「本次会话：尚未重载」在重启 App 后必然出现，暗示系统状态回退了 ——
    /// 其实是 App 自己没记录。改成陈述「做过什么动作」，且仍不替用户宣称画面效果。
    static func ledgerMessage(_ d: LedgerDisplay, timeText: String = "") -> String {
        switch d {
        case .never:
            return "还没让系统重新加载过：改开关后会自动执行，也可点「立即生效」手动触发。"
        case .upToDate(let enabled):
            let when = timeText.isEmpty ? "上次" : "上次在 \(timeText) "
            return "\(when)已让系统按「\(enabled ? "开启" : "关闭")」重新加载；同一登录会话内无需重复点，画面效果仍需你自己确认。如手感不符可再点一次。"
        case .stale(let previous, let desired):
            return "开关已改为「\(desired ? "开启" : "关闭")」，上次重载记录是「\(previous ? "开启" : "关闭")」：正在自动让系统追平（会打开系统设置再回到原应用，首次冷启动可能要十几秒）；若未触发请点「立即生效」。"
        }
    }

    /// 失败结果绝不记进 ledger，否则重启后会显示「已按目标态重载」= 假绿。
    static func shouldRecord(_ result: CursorZoomSyncResult) -> Bool { result.ok }
}

/// 只记录「我们确实成功触发过一次会话重载」这个动作与目标方向；
/// 不记录、也不推断画面效果（那只有用户能观测）。
final class CursorZoomSyncLedger {
    static let shared = CursorZoomSyncLedger()
    private static let key = "smoose.zoom.lastSync"
    private static let domain = "app.smoose.macos"

    struct Record: Equatable {
        let enabled: Bool
        let at: Double
    }

    /// 从 cfprefsd 独立读回，刻意不用 UserDefaults 的进程内缓存（写完立刻读必然是新值 = 假绿）。
    private func readBack() -> Record? {
        guard let raw = CFPreferencesCopyValue(
            Self.key as CFString,
            Self.domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String: Any],
        let enabled = raw["enabled"] as? Bool,
        let at = raw["at"] as? Double else { return nil }
        return Record(enabled: enabled, at: at)
    }

    func current() -> Record? { readBack() }

    /// 写后必须独立读回一致才算记录成功；失败时调用方回退到「never」，不假装已记录。
    @discardableResult
    func record(enabled: Bool, at: Double = Date().timeIntervalSince1970) -> Bool {
        let payload: [String: Any] = ["enabled": enabled, "at": at]
        UserDefaults.standard.set(payload, forKey: Self.key)
        UserDefaults.standard.synchronize()
        return readBack() == Record(enabled: enabled, at: at)
    }
}

/// 用 Smoose 已有的辅助功能授权，拨动系统设置里的开关触发重载。
/// 只读遍历 + 两次 AXPress，终态严格校验；任何异常都如实返回，不假装生效。
///
/// 调度与状态放在单例而非 View 的 @State：切标签页 / 设置窗关闭时自动重载仍要跑完，
/// 且 UI 通过 @Published 直接观察，不靠 completion 闭包（避免 View 销毁后的静默丢结果）。
final class CursorZoomSessionSync: ObservableObject {
    static let shared = CursorZoomSessionSync()

    /// 本次 App 运行内最后一次同步结果（失败原因 / 成功方向都从这里显示）。
    @Published private(set) var lastResult: CursorZoomSyncResult?
    /// 上次成功重载的目标方向与时间戳（重启 App 仍在，消除「尚未重载」的假提示）。
    @Published private(set) var ledgerEnabled: Bool?
    @Published private(set) var ledgerAt: Double?
    /// ledger 写盘失败是「显示问题」，不能伪装成记录成功，也不能把已成功的重载判红。
    @Published private(set) var ledgerWriteOk = true

    /// 只追踪「尚未开始执行」的防抖等待；已经进 perform 的任务绝不 cancel。
    private var debounceTask: Task<Void, Never>?
    private var queue = CursorZoomSyncQueue()

    private init() { reloadLedger() }

    func reloadLedger() {
        let r = CursorZoomSyncLedger.shared.current()
        ledgerEnabled = r?.enabled
        ledgerAt = r?.at
    }

    /// 开关变化后自动跑：防抖合并连拨；清掉上次结果让状态区显示「正在追平」。
    /// 防抖任务与「已经在跑的 AX 操作」分开追踪：只取消尚未开始的等待，
    /// 绝不 cancel 已进 perform 的任务（同步 AX 调用取消不了，只会留下半截状态）。
    func scheduleAuto(desiredEnabled: Bool) {
        debounceTask?.cancel()
        lastResult = nil
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(CursorZoomAutoSyncPolicy.debounceMilliseconds))
            guard !Task.isCancelled else { return }
            await self.enqueue(desiredEnabled: desiredEnabled)
        }
    }

    /// 手动按钮：立刻跑，并取消待执行的自动任务，避免同一次改动被拨两遍。
    /// 已经在跑的任务不取消，交给队列串行补跑最后一次目标。
    func runNow(desiredEnabled: Bool) {
        debounceTask?.cancel()
        Task { @MainActor in
            await self.enqueue(desiredEnabled: desiredEnabled)
        }
    }

    /// 串行执行：正在跑时又来的目标只记最后一次，跑完再补一次。
    /// 「跳过」会让最后一次开关方向丢失，「并发」会让两次 AXPress 互相抵消 ——
    /// 两个方向都必须真的跑一次。
    @MainActor
    private func enqueue(desiredEnabled: Bool) async {
        guard let first = queue.submit(desiredEnabled) else { return }
        var desired = first
        while true {
            _ = await apply(desiredEnabled: desired)
            guard let next = queue.finish() else { break }
            desired = next
        }
    }

    private func attr(_ el: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, key as CFString, &value) == .success ? value : nil
    }
    private func str(_ el: AXUIElement, _ key: String) -> String? {
        guard let v = attr(el, key) else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return "\(n)" }
        return nil
    }
    private func storedString() -> String? {
        guard let raw = CFPreferencesCopyValue(
            CursorZoomController.key as CFString,
            CursorZoomController.domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) else { return nil }
        return (raw as? NSNumber)?.boolValue == true ? "1" : "0"
    }

    /// 在当前系统设置窗口里找 AX_FIND_CURSOR；找不到返回 nil（不猜、不点别的开关）。
    private func findTarget() -> AXUIElement? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.systempreferences"
        }) else { return nil }
        let root = AXUIElementCreateApplication(pid_t(app.processIdentifier))
        var visited = 0
        func walk(_ el: AXUIElement, _ depth: Int) -> AXUIElement? {
            if depth > 20 || visited > 60000 { return nil }
            visited += 1
            if str(el, "AXIdentifier") == CursorZoomSyncPolicy.targetIdentifier { return el }
            guard let children = attr(el, kAXChildrenAttribute) else { return nil }
            let array = unsafeBitCast(children, to: CFArray.self)
            for i in 0..<CFArrayGetCount(array) {
                let child = unsafeBitCast(CFArrayGetValueAtIndex(array, i), to: AXUIElement.self)
                if let hit = walk(child, depth + 1) { return hit }
            }
            return nil
        }
        guard let windows = attr(root, kAXWindowsAttribute) else { return nil }
        let array = unsafeBitCast(windows, to: CFArray.self)
        for i in 0..<CFArrayGetCount(array) {
            let win = unsafeBitCast(CFArrayGetValueAtIndex(array, i), to: AXUIElement.self)
            if let hit = walk(win, 0) { return hit }
        }
        return nil
    }

    /// 打开系统设置 → 辅助功能 → 显示，找到开关，拨一次或两次并校验终态。
    /// 终态由 `desiredEnabled` 决定：已是目标态就「离开再回来」强制系统重写一次，
    /// 不是目标态就拨一次直接到位。两种方向都走同一套终态校验。
    @MainActor
    func apply(desiredEnabled: Bool) async -> CursorZoomSyncResult {
        // 必须在 perform 之前取：perform 会打开系统设置并抢走前台，之后再读就只能读到它自己。
        // 真机实测（2026-11-09）：无条件 activate Smoose 并不总能成功，前台会掉到 Finder；
        // 改成「恢复拨开关前的前台应用」，正常场景下那就是 Smoose，切走了也不打扰用户。
        let previousFront = NSWorkspace.shared.frontmostApplication
        let result = await perform(desiredEnabled: desiredEnabled)
        lastResult = result
        // 只有四条硬门槛全过才写记录；失败不写，重启后不会显示假的「已重载」。
        if CursorZoomAutoSyncPolicy.shouldRecord(result) {
            ledgerWriteOk = CursorZoomSyncLedger.shared.record(enabled: desiredEnabled)
            reloadLedger()
        }
        restoreFocus(previousFront)
        return result
    }

    private func restoreFocus(_ app: NSRunningApplication?) {
        // 只在前台仍是系统设置时恢复：重载最长 25 秒，用户可能早已主动切走，
        // 无条件 activate 会把人硬拽回来（自动路径尤其意外）。
        guard CursorZoomSyncPolicy.shouldRestoreFocus(
            currentFrontBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) else { return }
        // 统一走 NSRunningApplication 的现代 API：真机实测 NSApp.activate(ignoringOtherApps:)
        // 在 macOS 27 并不可靠（前台会掉到 Finder）。对自己也走同一条路径。
        // 不主动关闭系统设置：那个窗口可能是用户原本就开着的，误杀比留在后台更糟。
        let target = app ?? NSRunningApplication.current
        _ = target.activate(options: [.activateAllWindows])
    }

    @MainActor
    private func perform(desiredEnabled: Bool) async -> CursorZoomSyncResult {
        guard AXIsProcessTrusted() else { return .notTrusted }
        // 必须在 open 之前取：open 会把系统设置拉起来，之后读永远是「已在运行」。
        let settingsRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == CursorZoomSyncPolicy.systemSettingsBundleID
        }
        switch await DisplaySettingsLauncher.open() {
        case .opened: break
        case .failed(let reason): return .launchFailed(reason)
        }

        // 页面是异步加载的：冷启动实测约 20 秒才出现 AX_FIND_CURSOR，
        // 原来固定 250ms×16=4 秒的开窗必现假失败。按进程是否冷启动分配间隔，
        // 次数不变、找不到就如实判失败，不许「没找到就当成功」。
        let delays = CursorZoomSyncPolicy.pollDelaysMilliseconds(
            coldLaunch: CursorZoomSyncPolicy.isColdLaunch(systemSettingsRunning: settingsRunning))
        var target: AXUIElement?
        var attempt = 0
        for _ in 0..<16 {
            if let found = findTarget() { target = found; break }
            try? await Task.sleep(for: .milliseconds(delays[attempt]))
            attempt += 1
        }
        guard let t = target else { return .targetNotFound }

        let before = str(t, kAXValueAttribute)
        let press2Needed = CursorZoomSyncPolicy.needsDoublePress(
            before: before, desiredEnabled: desiredEnabled)
        let r1 = AXUIElementPerformAction(t, kAXPressAction as CFString).rawValue
        try? await Task.sleep(for: .milliseconds(300))
        let afterFirst = str(t, kAXValueAttribute)

        var r2: Int32 = 0
        if CursorZoomSyncPolicy.shouldPerformSecondPress(
            press1Code: r1, before: before, afterFirst: afterFirst,
            needsDoublePress: press2Needed) {
            r2 = AXUIElementPerformAction(t, kAXPressAction as CFString).rawValue
            try? await Task.sleep(for: .milliseconds(300))
        }
        let afterFinal = str(t, kAXValueAttribute)

        // 系统设置写盘是异步的：AXPress 后 300ms 读回可能仍是旧值，
        // 短轮询等到目标态（最多 1 秒）。等不到也照旧交给 verdict 判，绝不因此放宽。
        let expectedStored = CursorZoomSyncPolicy.desiredStored(desiredEnabled)
        var waitAttempt = 0
        while CursorZoomSyncPolicy.shouldKeepWaitingForStored(
            stored: storedString(), desired: expectedStored, attempt: waitAttempt) {
            try? await Task.sleep(for: .milliseconds(CursorZoomSyncPolicy.storedPollDelayMilliseconds))
            waitAttempt += 1
        }

        return CursorZoomSyncPolicy.verdict(
            before: before, afterFirst: afterFirst, afterFinal: afterFinal,
            press1Code: r1, press2Needed: press2Needed,
            press2Code: r2, stored: storedString(), desiredEnabled: desiredEnabled
        )
    }
}

/// 纯逻辑，供 harness 离线断言（不碰 IOKit / cfprefsd 也能验证判定分支）。
enum CursorZoomPolicy {
    static let key = "CGDisableCursorLocationMagnification"
    static let domain = ".GlobalPreferences"

    /// 功能开 → 键 false；功能关 → 键 true。
    static func storedValue(enabled: Bool) -> Bool { !enabled }

    /// 键缺失时按系统默认：功能开启。
    static func systemEnabled(stored: Bool?) -> Bool {
        guard let stored else { return true }
        return !stored
    }

    /// 只有「写成功 + 独立读回等于期望」才算写入完成。
    /// 注意：即便返回 `.writtenPendingRelogin`，也**不代表功能已即时生效**。
    static func verdict(writeOK: Bool, readBack: Bool?, expected: Bool) -> CursorZoomApplyResult {
        guard writeOK else { return .writeFailed }
        guard let actual = readBack else {
            return .readBackMismatch(expected: expected, actual: nil)
        }
        return actual == expected
            ? .writtenPendingRelogin
            : .readBackMismatch(expected: expected, actual: actual)
    }

    /// 状态文案：成功必须同时说清「写好了」和「还没生效」，并给可操作路径；
    /// 失败必须带具体原因 + 重试。少一样就是假反馈。
    static func statusMessage(_ result: CursorZoomApplyResult) -> String {
        switch result {
        case .writtenPendingRelogin:
            return "已写入系统偏好 ✓ 但 macOS 只在登录时加载它，需重新登录才生效。"
                + "想立刻生效：点下面的按钮，让系统设置在本次会话按当前开关状态重新加载（无需注销）。"
        case .suiteUnavailable:
            return "写入失败：读不到系统全局偏好（.GlobalPreferences）。开关已回弹，请重试。"
        case .writeFailed:
            return "写入失败：系统偏好没有接受这次写入。开关已回弹，请重试。"
        case .readBackMismatch(let expected, let actual):
            let got = actual.map { $0 ? "true" : "false" } ?? "读不到"
            return "写入校验失败：期望 \(expected ? "true" : "false")，读回 \(got)。开关已回弹，请重试。"
        }
    }
}

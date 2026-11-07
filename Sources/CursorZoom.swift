import AppKit
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

    private static let key = "CGDisableCursorLocationMagnification"
    private static let domain = ".GlobalPreferences"

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
                + "想立刻生效：点下面的按钮，在系统设置里把这个开关关一次再打开。"
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

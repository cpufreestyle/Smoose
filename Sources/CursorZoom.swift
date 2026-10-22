import AppKit

/// 光标放大开关：控制系统「摇动鼠标指针以定位」
/// （快速来回移动鼠标指针时，光标图标放大，方便定位）。
///
/// 这是 macOS 自带功能，Smoose 只提供一个入口，不自己实现放大逻辑。
/// 系统设置位置：系统设置 → 辅助功能 → 显示 → 摇动鼠标指针以定位。
///
/// 偏好键是 `.GlobalPreferences` 的 `CGDisableCursorLocationMagnification`。
/// 注意键名带 Disable，语义是反的：
///   功能开 → 键 = false（0）
///   功能关 → 键 = true（1）
/// 映射关系已用 GUI 实测确认：勾选复选框 ↔ 键读数为 0。
///
/// **必须用 `UserDefaults(suiteName: ".GlobalPreferences")` 而不是 `UserDefaults.standard`。**
/// 实测（macOS 27）：`UserDefaults.standard.set` 对这个键只写进进程内缓存，不落盘——
/// `defaults read` 和 `plutil` 都看不到，系统永远收不到变更，开关表现为「没效果」。
/// 换成 suite 后写入立即落盘。
final class CursorZoomController {
    static let shared = CursorZoomController()

    private static let key = "CGDisableCursorLocationMagnification"
    private static let domain = ".GlobalPreferences"

    private var defaults: UserDefaults? {
        UserDefaults(suiteName: Self.domain)
    }

    /// 系统当前是否开启了放大
    var systemEnabled: Bool {
        guard let d = defaults else { return true }
        // 键缺失时按系统默认（默认开启）
        let v = d.object(forKey: Self.key)
        if v == nil { return true }
        return !(v as? Bool ?? true)
    }

    /// 把开关状态写入系统
    func apply(_ enabled: Bool) {
        guard let d = defaults else { return }
        d.set(!enabled, forKey: Self.key)
        d.synchronize()
        // 注意：这里不要调用 CGAssociateMouseAndMouseCursorPosition。
        // 实测传 0 会把鼠标和光标解绑，造成 Dock 图标被「粘住」等异常行为。
        // 系统对 CGDisableCursorLocationMagnification 的热更新路径目前不确认，
        // 需要重启 Smoose 或注销后才能保证生效。
    }
}

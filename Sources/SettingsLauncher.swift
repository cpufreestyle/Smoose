import AppKit

/// 系统设置跳转（2026-11-07 修正，macOS 27.3 真机实测）。
///
/// 两个独立的坑，别混为一谈：
/// 1. **落到错误页面**：旧地址
///    `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`
///    在新系统里打开的是「Device Control and Data Access」，不是辅助功能授权列表。
///    ExtensionKit 里真实的 pane 扩展 ID 是 `com.apple.settings.PrivacySecurity.extension`，
///    用它打开「隐私与安全性」，用户再点「辅助功能」即可勾选 Smoose。
/// 2. **进程卡死**：System Settings 长时间运行后可能不响应 AppleEvent，
///    LSOpenURLs 抛 -1712 并弹系统级英文框「not responding」。App 必须用
///    completionHandler 接住，如实给中文原因 + 重试路径，不能静默吞掉或假装成功。
enum AccessibilitySettingsLauncher {
    /// 新扩展 ID；`?privacy-accessibility` 在支持精确跳转的系统上生效，
    /// 在 macOS 27.3 上安全退化为「隐私与安全性」首页（实测 rc=0）。
    static let urlString =
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?privacy-accessibility"
    static let manualPath = "系统设置 → 隐私与安全性 → 辅助功能"

    enum Outcome: Equatable {
        case opened
        /// 必须带具体原因，不能是空的「失败」二字。
        case failed(String)
    }

    /// 只有「完全没有 error」才算成功。
    /// 空描述也是失败并补一条明确原因，避免把未知错误伪装成打开成功（假绿）。
    static func outcome(errorDescription: String?) -> Outcome {
        guard let detail = errorDescription else { return .opened }
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .failed("系统设置未返回具体错误") : .failed(trimmed)
    }

    /// 失败反馈三要素：具体原因、可操作的重试、手动路径。缺一就是假反馈。
    static func failureMessage(reason: String) -> String {
        "打开系统设置失败（\(reason)）。请先强制退出「系统设置」再点「重试」；也可手动前往 \(manualPath) 勾选 Smoose。"
    }

    /// 实际打开：用带 completionHandler 的重载把结果交回主线程。
    /// 不在这里替用户强杀系统进程 —— App 只负责如实反馈与给出下一步。
    @MainActor
    static func open() async -> Outcome {
        guard let url = URL(string: urlString) else { return .failed("URL 构造失败") }
        let configuration = NSWorkspace.OpenConfiguration()
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.open(url, configuration: configuration) { _, error in
                continuation.resume(returning: outcome(errorDescription: error?.localizedDescription))
            }
        }
    }
}

/// 「辅助功能 → 显示」页（摇动鼠标指针以定位所在页）。
///
/// **2026-11-07 冷启动实测纠正一次假绿**：带 anchor 的 URL 在 System Settings
/// **冷启动**时只落到 `Accessibility` 首页 —— 之前以为 `Seeing_Display` 能直达
/// `Display`，其实是连续发三个 URL 时前一个导航留下的状态。
/// 逐个冷启动复测：A `?Seeing_Display` / B `?display` / C `?Accessibility_Display`
/// 以及 `?pane=display` / `?page=display` **全部只到首页**。
/// 可靠做法是两步：先发不带 anchor 的基础 URL 把进程拉起来，等它就绪后再发
/// `?display`（间隔 0.4 / 1.0 / 2.0 秒三种都稳定到 `Display`）。
///
/// 为什么光标放大开关需要它：macOS 只在登录会话启动时加载
/// `CGDisableCursorLocationMagnification`，第三方写 plist 不会让功能即时生效。
/// 系统设置里手动把开关关一次再打开，是唯一能立刻生效的可靠路径。
enum DisplaySettingsLauncher {
    static let baseURLString =
        "x-apple.systempreferences:com.apple.Accessibility-Settings.extension"
    static let urlString = baseURLString + "?display"
    static let manualPath = "系统设置 → 辅助功能 → 显示 → 摇动鼠标指针以定位"

    /// 两步 URL 序列抽成纯函数，harness 可以直接断言「先无 anchor、后有 anchor」，
    /// 不必启动 AppKit 或真的打开系统设置。
    static func urlSequence() -> [String] { [baseURLString, urlString] }

    static func failureMessage(reason: String) -> String {
        "跳转系统设置未完全成功（\(reason)）。请先强制退出「系统设置」再点「重试」；"
            + "也可手动前往 \(manualPath)。"
    }

    @MainActor
    static func open() async -> AccessibilitySettingsLauncher.Outcome {
        for (index, string) in urlSequence().enumerated() {
            // 第二步前给刚冷启动的进程一点就绪时间（实测 0.4s 足够）。
            if index > 0 { try? await Task.sleep(for: .milliseconds(300)) }
            let result = await openOne(string)
            if case .failed(let reason) = result {
                return .failed(index == 0
                    ? reason
                    : "已打开辅助功能，但未能直达「显示」页（\(reason)）；请手动点「显示」")
            }
        }
        return .opened
    }

    @MainActor
    private static func openOne(_ string: String) async -> AccessibilitySettingsLauncher.Outcome {
        guard let url = URL(string: string) else { return .failed("URL 构造失败") }
        let configuration = NSWorkspace.OpenConfiguration()
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.open(url, configuration: configuration) { _, error in
                continuation.resume(returning: AccessibilitySettingsLauncher.outcome(
                    errorDescription: error?.localizedDescription))
            }
        }
    }
}

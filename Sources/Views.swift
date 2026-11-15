import SwiftUI
import AppKit
import Combine
import CoreGraphics
import ServiceManagement

// MARK: - 当前前台应用

final class ActiveAppInfo: ObservableObject {
    static let shared = ActiveAppInfo()
    @Published var bundleID: String?
    @Published var name: String?
    /// 设置窗口被激活时前台会变成 Smoose 自己；这里保留最后一个非 Smoose 的前台，
    /// 供状态条和「为当前 App 微调」使用，避免把 Smoose 当作用户要配置的应用。
    @Published var lastExternalBundleID: String?
    @Published var lastExternalName: String?

    func update(bundleID: String?, name: String?) {
        if let bundleID, bundleID != "app.smoose.macos" {
            lastExternalBundleID = bundleID
            lastExternalName = name
        }
        self.bundleID = bundleID
        self.name = name
    }
}

// MARK: - 菜单栏面板

struct MenuBarPanel: View {
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var active: ActiveAppInfo
    @EnvironmentObject var monitor: Monitor
    @ObservedObject private var updater = Updater.shared

    @State private var trusted = ScrollEngine.trusted(prompt: false)

    /// 打开手动管理的设置窗口（AppDelegate.openSettingsWindow）。
    /// 不用 SwiftUI 的 openSettings：那会打开 Settings 场景的空窗口，且关不掉重开不了。
    private func openSmooseSettings() {
        if let d = NSApp.delegate as? AppDelegate {
            d.openSettingsWindowForAnchor()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            Toggle("启用平滑滚动", isOn: $prefs.masterEnabled)
                .smooseHelp(.masterEnabled)
                .toggleStyle(.switch)
                .font(.system(size: 13, weight: .medium))

            VStack(alignment: .leading, spacing: 10) {
                LabeledSlider(title: "距离倍率", value: $prefs.global.speed, range: 0.2...8, unit: "×",
                              help: .speed)
                LabeledSlider(title: "滚轮行数", value: $prefs.global.wheelLines, range: 0.2...5, unit: " 行",
                              help: .wheelLines)
                LabeledSlider(title: "顺滑度", value: $prefs.global.smoothness, range: 0...1, unit: "",
                              help: .smoothness)
                LabeledSlider(title: "最小步长", value: $prefs.global.minStep, range: 0...30, unit: "px",
                              help: .minStep)
                ScrollCurvePreview(profile: prefs.global, compact: true)
                    .smooseHelp(.curvePreview)
            }
            .disabled(!prefs.masterEnabled)

            Divider()
            Section("轴") {
                Toggle("垂直平滑", isOn: $prefs.global.smoothVertical)
                    .smooseHelp(.smoothVertical)
                Toggle("水平平滑", isOn: $prefs.global.smoothHorizontal)
                    .smooseHelp(.smoothHorizontal)
            }
            if prefs.global.boostModifiers != 0 {
                Text("按住加速键可滚得更远（\(String(format: "%.1f", prefs.global.boostFactor))×）")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Divider()
            // 有新版本时在菜单栏面板顶部横幅提示。
            // 静默检查（启动 5s / 每天）只在 updateFound 时置位 phase，不弹窗不打扰；
            // 用户点开菜单栏就能顺手处理，这是菜单栏 App 最不吵的告知方式。
            if case .updateFound(let v) = updater.phase {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("发现新版本 v\(v)").font(.system(size: 12, weight: .medium))
                        HStack(spacing: 6) {
                            Button("下载并安装") { updater.downloadAndInstall() }
                                .controlSize(.small)
                            Button("暂不更新") { updater.dismiss() }
                                .controlSize(.small)
                        }
                    }
                    Spacer(minLength: 0)
                }
                Divider()
            }
            // 下载 / 安装 / 待重启也必须出现在菜单栏：用户是从这里点「下载并安装」的，
            // 装完却没有任何反馈的话，他只会以为点了没反应 —— 此前 readyToRelaunch
            // 只在「关于」页有出口，从菜单栏发起的更新得自己想起来去设置里重启。
            switch updater.phase {
            case .downloading(let p):
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: max(0, min(1, p)))
                    Text("正在下载 v\(updater.available?.version ?? "")… \(Int(max(0, min(1, p)) * 100))%")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Divider()
            case .installing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在安装，请勿退出 Smoose…")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Divider()
            case .readyToRelaunch(let v):
                VStack(alignment: .leading, spacing: 6) {
                    Label("v\(v) 已就绪，重启后生效", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 12, weight: .medium))
                    if updater.needsReauthorizationNotice {
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("签名证书有变化，重启后可能要重新授予辅助功能权限。")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 6) {
                        Button("立即重启") { updater.relaunch() }
                            .controlSize(.small)
                        // 不提供「稍后再说」：新版本已经落盘，收起横幅就没有重启入口了
                        // （dismiss() 对 readyToRelaunch 是 no-op）。要么现在重启，
                        // 要么横幅一直挂在菜单栏顶部当提醒。
                        Button("去设置页") {
                            if let d = NSApp.delegate as? AppDelegate {
                                d.openSettingsWindowForAnchor()
                            }
                        }
                        .controlSize(.small)
                    }
                }
                Divider()
            default:
                EmptyView()
            }
            Toggle("忽略触控板 / Magic Mouse", isOn: $prefs.ignoreTrackpad)
            Text("最近一次滚动来源：\(monitor.sourceName)，原始 Δ \(String(format: "%.1f", monitor.rawDelta))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Divider()
            HStack {
                Label("光标造物实验室", systemImage: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("体验网页版") {
                    if let url = URL(string: "https://cursor-forge-lab.app.workbuddy.host/?sharecode=JFGQ2NRCSZ") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundStyle(.tint)
            }
            Divider()
            footer
        }
        .padding(14)
        // 菜单栏面板：宽随内容，不设上限（与设置窗口可拉伸的策略一致）
        .frame(minWidth: 330)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.and.down.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Smoose").font(.system(size: 13, weight: .semibold))
                Text("丝滑滚轮 · Michaelqiu 出品").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(trusted ? Color.green : Color.red)
                .frame(width: 8, height: 8)
                .help(trusted ? "已获得辅助功能权限" : "缺少辅助功能权限")
        }
    }

    private var footer: some View {
        HStack {
            Button {
                if let id = active.lastExternalBundleID ?? active.bundleID {
                    NavState.shared.focusAppID = id
                    NavState.shared.selectedTab = 2   // 每应用
                }
                openSmooseSettings()
            } label: {
                Label("为 \(active.lastExternalName ?? active.name ?? "当前 App") 微调", systemImage: "slider.horizontal.3")
            }
            Button {
                openSmooseSettings()
            } label: {
                Label("更多设置", systemImage: "gear")
            }
            Button {
                NSApp.activate(ignoringOtherApps: true)
                _ = ScrollEngine.trusted(prompt: true)
                trusted = ScrollEngine.trusted(prompt: false)
            } label: {
                Label("权限", systemImage: "lock.shield")
            }
            Spacer()
            Button("退出") {
                // 退出确认（myMouseMagic 的 quitConfirm 模式）：误触保护
                let alert = NSAlert()
                alert.messageText = "退出 Smoose？"
                alert.informativeText = "退出后平滑滚动、指针调校和侧键绑定都会停止，直到下次打开。"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "退出")
                alert.addButton(withTitle: "取消")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn {
                    NSApp.terminate(nil)
                }
            }
        }
        .font(.system(size: 11))
    }
}

// MARK: - 设置窗口

/// 窗口拉大时让「整页 UI」等比放大，而不是把 560×520 的内容按原始点数居中留白。
/// 纯数据计算，harness J 段可以直接断言，不需要真的开窗口 / 依赖屏幕。
enum SettingsLayout {
    /// 与 AppDelegate.openSettingsWindow 里 NSWindow 的初始 contentRect 一致，
    /// 也是各 Tab 硬编码字号、420pt 内容宽度的设计基准。
    /// 高度取 620 而不是窗口最初的 520：关于页完整内容（图标 + 诊断 + 联动 +
    /// 自动更新 + 页脚）实测约 617pt，按 520 排版会把说明压成单行、页脚裁掉。
    static let baseWidth: CGFloat = 560
    static let baseHeight: CGFloat = 620
    /// 2× 封顶：再大的窗口只留白，避免控件大到没法用。
    static let maxScale: CGFloat = 2.0

    /// 等比系数取「宽 / 高」两个方向里较小的比例，保证放大后不会把内容裁掉。
    /// 低于基准尺寸时钳到 1（窗口 minSize 已挡住，这里是防御）。
    static func uiScale(width: CGFloat, height: CGFloat) -> CGFloat {
        guard width > 0, height > 0 else { return 1 }
        return min(maxScale, max(1, min(width / baseWidth, height / baseHeight)))
    }

    /// scaleEffect 用的「逻辑布局尺寸」：先按 1/s 布局，再视觉放大 s 倍，
    /// 放大后的视觉尺寸恰好等于窗口尺寸 —— 既铺满，又不溢出。
    static func logicalSize(width: CGFloat, height: CGFloat) -> CGSize {
        let s = uiScale(width: width, height: height)
        return CGSize(width: width / s, height: height / s)
    }

    /// 列数由「窗口实际像素宽度」决定（见 `ScaledTabContent` 的调用点）。
    /// 内容画布按 `logicalSize` 布局、再用 `scaleEffect` 铺满窗口，因此每列的
    /// 视觉宽度恒等于「窗口宽 / 列数」，与缩放系数无关。直接拿窗口实际宽判断，
    /// 才不会掉进「横屏宽矮窗逻辑宽被放大、全屏标准宽屏逻辑宽被压小」的倒置坑
    /// （2026-11-07 真机：非全屏 1600×760 出 3 列、全屏 1920×1080 反而 2 列）。
    /// - 2 列阈值 760：默认 560 基准窗口之下为单列；拖宽到 760+ 即切 2 列。
    /// - 3 列阈值 1140：更宽的窗口再切出第三列；三列各约 380pt+，表单仍可读。
    ///   全屏（1920+）必然越过此阈值，保证「全屏列数 ≥ 非全屏」。
    static let twoColumnWindowWidth: CGFloat = 760
    static let threeColumnWindowWidth: CGFloat = 1140
    static func columns(forWindowWidth w: CGFloat) -> Int {
        if w >= threeColumnWindowWidth { return 3 }
        if w >= twoColumnWindowWidth { return 2 }
        return 1
    }

    /// 本地诊断入口：解析 smoose://settings?w=…&h=… 里的窗口点数尺寸。
    /// 没有 UI scripting 权限的环境里，用它把窗口拉大来验证等比缩放。
    /// 只接受 300...4000 的合理尺寸，其余一律忽略，不影响正常开窗。
    static func debugWindowSize(from url: String) -> CGSize? {
        guard url.contains("?"),
              let query = url.split(separator: "?", maxSplits: 1).last else { return nil }
        var width: CGFloat?
        var height: CGFloat?
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, let v = Double(kv[1]) else { continue }
            if kv[0] == "w" { width = CGFloat(v) }
            if kv[0] == "h" { height = CGFloat(v) }
        }
        guard let w = width, let h = height,
              w >= 300, w <= 4000, h >= 300, h <= 4000 else { return nil }
        return CGSize(width: w, height: h)
    }
}

/// 当前标签页应使用的列数（1 或 2），由 `ScaledTabContent` 按逻辑画布宽度注入。
/// 默认 1，保证未注入环境时（如独立预览）仍是单列。
private struct LayoutColumnsKey: EnvironmentKey {
    static let defaultValue: Int = 1
}
extension EnvironmentValues {
    var layoutColumns: Int {
        get { self[LayoutColumnsKey.self] }
        set { self[LayoutColumnsKey.self] = newValue }
    }
}

/// 横屏 / 宽窗响应式容器：把标签页内容分成最多 3 列以压低高度，避免「一页显示不全」。
/// 三组内容（col0 / col1 / col2）互不重复，按列数并排或堆叠：
/// - 1 列（窄窗）：合并进同一个 `Form`，顺序 col0 → col1 → col2，外观与改造前一致；
/// - 2 列（宽窗）：col0 独立一列，col1 + col2 在右列上下堆叠；
/// - 3 列（超宽窗）：三组各占一列。
/// 三种形态都保持 `.grouped` 表单风格。
struct ResponsiveForm<Col0: View, Col1: View, Col2: View>: View {
    let columns: Int
    @ViewBuilder let col0: () -> Col0
    @ViewBuilder let col1: () -> Col1
    @ViewBuilder let col2: () -> Col2

    var body: some View {
        if columns >= 3 {
            HStack(alignment: .top, spacing: 14) {
                Form { col0() }.formStyle(.grouped)
                Form { col1() }.formStyle(.grouped)
                Form { col2() }.formStyle(.grouped)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if columns >= 2 {
            HStack(alignment: .top, spacing: 14) {
                Form { col0() }.formStyle(.grouped)
                VStack(alignment: .leading, spacing: 14) {
                    Form { col1() }.formStyle(.grouped)
                    Form { col2() }.formStyle(.grouped)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Form { col0(); col1(); col2() }.formStyle(.grouped)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 单个标签页的内容缩放容器：只缩放「页面内容」，绝不包住 TabView 本体。
/// macOS 的 TabView 标签栏由窗口 toolbar 参与布局，实测把整个 TabView 塞进
/// GeometryReader + scaleEffect 后，标签栏会跑到内容区之外被裁掉（2026-11-06 真机验证）。
private struct ScaledTabContent<Content: View>: View {
    /// 系统标签栏浮在内容区顶部。scaleEffect 会吃掉 SwiftUI 的 safe area inset，
    /// 内容会顶到标签栏上（真机截图：蓝色图标盖住「按应用」）。留出这段实际点数，
    /// 再换算成逻辑点数补在缩放前，放大后正好是 36pt 的让位。
    // 泛型 View 不支持 static stored property，所以放实例属性。
    // 让位放在 scaleEffect「之后」：它是固定的实际点数，不参与缩放。
    private let tabBarInset: CGFloat = 44

    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geo in
            // 可用高度先扣掉让位，再拿去算缩放；这样逻辑高度 = usableH/s ≥ 620，
            // 关于页能完整排版，放大后又正好铺满 geo.size.height。
            let usableH = max(1, geo.size.height - tabBarInset)
            let s = SettingsLayout.uiScale(width: geo.size.width, height: usableH)
            let logical = SettingsLayout.logicalSize(width: geo.size.width, height: usableH)
            // 列数按窗口「实际像素宽度」判定：每列视觉宽 = 窗口宽 / 列数，
            // 与缩放系数无关；用实际宽才能避免全屏标准宽屏反而列数变少的倒置。
            let cols = SettingsLayout.columns(forWindowWidth: geo.size.width)
            content()
                .environment(\.layoutColumns, cols)
                .frame(width: logical.width, height: logical.height)
                .scaleEffect(s, anchor: .topLeading)
                .padding(.top, tabBarInset)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SettingsWindow: View {
    @StateObject private var nav = NavState.shared

    var body: some View {
        // 注意：使用 TabView(selection:) 时每个 tab 都必须设 .tag(n)，否则点击未设 tag 的页
        // 会让 selection 变 nil 并卡在最后一个有 tag 的页（2026-10-15 踩过）。
        TabView(selection: $nav.selectedTab) {
            ScaledTabContent { GeneralTab() }.tabItem { Label("滚动", systemImage: "arrow.up.and.down") }.tag(0)
            ScaledTabContent { PointerTab() }.tabItem { Label("指针", systemImage: "cursorarrow") }.tag(1)
            ScaledTabContent { AppRulesTab() }.tabItem { Label("按应用", systemImage: "macwindow.on.rectangle") }.tag(2)
            ScaledTabContent { ButtonsTab() }.tabItem { Label("按键", systemImage: "rectangle.3.offgrid") }.tag(3)
            ScaledTabContent { GamePerfTab() }.tabItem { Label("游戏", systemImage: "gamecontroller") }.tag(4)
            ScaledTabContent { AboutTab() }.tabItem { Label("关于", systemImage: "info.circle") }.tag(5)
        }
        // 下限约束会传给 NSHostingView → NSWindow.minSize，窗口仍可自由拖拽放大。
        .frame(minWidth: SettingsLayout.baseWidth, maxWidth: .infinity,
               minHeight: SettingsLayout.baseHeight, maxHeight: .infinity)
    }
}

/// 首屏四格健康状态。观察到异常时直接给下一步入口，不让用户自己在六个 tab 里找。
struct HealthStrip: View {
    let snapshot: HealthSnapshot
    let onPermission: () -> Void
    let onTakeover: () -> Void
    let onDevice: () -> Void
    let onApp: () -> Void

    private var items: [HealthItem] { HealthStatus.items(snapshot) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("当前状态", systemImage: "waveform.path.ecg")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("点异常项可跳转修复")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        switch index {
                        case 0: onPermission()
                        case 1: onTakeover()
                        case 2: onDevice()
                        default: onApp()
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 7) {
                            Circle()
                                .fill(color(item.level))
                                .frame(width: 8, height: 8)
                                .padding(.top, 4)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Text(item.value)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(color(item.level).opacity(0.08))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func color(_ level: HealthLevel) -> Color {
        switch level {
        case .ok: return .green
        case .warn: return .orange
        case .fail: return .red
        }
    }
}

struct GeneralTab: View {
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var active: ActiveAppInfo
    @EnvironmentObject var monitor: Monitor
    @Environment(\.layoutColumns) private var columns
    @ObservedObject private var pointer = PointerController.shared
    @AppStorage("smoose.advancedSettings") private var advancedSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HealthStrip(
                snapshot: healthSnapshot,
                onPermission: { NavState.shared.selectedTab = SettingsTab.about.rawValue },
                onTakeover: {
                    NavState.shared.selectedTab = prefs.masterEnabled
                        ? SettingsTab.scroll.rawValue : SettingsTab.about.rawValue
                },
                onDevice: { NavState.shared.selectedTab = SettingsTab.pointer.rawValue },
                onApp: {
                    if let id = active.bundleID { NavState.shared.focusAppID = id }
                    NavState.shared.selectedTab = SettingsTab.apps.rawValue
                }
            )
            .padding(.horizontal, 12)
            .padding(.top, 12)

            ResponsiveForm(columns: columns) {
                Section("查看方式") {
                    Picker("设置模式", selection: $advancedSettings) {
                        Text("简易").tag(false)
                        Text("高级").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Text("简易模式只显示常用参数；曲线、轴向和临时透传等细节在高级模式。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Section("全局") {
                    Toggle("启用平滑滚动", isOn: $prefs.masterEnabled)
                        .smooseHelp(.masterEnabled)
                    Toggle("忽略触控板 / Magic Mouse（推荐）", isOn: $prefs.ignoreTrackpad)
                        .smooseHelp(.ignoreTrackpad)
                }
                Section("输出方式") {
                    Toggle("模拟触控板滚动（推荐）", isOn: $prefs.global.simulateTrackpad)
                        .smooseHelp(.simulateTrackpad)
                    Text("把平滑后的滚动标记成触控板滚动（带开始 / 结束 / 惯性相位），Chrome、Safari 等会直接采用上面调好的曲线，不再二次加工；个别 App 表现异常时关掉即可，关掉后完全回到旧的「滚轮 + 像素」行为。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Section("常用曲线") {
                    LabeledSlider(title: "距离倍率", value: $prefs.global.speed, range: 0.2...8, unit: "×",
                                  help: .speed)
                    LabeledSlider(title: "顺滑度", value: $prefs.global.smoothness, range: 0...1, unit: "",
                                  help: .smoothness)
                }
                if advancedSettings {
                    Section("高级曲线") {
                        LabeledSlider(title: "滚轮行数", value: $prefs.global.wheelLines, range: 0.2...5, unit: " 行",
                                      help: .wheelLines)
                        LabeledSlider(title: "最小步长", value: $prefs.global.minStep, range: 0...30, unit: "px",
                                      help: .minStep)
                        ScrollCurvePreview(profile: prefs.global)
                            .smooseHelp(.curvePreview)
                    }
                }
            } col1: {
                if advancedSettings {
                    Section("轴向与方向") {
                        HStack {
                            Toggle("垂直平滑", isOn: $prefs.global.smoothVertical)
                                .smooseHelp(.smoothVertical)
                            Toggle("垂直反向", isOn: $prefs.global.reverseVertical)
                                .smooseHelp(.reverseVertical)
                        }
                        HStack {
                            Toggle("水平平滑", isOn: $prefs.global.smoothHorizontal)
                                .smooseHelp(.smoothHorizontal)
                            Toggle("水平反向", isOn: $prefs.global.reverseHorizontal)
                                .smooseHelp(.reverseHorizontal)
                        }
                        LabeledSlider(title: "斜向锁定", value: $prefs.global.axisLockThreshold,
                                      range: 0...0.9, unit: "", help: .axisLockThreshold)
                        Text("0 = 关闭；例如 0.2 表示较小轴不足较大轴的 20% 时丢弃该轴，抑制横向抖动。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Section("临时透传") {
                        ModifierBypassRow(
                            title: "按住以下键时不接管滚动",
                            mask: Binding(get: { prefs.global.bypassModifiers },
                                         set: { prefs.global.bypassModifiers = $0 }),
                            help: .bypassModifiers
                        )
                        Text("做精细操作（PR / 时间线 / 表格）时，按住 ⌥ 之类即可临时回到原生逐格滚动。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            } col2: {
                if advancedSettings {
                    Section("按住加速") {
                        ModifierBypassRow(
                            title: "按住以下键时滚得更远",
                            mask: Binding(get: { prefs.global.boostModifiers },
                                         set: { prefs.global.boostModifiers = $0 }),
                            help: .boostModifiers
                        )
                        LabeledSlider(title: "加速倍数", value: $prefs.global.boostFactor,
                                      range: 1.2...ScrollBoost.maxScale, unit: "×",
                                      help: .boostFactor)
                        Text("滚长文档 / 长网页时按住加速键，平时仍保持温和手感。")
                        if ScrollBoost.conflicts(bypass: prefs.global.bypassModifiers,
                                                 boost: prefs.global.boostModifiers) {
                            Label("加速键与上面的「按住透传」重复，加速不会生效（同一键时透传优先）。"
                                  + "请给其中一项换个键。", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        }
                    }
                }
                Section("预设") {
                    // 一行放不下时自动换行成多行（LazyVGrid 自适应列宽），而不是把按钮文字截断成「原...」。
                    // 每列最小 84pt，足以容纳最宽的「原生 App / 跳过此 App」；放得下就一行、放不下就折行。
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 120), spacing: 8)], spacing: 8) {
                        ForEach(Array(ScrollProfile.presets.keys.sorted()), id: \.self) { name in
                            Button {
                                if let p = ScrollProfile.preset(named: name,
                                                                preservingBoostFrom: prefs.global) {
                                    prefs.global = p
                                }
                            } label: {
                                Text(name)
                                    .frame(maxWidth: .infinity)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        Button("恢复默认") { prefs.resetGlobal() }
                            .frame(maxWidth: .infinity)
                            .smooseHelp(.presets)
                    }
                }
                Section("开机") {
                    LaunchToggle()
                        .smooseHelp(.launchAtLogin)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var healthSnapshot: HealthSnapshot {
        HealthSnapshot(
            version: Updater.currentVersion,
            trusted: ScrollEngine.trusted(prompt: false),
            tapRunning: ScrollEngine.shared.isTapRunning,
            masterEnabled: prefs.masterEnabled,
            activeAppName: active.lastExternalName ?? active.name,
            activeAppBundle: active.lastExternalBundleID ?? active.bundleID,
            activeAppHasRule: (active.lastExternalBundleID ?? active.bundleID).map { prefs.apps[$0] != nil } ?? false,
            pointerDeviceCount: pointer.devices.count,
            lastSource: monitor.sourceName,
            echoGuardCount: ScrollEngine.shared.echoGuardCount
        )
    }
}

struct LaunchToggle: View {
    @EnvironmentObject var prefs: Preferences
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading) {
            Toggle("登录时启动", isOn: Binding(get: { prefs.launchAtLogin }, set: { set($0) }))
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
            Text("需要将 Smoose 放在「应用程序」文件夹内才能注册登录项。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func set(_ on: Bool) {
        do {
            if on {
                if SMAppService.mainApp.status == .enabled { return }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            prefs.launchAtLogin = SMAppService.mainApp.status == .enabled
            error = nil
        } catch {
            self.error = "注册失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 每应用

struct AppRulesTab: View {
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var active: ActiveAppInfo
    @State private var selection = ""
    @State private var showingAdd = false
    @AppStorage("smoose.newAppPreset") private var newAppPreset = "自动识别"

    private var sortedKeys: [String] { prefs.apps.keys.sorted() }

    private var candidates: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("按 App 单独设置滚动手感。留空的 App 沿用全局配置。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("新增预设").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("", selection: $newAppPreset) {
                    Text("自动识别").tag("自动识别")
                    ForEach(Array(ScrollProfile.presets.keys.sorted()), id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 132)
                Menu {
                    ForEach(candidates, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "?") {
                            if let id = app.bundleIdentifier, prefs.apps[id] == nil {
                                prefs.apps[id] = profileForNewApp(id: id)
                            }
                        }
                    }
                    Divider()
                    Button("当前前台应用：\(active.lastExternalName ?? active.name ?? "无")") {
                        if let id = active.lastExternalBundleID ?? active.bundleID, prefs.apps[id] == nil {
                            prefs.apps[id] = profileForNewApp(id: id)
                        }
                    }
                } label: { Label("添加应用", systemImage: "plus") }
                .smooseHelp(.addAppRule)
            }

            List {
                ForEach(sortedKeys, id: \.self) { id in
                    AppRuleRow(id: id, profile: binding(for: id))
                }
                .onDelete { offsets in
                    let keys = sortedKeys
                    for i in offsets { prefs.apps.removeValue(forKey: keys[i]) }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func binding(for id: String) -> Binding<ScrollProfile> {
        Binding(get: { prefs.apps[id] ?? prefs.global },
                set: { prefs.apps[id] = $0 })
    }

    /// 新增规则的唯一入口：自动识别只对保守白名单生效；手动预设覆盖自动结果。
    private func profileForNewApp(id: String) -> ScrollProfile {
        if newAppPreset == "自动识别" {
            guard let suggested = ScrollProfile.suggested(forBundleID: id) else {
                return prefs.global
            }
            return preservingGlobalOutput(suggested)
        }
        return ScrollProfile.preset(named: newAppPreset, preservingBoostFrom: prefs.global)
            ?? prefs.global
    }

    /// 自动模板只改曲线参数；输出方式、斜向锁定和加速键属于用户的全局策略，新增 App 时不能被模板重置。
    private func preservingGlobalOutput(_ profile: ScrollProfile) -> ScrollProfile {
        var p = profile
        p.boostModifiers = prefs.global.boostModifiers
        p.boostFactor = prefs.global.boostFactor
        p.simulateTrackpad = prefs.global.simulateTrackpad
        p.axisLockThreshold = prefs.global.axisLockThreshold
        return p
    }
}

struct AppRuleRow: View {
    let id: String
    @Binding var profile: ScrollProfile
    @EnvironmentObject var prefs: Preferences
    @State private var expanded = false
    @StateObject private var nav = NavState.shared

    private var isFocused: Bool { nav.focusAppID == id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "app.badge.checkmark").foregroundStyle(.secondary)
                Text(displayName).font(.system(size: 12, weight: .medium))
                Spacer()
                Toggle("接管", isOn: $profile.enabled)
                    .smooseHelp(.appRuleEnabled)
                    .labelsHidden()
                Button {
                    prefs.apps.removeValue(forKey: id)
                } label: { Image(systemName: "trash") }
                .buttonStyle(.plain)
            }
            // 常用两个参数直接可见，不用展开「细节参数」
            LabeledSlider(title: "距离倍率", value: $profile.speed, range: 0.2...8, unit: "×",
                            help: .appRuleSpeed)
                .disabled(!profile.enabled)
            LabeledSlider(title: "顺滑度", value: $profile.smoothness, range: 0...1, unit: "",
                            help: .appRuleSmoothness)
                .disabled(!profile.enabled)
            Menu("套用预设模板") {
                Button("从全局复制") {
                    profile = prefs.global
                }
                Divider()
                ForEach(Array(ScrollProfile.presets.keys.sorted()), id: \.self) { name in
                    Button(name) {
                        if let p = ScrollProfile.preset(named: name, preservingBoostFrom: profile) {
                            profile = p
                        }
                    }
                }
            }
            .font(.system(size: 11))
            DisclosureGroup("细节参数", isExpanded: $expanded) {
                LabeledSlider(title: "距离倍率", value: $profile.speed, range: 0.2...8, unit: "×",
                            help: .appRuleSpeed)
                LabeledSlider(title: "滚轮行数", value: $profile.wheelLines, range: 0.2...5, unit: " 行",
                            help: .appRuleWheelLines)
                LabeledSlider(title: "顺滑度", value: $profile.smoothness, range: 0...1, unit: "",
                            help: .appRuleSmoothness)
                LabeledSlider(title: "最小步长", value: $profile.minStep, range: 0...30, unit: "px",
                            help: .appRuleMinStep)
                LabeledSlider(title: "斜向锁定", value: $profile.axisLockThreshold,
                              range: 0...0.9, unit: "", help: .appRuleAxisLockThreshold)
                HStack {
                    Toggle("垂直平滑", isOn: $profile.smoothVertical)
                        .smooseHelp(.appRuleSmoothVertical)
                    Toggle("水平平滑", isOn: $profile.smoothHorizontal)
                        .smooseHelp(.appRuleSmoothHorizontal)
                }
                HStack {
                    Toggle("垂直反向", isOn: $profile.reverseVertical)
                        .smooseHelp(.appRuleReverseVertical)
                    Toggle("水平反向", isOn: $profile.reverseHorizontal)
                        .smooseHelp(.appRuleReverseHorizontal)
                }
                Toggle("模拟触控板滚动", isOn: $profile.simulateTrackpad)
                    .smooseHelp(.appRuleSimulateTrackpad)
                    .disabled(!profile.enabled)
                ModifierBypassRow(title: "按住时透传滚动",
                                 mask: Binding(get: { profile.bypassModifiers },
                                              set: { profile.bypassModifiers = $0 }),
                                 help: .appRuleBypass)
                Divider()
                Text("侧键绑定覆盖（留空走全局）").font(.system(size: 10)).foregroundStyle(.secondary)
                ForEach(3...5, id: \.self) { button in
                    Picker("按键 \(button)", selection: appBinding(for: button)) {
                        Text("跟随全局").tag(ButtonAction?.none)
                        ForEach(ButtonAction.allCases) { action in
                            Text(action.label).tag(ButtonAction?.some(action))
                        }
                    }
                    .smooseHelp(.appRuleSideButtons)
                }
            }
            .font(.system(size: 11))
        }
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isFocused ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .onChange(of: isFocused) { _, focused in
            if focused {
                expanded = true
                nav.focusAppID = nil
            }
        }
        .padding(.vertical, 4)
    }

    private var displayName: String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let n = FileManager.default.displayName(atPath: url.path)
            return n.replacingOccurrences(of: ".app", with: "")
        }
        return id
    }

    private func appBinding(for button: Int) -> Binding<ButtonAction?> {
        Binding(
            get: { prefs.appBindings[id]?[String(button)].flatMap(ButtonAction.init(rawValue:)) },
            set: { nv in
                var table = prefs.appBindings[id] ?? [:]
                if let a = nv { table[String(button)] = a.rawValue } else { table.removeValue(forKey: String(button)) }
                if table.isEmpty { prefs.appBindings.removeValue(forKey: id) } else { prefs.appBindings[id] = table }
            })
    }
}

// MARK: - 按键绑定

struct ButtonsTab: View {
    @EnvironmentObject var prefs: Preferences
    @Environment(\.layoutColumns) private var columns
    @State private var lastDetectedButton: Int?
    @State private var testMonitor: Any?
    @State private var testLocalMonitor: Any?

    var body: some View {
        ResponsiveForm(columns: columns) {
            Section("鼠标按键") {
                Toggle("交换后/前侧键（4 ↔ 5）", isOn: $prefs.swapBackForward)
                    .smooseHelp(.swapBackForward)
                Toggle("抬起时触发（默认按下触发）", isOn: $prefs.triggerOnMouseUp)
                    .smooseHelp(.triggerOnMouseUp)
                ForEach(3...5, id: \.self) { button in
                    Picker("按键 \(button)\(subtitle(for: button))", selection: binding(for: button)) {
                        ForEach(ButtonAction.allCases) { action in
                            Text(action.label).tag(action)
                        }
                    }
                    .smooseHelp(.sideButton)
                }
            }
        } col1: {
            Section("按键测试") {
                HStack {
                    Image(systemName: lastDetectedButton == nil ? "questionmark.circle" : "checkmark.circle.fill")
                        .foregroundStyle(lastDetectedButton == nil ? Color.secondary : Color.green)
                    Text(lastDetectedButton.map { "检测到按键 \(String($0))" } ?? "按一下鼠标侧键试试")
                        .font(.system(size: 11))
                    Spacer()
                    if let b = lastDetectedButton {
                        Text("副键 \(String(b))")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tint)
                    }
                }
            }
        } col2: {
            Section {
                Text("绑定会吞掉该按键的原生点击事件。Logitech 侧键在 HID++ 模式下可能无法识别为按钮 4/5。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
        .onAppear { installMonitorIfNeeded() }
        .onDisappear {
            if let m = testMonitor {
                NSEvent.removeMonitor(m)
                testMonitor = nil
            }
            if let m = testLocalMonitor {
                NSEvent.removeMonitor(m)
                testLocalMonitor = nil
            }
        }
    }

    private func installMonitorIfNeeded() {
        guard testMonitor == nil else { return }
        // 双监听（myMouseMagic 的 localMonitor + globalMonitor 模式）：
        // 设置窗口在前台时事件发给本 App，local monitor 能看到；
        // 其他 App 前台时 global monitor 借助辅助功能权限观测。两者不影响事件流向。
        testLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { event in
            let b = Int(event.buttonNumber)
            DispatchQueue.main.async { lastDetectedButton = b }
            return event
        }
        testMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { event in
            let b = Int(event.buttonNumber)
            DispatchQueue.main.async { lastDetectedButton = b }
        }
    }

    private func subtitle(for button: Int) -> String {
        switch button {
        case 3: return "（中键）"
        case 4: return "（侧键·后）"
        default: return "（侧键·前）"
        }
    }

    private func binding(for button: Int) -> Binding<ButtonAction> {
        Binding(get: {
            prefs.bindings[String(button)].flatMap(ButtonAction.init(rawValue:)) ?? .none
        }, set: { action in
            if action == .none {
                prefs.bindings.removeValue(forKey: String(button))
            } else {
                prefs.bindings[String(button)] = action.rawValue
            }
        })
    }
}

// MARK: - 游戏性能

/// 鼠标游戏性能检测面板。
///
/// 数据来源全部是 Smoose **本来就在跑**的两条回调，不新开 tap、不加轮询：
///   · 指针 / 侧键 —— ScrollEngine 的 CGEvent tap 已拦 mouseMoved 与 otherMouseDown/Up
///   · 显示帧 —— ScrollEngine 的 CVDisplayLink
/// 所以打开这个页面对 Smoose 自身零额外系统开销。
struct GamePerfTab: View {
    @Environment(\.layoutColumns) private var columns
    @ObservedObject private var probe = GamePerfProbe.shared

    var body: some View {
        ResponsiveForm(columns: columns) {
            Section("设备参数（硬件实读）") {
                if probe.devices.isEmpty {
                    Text("还没有枚举到指针设备。").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ForEach(probe.devices) { d in
                        // 两个罗技接收器的 Product 都叫 "USB Receiver"，列表会出现两行同名。
                        // 同名时追加 PID / USB 位置，用户才看得出这不是重复（2026-11-10）。
                        let title = DeviceLabel.disambiguate(
                            d.name,
                            productID: d.productID,
                            locationID: d.locationID,
                            ambiguous: DeviceLabel.hasSameNameSibling(name: d.name,
                                                                     in: probe.devices.map(\.name)))
                            + (d.builtIn ? "（内置）" : "")
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title)
                                    .font(.system(size: 12, weight: .medium))
                                Text("\(d.transport.isEmpty ? "传输未知" : d.transport)"
                                     + " · 上报间隔 \(String(format: "%.0f", d.reportIntervalUs)) µs")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(d.pollingLabel)
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                .foregroundStyle(d.pollingHz >= 500 ? .green : .orange)
                        }
                    }
                }
                Text("回报率读自 IORegistry 的 ReportInterval，是鼠标板载配置的真实值"
                     + "（G502 X 接收器实测 1000 µs = 1000 Hz）。"
                     + "传感器 DPI 不在 IORegistry 里，改由「指针」页的 HID++ 0x2201 向设备实读。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text("出现多行同名（例如两个都叫 USB Receiver）不是重复：系统给不同接收器的名字相同，"
                     + "只有 PID / USB 位置能区分。同名行会带上后缀，对应的是插在不同 USB 口上的不同设备。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section("实时指标（2 秒滚动窗口）") {
                if probe.sampling {
                    Label("正在采样：移动鼠标约 2 秒", systemImage: "waveform.path.ecg")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                metricRow("指针事件率", probe.pointerRateHz > 0 ? "\(String(format: "%.0f", probe.pointerRateHz)) Hz" : "—",
                          sub: probe.pointerSamples > 0 ? "\(probe.pointerSamples) 个样本" : "")
                metricRow("移动抖动 p50 / p99 / max",
                          "\(ms(probe.pointerJitterP50Ms)) / \(ms(probe.pointerJitterP99Ms)) / \(ms(probe.pointerJitterMaxMs))")
                metricRow("指针延迟 p50 / p99 / max",
                          "\(ms(probe.pointerLatencyP50Ms)) / \(ms(probe.pointerLatencyP99Ms)) / \(ms(probe.pointerLatencyMaxMs))")
                metricRow("显示刷新率", probe.refreshHz > 0 ? "\(String(format: "%.1f", probe.refreshHz)) Hz" : "—",
                          sub: "掉帧 \(String(format: "%.1f%%", probe.frameDropRatio * 100))"
                               + " · \(probe.frameSamples) 帧")
                metricRow("滚轮事件率", probe.wheelRateHz > 0 ? "\(String(format: "%.1f", probe.wheelRateHz)) Hz" : "—")
                metricRow("侧键按下时长", probe.sideButtonMs > 0 ? ms(probe.sideButtonMs) : "—",
                          sub: "只统计侧键 4/5，左右主键不经过事件拦截")
            }
        } col1: {
            Section("就绪度") {
                HStack(spacing: 10) {
                    Image(systemName: probe.sampling ? "hourglass" : probe.readiness.symbol)
                        .font(.system(size: 24))
                        .foregroundStyle(probe.sampling ? .secondary : color(for: probe.readiness))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(probe.sampling ? "采样中" : probe.readiness.rawValue)
                            .font(.headline)
                        Text(probe.sampling ? "移动鼠标 2 秒后给出评级" : summary())
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                ForEach(probe.checks) { c in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: c.pass ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(c.pass ? .green : .orange)
                            .font(.system(size: 12))
                        Text(c.label).font(.system(size: 12))
                        Spacer()
                        Text(c.detail)
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } col2: {
            Section("建议") {
                ForEach(Array(probe.advice.enumerated()), id: \.offset) { i, s in
                    Text("\(i + 1). \(s)")
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("重置统计") { probe.reset() }
            }
        }
    }

    private func ms(_ v: Double) -> String { v > 0 ? String(format: "%.2f ms", v) : "—" }

    /// 指标行：左边标题（可带灰色小字补充），右边等宽数字。
    /// 用 monospacedDigit 是因为数字每秒都在跳，比例字体下宽度会抖。
    private func metricRow(_ title: String, _ value: String, sub: String = "") -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12))
                if !sub.isEmpty {
                    Text(sub).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
        }
    }

    private func color(for r: GameReadiness) -> Color {
        switch r {
        case .competitive: return .green
        case .good: return .mint
        case .fair: return .orange
        case .poor: return .red
        }
    }

    private func summary() -> String {
        let failed = probe.checks.filter { !$0.pass }
        if failed.isEmpty { return "5 项检查全部通过" }
        return "\(failed.count) 项未达标：\(failed.map { $0.label }.joined(separator: "、"))"
    }
}

// MARK: - 关于

struct AboutTab: View {
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var active: ActiveAppInfo
    @EnvironmentObject var monitor: Monitor
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var pointer = PointerController.shared
    @State private var trusted = ScrollEngine.trusted(prompt: false)
    @State private var feedDraft: String = ""
    @State private var feedSaved = false
    @State private var diagnosticsCopied = false

    var body: some View {
        VStack(alignment: .center, spacing: 14) {
            Image(systemName: "arrow.up.and.down.circle.fill")
                .font(.system(size: 48)).foregroundStyle(.tint)
            Text("Smoose").font(.largeTitle.bold())
            Text("v\(Updater.currentVersion) · macOS 鼠标平滑滚动引擎 · Michaelqiu 出品").font(.subheadline).foregroundStyle(.secondary)
            Text("拦截 HID 层滚轮事件，按显示刷新率重建滚动曲线：指数插值 + 亚像素累积投递。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                // 外层容器高度固定时 SwiftUI 会把长说明压成单行并打省略号；
                // 固定垂直尺寸让它按 420pt 正常换成两行。
                .fixedSize(horizontal: false, vertical: true)

            Divider().frame(maxWidth: 420)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("诊断").font(.headline)
                    Text("辅助功能权限：\(trusted ? "已授权" : "未授权")")
                    Text("事件 tap：\(ScrollEngine.shared.isTapRunning ? "运行中" : "未运行")")
                    Text("指针设备：\(pointer.devices.count) 台")
                    Text("回环拦截计数：\(ScrollEngine.shared.echoGuardCount)")
                    Text("最近 Δ：\(String(format: "%.1f", monitor.rawDelta)) · \(monitor.sourceName)")
                }
                .font(.system(size: 11))
                VStack(spacing: 6) {
                    Button(diagnosticsCopied ? "已复制诊断报告" : "复制诊断报告") {
                        copyDiagnostics()
                    }
                    .controlSize(.small)
                    Button("请求/检查权限") {
                        _ = ScrollEngine.trusted(prompt: true)
                        trusted = ScrollEngine.trusted(prompt: false)
                    }
                    .smooseHelp(.requestPermission)
                    Button("重新检测") {
                        recheckSystem()
                    }
                    .controlSize(.small)
                    Button("重置全部设置") {
                        UserDefaults.standard.removeObject(forKey: "smoose.state")
                        prefs.load()
                    }
                    .smooseHelp(.resetAllSettings)
                }
            }

            Divider().frame(maxWidth: 420)

            // MARK: 创意联动
            VStack(alignment: .leading, spacing: 6) {
                Text("创意联动").font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cursor Forge Lab · 光标造物实验室").font(.system(size: 12, weight: .medium))
                        Text("把鼠标轨迹实时变成热力图与艺术字，测测你的造物指数").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        if let url = URL(string: "https://cursor-forge-lab.app.workbuddy.host/?sharecode=JFGQ2NRCSZ") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("立即体验", systemImage: "arrow.up.right.square")
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(8)
            }
            .frame(maxWidth: 420)

            Divider().frame(maxWidth: 420)

            // MARK: 自动更新
            VStack(alignment: .leading, spacing: 8) {
                Text("自动更新").font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Text("当前版本")
                    Spacer()
                    Text("v\(Updater.currentVersion)").foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                Toggle("每天自动检查一次更新", isOn: $prefs.autoCheckUpdates)
                    .smooseHelp(.autoCheckUpdates)
                    .font(.system(size: 11))
                    .toggleStyle(.switch)

                HStack(spacing: 8) {
                    Button {
                        updater.check(interactive: true)
                    } label: {
                        if case .checking = updater.phase {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("检查更新")
                        }
                    }
                    .disabled(updater.phase.isBusy)
                    if let at = updater.lastCheckedAt {
                        Text("上次检查 \(at.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }

                // 版本源地址（可选覆盖）
                HStack(spacing: 6) {
                    TextField("版本源地址（留空用默认）", text: $feedDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(maxWidth: 340)
                    Button(feedSaved ? "已保存" : "保存") {
                        updater.setFeedURL(feedDraft)
                        feedSaved = true
                    }
                    .disabled(feedDraft.trimmingCharacters(in: .whitespaces)
                        == updater.feedURLString)
                }

                Text("默认版本源：\(Updater.defaultFeedURL)")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                UpdateStatusView()
            }
            .font(.system(size: 11))
            .frame(maxWidth: 420)

            Text("开源致敬：Mos (Caldis/Mos) · MIT").font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if feedDraft.isEmpty {
                feedDraft = updater.feedURLString
            }
        }
    }

    private var healthSnapshot: HealthSnapshot {
        HealthSnapshot(
            version: Updater.currentVersion,
            trusted: ScrollEngine.trusted(prompt: false),
            tapRunning: ScrollEngine.shared.isTapRunning,
            masterEnabled: prefs.masterEnabled,
            activeAppName: active.lastExternalName ?? active.name,
            activeAppBundle: active.lastExternalBundleID ?? active.bundleID,
            activeAppHasRule: (active.lastExternalBundleID ?? active.bundleID).map { prefs.apps[$0] != nil } ?? false,
            pointerDeviceCount: pointer.devices.count,
            lastSource: monitor.sourceName,
            echoGuardCount: ScrollEngine.shared.echoGuardCount
        )
    }

    private func copyDiagnostics() {
        let report = HealthStatus.report(healthSnapshot)
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(report, forType: .string)
        diagnosticsCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            diagnosticsCopied = false
        }
    }

    private func recheckSystem() {
        trusted = ScrollEngine.trusted(prompt: false)
        ScrollEngine.shared.revalidateTap()
        PointerController.shared.refresh(force: true)
        LogitechHIDPP.shared.refresh()
        diagnosticsCopied = false
    }
}

/// 更新状态条：把 Updater.phase 渲染成一句人能看懂的话 + 一个明确的下一步按钮。
/// 每种失败都给可操作的原因（地址错 / 网络错 / 系统版本不够 / 没有安装包）。
struct UpdateStatusView: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Group {
            switch updater.phase {
            case .idle:
                EmptyView()
            case .upToDate(let v):
                Label("已是最新版本 v\(v)", systemImage: "checkmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            case .updateFound(let v):
                VStack(alignment: .leading, spacing: 6) {
                    Label("发现新版本 v\(v)", systemImage: "sparkles")
                        .font(.system(size: 11)).foregroundStyle(.green)
                    HStack(spacing: 8) {
                        Button("下载并安装") { updater.downloadAndInstall() }
                            .controlSize(.small)
                        Button("暂不更新") { updater.dismiss() }
                            .controlSize(.small)
                        Button("跳过此版本") { updater.skipVersion(v) }
                            .controlSize(.small)
                    }
                    if let notes = updater.available?.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            case .skipped(let v):
                Label("已跳过 v\(v)，不会自动提示", systemImage: "forward.fill")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            case .checking:
                Text("正在检查更新…").foregroundStyle(.secondary)
            case .downloading(let p):
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: max(0, min(1, p)))
                    Text("下载中 \(Int(p * 100))%")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            case .installing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在安装，请勿退出 Smoose…")
                }
            case .readyToRelaunch(let v):
                VStack(alignment: .leading, spacing: 6) {
                    Label("v\(v) 已就绪，重启后生效", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 11))
                    if updater.needsReauthorizationNotice {
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("新版本签名证书变更，重启后 macOS 可能会撤销辅助功能权限，届时需在系统设置中重新勾选。")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("立即重启") { updater.relaunch() }
                        .controlSize(.small)
                }
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: 10))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 指针（加速度 / 速度）

struct PointerTab: View {
    @EnvironmentObject var prefs: Preferences
    @Environment(\.layoutColumns) private var columns
    @ObservedObject private var controller = PointerController.shared
    /// 会话同步的调度与结果放在单例里：切标签页 / 关设置窗也不打断自动重载。
    @ObservedObject private var zoomSync = CursorZoomSessionSync.shared

    /// 光标放大：写入结果与「打开系统设置」的失败都必须可见，不能静默。
    @State private var zoomResult: CursorZoomApplyResult?
    @State private var zoomLaunchFailure: String?
    /// 「进入设置页时读回的系统真实偏好值」，与 prefs 里的缓存分开显示，
    /// 避免「开关显示关、实物还在放大」的假绿。同步结果改由 zoomSync 发布。
    @State private var zoomSystemEnabled: Bool?

    private var zoomLedgerDisplay: CursorZoomAutoSyncPolicy.LedgerDisplay {
        CursorZoomAutoSyncPolicy.display(
            ledgerEnabled: zoomSync.ledgerEnabled,
            desired: prefs.cursorZoomEnabled)
    }

    private var zoomTimeText: String {
        guard let at = zoomSync.ledgerAt else { return "" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: at))
    }

    /// 自定义 Binding：只有写后读回校验通过才更新 prefs。
    /// 失败时不写 prefs，Toggle 读 get 会自动回弹，且不会再触发一次写入
    /// （旧实现的 onChange(of:) 直接改状态会造成来回回弹）。
    private var cursorZoomBinding: Binding<Bool> {
        Binding(
            get: { prefs.cursorZoomEnabled },
            set: { newValue in applyCursorZoom(newValue) }
        )
    }

    private func applyCursorZoom(_ enabled: Bool) {
        let result = CursorZoomController.shared.apply(enabled)
        zoomResult = result
        if result.ok { prefs.cursorZoomEnabled = enabled }
        // 失败：不写 prefs → 开关回弹；红字给出具体原因与重试提示。
        // 写盘成功就安排自动重载（防抖在单例里）；失败绝不触发，
        // 否则会把系统设置拨到没有用户意图的方向。
        if CursorZoomAutoSyncPolicy.shouldTrigger(writeOK: result.ok) {
            zoomSync.scheduleAuto(desiredEnabled: enabled)
        }
    }

    /// 每次进入指针页都从 cfprefsd 读回系统真实偏好值，只用于「显示」。
    /// 绝不回写 prefs：旧实现用系统值覆盖用户刚选的开关，用户点「开启」后切页/重进
    /// 就被改回「关」，看起来就是「打开了却不生效」。差异另行提示，让用户主动追平。
    private func syncZoomFromSystem() {
        zoomSystemEnabled = CursorZoomController.shared.systemEnabled
        zoomSync.reloadLedger()
    }

    /// 手动触发（重试 / 用户主动点按钮）：与自动路径共用同一个 apply 与四条硬门槛。
    private func applyZoomThisSession() {
        zoomSync.runNow(desiredEnabled: prefs.cursorZoomEnabled)
    }

    private func openDisplaySettings() {
        zoomLaunchFailure = nil
        Task { @MainActor in
            switch await DisplaySettingsLauncher.open() {
            case .opened:
                zoomLaunchFailure = nil
            case .failed(let reason):
                zoomLaunchFailure = DisplaySettingsLauncher.failureMessage(reason: reason)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "cursorarrow")
                    .foregroundStyle(.tint)
                Text("绕过系统设置，直接改写 IOHIDSystem 的 HID 参数").font(.system(size: 12, weight: .medium))
            }
            Text("这部分等价于 LinearMouse 的看家功能：关掉 macOS 那条让人抓狂的指针加速曲线，让指针移动变成严格线性 —— 肌肉记忆和 Windows / Linux 上一致。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ResponsiveForm(columns: columns) {
                Section("指针加速度") {
                    Toggle("接管并提供线性追踪（关掉 macOS 的加速曲线）", isOn: $prefs.pointerAccelManaged)
                        .smooseHelp(.pointerAccelManaged)
                    LabeledSlider(title: "加速度数值", value: $prefs.pointerAccelerationValue, range: 0...6, unit: "",
                                  help: .pointerAccelerationValue)
                    .disabled(!prefs.pointerAccelManaged)
                    HStack {
                        Button("取 0（线性）") { prefs.pointerAccelerationValue = 0 }
                        Button("取 2.5（接近系统默认）") { prefs.pointerAccelerationValue = 2.5 }
                    }
                    .disabled(!prefs.pointerAccelManaged)
                    Text("内建触控板由系统管理：本机实测写入 HIDMouseAcceleration = -1 后读回 0，线性缩放标志也不支持，所以它不参与加速度接管，也不会再把状态区误报成写入失败。外接鼠标 / 接收器照常接管。")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section("光标放大") {
                    Toggle("快速移动鼠标时放大光标图标", isOn: cursorZoomBinding)
                        .smooseHelp(.cursorZoomEnabled)
                    // 系统偏好值与「本次会话是否生效」分开写，不能混成一个开关状态。
                    if let zoomSystemEnabled {
                        Text("系统偏好：\(zoomSystemEnabled ? "开启" : "已关闭")（进入本页时从系统读回）")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        if zoomSystemEnabled != prefs.cursorZoomEnabled {
                            Text("系统偏好与当前开关不一致：点「立即生效」让系统按开关状态追平。")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let sync = zoomSync.lastResult {
                        Text(sync.message)
                            .font(.system(size: 10))
                            .foregroundStyle(sync.ok ? Color.green : Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        // 不写「尚未重载」：那是 App 丢了记录，不是系统状态回退。
                        Text(CursorZoomAutoSyncPolicy.ledgerMessage(zoomLedgerDisplay, timeText: zoomTimeText))
                            .font(.system(size: 10))
                            .foregroundStyle(
                                zoomLedgerDisplay == .upToDate(enabled: prefs.cursorZoomEnabled)
                                    ? Color.secondary : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !zoomSync.ledgerWriteOk {
                        Text("重载记录未能保存：只影响重启后的状态提示，不影响本次重载结果。")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let zoomResult {
                        Text(CursorZoomPolicy.statusMessage(zoomResult))
                            .font(.system(size: 10))
                            .foregroundStyle(zoomResult.ok ? Color.secondary : Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Button("立即生效（无需注销）") { applyZoomThisSession() }
                            .smooseHelp(.zoomApplyNow)
                            .font(.system(size: 11))
                        Button("在系统设置里打开") { openDisplaySettings() }
                            .smooseHelp(.zoomOpenSystemSettings)
                            .font(.system(size: 11))
                        if zoomLaunchFailure != nil
                            || (zoomSync.lastResult != nil && !zoomSync.lastResult!.ok) {
                            Button("重试") {
                                applyZoomThisSession()
                                openDisplaySettings()
                            }
                            .controlSize(.small)
                        }
                    }
                    if let zoomLaunchFailure {
                        Text(zoomLaunchFailure)
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("即系统自带的「摇动鼠标指针以定位」。拨动开关后 Smoose 会自动用自身辅助功能权限到系统设置里，按目标状态拨动该开关并校验终态（开与关都支持），完成后回到你之前所在的应用；也可点「立即生效」手动重试。macOS 只在登录时加载该偏好，所以不重载的话运行中的会话仍可能用旧值。若授权被系统收回，请在 系统设置 → 隐私与安全性 → 辅助功能 重新勾选 Smoose。")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } col1: {
                Section("设备") {
                    if controller.devices.isEmpty {
                        Text("尚未发现指针设备").foregroundStyle(.secondary).font(.system(size: 11))
                    } else {
                        ForEach(controller.devices) { device in
                            PointerDeviceRow(device: device, controller: controller)
                        }
                        Text("「滚动判定」只影响这一台设备：自动 = 按设备类型识别（触控面原样放行 / 滚轮鼠标交给平滑），识别不出来时才回落到「忽略触控板」开关。误判的第三方设备在这里单独改成「滚轮鼠标」即可，内置触控板仍受保护。")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section("指针速度") {
                    Toggle("自定义移动速度倍率", isOn: $prefs.pointerSpeedManaged)
                        .smooseHelp(.pointerSpeedManaged)
                    LabeledSlider(title: "速度倍率", value: $prefs.pointerSpeedFactor, range: 0.2...4, unit: "×",
                                  help: .pointerSpeedFactor)
                    .disabled(!prefs.pointerSpeedManaged)
                    HStack {
                        Button("取 1.0（原速）") { prefs.pointerSpeedFactor = 1.0 }
                        Button("取 1.5") { prefs.pointerSpeedFactor = 1.5 }
                        Button("取 2.0") { prefs.pointerSpeedFactor = 2.0 }
                    }
                    .disabled(!prefs.pointerSpeedManaged)
                }
                Section("说明") {
                    Text("速度倍率通过 Event Tap 重写鼠标移动增量实现（现代 macOS 的 HIDPointerResolution 不可写）。拖拽、绘图等按住按键的场景保持系统原速，避免影响选区与拖放精度。")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } col2: {
                Section("状态") {
                    Text(controller.appliedDescription)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(controller.lastWriteOk ? Color.secondary : Color.red)
                    Text("线性模式同时写入加速度 -1 与 HIDUseLinearScalingMouseAcceleration=1；两者缺一都仍是系统加速曲线。参数写在外部鼠标的 HID 设备实例上，内建触控板不参与写入；重新插拔 / 唤醒后会由 App 自动重套，勾选「登录时启动」可开机自动生效。")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Section("罗技专属（Logitech HID++ 硬件直控）") {
                    LogitechSectionView()
                }
            }

            HStack {
                Button("重新检测") { controller.refresh(force: true) }
                    .smooseHelp(.pointerRefresh)
                Button("恢复系统默认") {
                    prefs.pointerAccelManaged = false
                    controller.restoreDefaults()
                    controller.refresh(force: true)
                }
                .smooseHelp(.pointerRestoreDefaults)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 每次指针页出现都从系统读回真实偏好值，消除「本地缓存显示关」的假绿。
        .onAppear { syncZoomFromSystem() }
        // 自动 / 手动同步结束后都重新读回系统偏好，避免显示停留在拨动前的值。
        .onChange(of: zoomSync.lastResult) { _, _ in syncZoomFromSystem() }
    }
}

struct LogitechSectionView: View {
    @ObservedObject private var logi = LogitechHIDPP.shared
    @State private var selectedDPI: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: logi.isConnected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(logi.isConnected ? Color.green : Color.secondary)
                Text(logi.statusMessage)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Button("刷新") { logi.refresh() }
                    .font(.system(size: 11))
            }
            // 只有「设置窗口可见 + 指针页可见」才保持 HID++ 长连接，离开立刻释放设备。
            .onAppear { logi.setDPIPageVisible(true) }
            .onDisappear { logi.setDPIPageVisible(false) }

            // 只有设备真的回报了 0x2201 能力才显示档位。探测失败 / 不支持时
            // 绝不用硬编码 [400...3200] 兜底 —— 那会让人以为写入成功了。
            if logi.isConnected {
                switch logi.probeState {
                case .ready(let cap, let current, let def):
                    HStack(spacing: 8) {
                        Text("当前硬件 DPI：\(current)")
                            .font(.system(size: 11, weight: .semibold))
                        Text(logi.syncStatus)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.secondary.opacity(logi.isWatching ? 1 : 0.55))
                    }
                    Text("设备回报：\(cap.min)–\(cap.max) DPI · 步进 \(cap.step ?? 0)"
                         + " · 默认 \(def) DPI")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text("硬件传感器 DPI：")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Picker("DPI", selection: $selectedDPI) {
                            ForEach(logi.selectableDPIs, id: \.self) { dpi in
                                Text("\(dpi) DPI").tag(dpi)
                            }
                        }
                        .smooseHelp(.logiDPI)
                        .pickerStyle(.menu)
                        .onAppear { if logi.currentDPI > 0 { selectedDPI = logi.currentDPI } }
                        .onChange(of: logi.currentDPI) { _, v in if v > 0 { selectedDPI = v } }
                        // 写入必须是显式动作：早先监听选中项变化自动下发，
                        // 结果「只是打开页面」就因为同步当前值触发了一次 SET 报文。
                        Button("应用") {
                            guard selectedDPI > 0 else { return }
                            logi.setDPI(selectedDPI)
                        }
                        .font(.system(size: 11))
                    }
                    Text("档位取自 HID++ 0x2201 设备回报；选好点「应用」写入，写后读回确认，失败会明确报错。鼠标上的 DPI 快捷键切档后本页会自动跟随显示（每 0.3 秒读一次设备当前值），不会回写硬件；离开本页自动释放 HID++ 接口。")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                case .probing:
                    Text("正在向设备查询 DPI 能力…")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                case .idle, .unsupported, .failed:
                    Text("未取得设备回报的 DPI 能力，不显示档位、也不下发写入。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct PointerDeviceRow: View {
    let device: PointerController.MouseDevice
    @ObservedObject var controller: PointerController
    @ObservedObject private var prefs = Preferences.shared
    /// 订阅设备表：否则「自动识别为」会停在窗口打开那一刻，插拔后也不再更新。
    @ObservedObject private var attribution = DeviceAttribution.shared

    /// 与 DeviceAttribution 用的持久键保持一致（builtin / pid@loc / pid@name）。
    private var deviceKey: String {
        DeviceKey.make(builtIn: device.builtIn,
                       productID: device.productID,
                       locationID: device.locationID,
                       product: device.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: device.builtIn ? "laptopcomputer" : "computermouse")
                    .foregroundStyle(.secondary)
                // 同名设备（两个罗技接收器的 Product 都是 "USB Receiver"）追加 PID / USB 位置，
                // 否则用户会以为列表重复了、也不知道接管覆盖了哪几台（2026-11-10）。
                Text(DeviceLabel.disambiguate(
                        device.name,
                        productID: device.productID,
                        locationID: device.locationID,
                        ambiguous: DeviceLabel.hasSameNameSibling(
                            name: device.name, in: controller.devices.map(\.name))))
                    .font(.system(size: 12, weight: .medium))
                if device.builtIn {
                    Text("内置").font(.system(size: 9)).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15)).cornerRadius(3)
                }
                Spacer()
                Text(device.transport).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            let accel = controller.currentAcceleration(for: device)
            let res = controller.currentResolution(for: device)
            let linear = controller.currentLinearScaling(for: device)
            let accelText = linear == 1 ? "线性 1:1" : String(format: "%.3f", accel / 65536)
            let linearText = linear == 1 ? "开" : (linear == nil ? "无" : "关")
            Text(verbatim: "实时  加速度 \(accelText) · 线性缩放 \(linearText)"
                + " · 分辨率 \(Int(res / 65536))（只读）")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            // 设备级滚动判定（v1.5.0）：只纠正这一台，不动其它设备，
            // 也不再把「忽略触控板」当全局开关一刀切。
            HStack(spacing: 6) {
                Text("滚动判定").font(.system(size: 10)).foregroundStyle(.secondary)
                Picker("滚动判定", selection: Binding(
                    get: { prefs.deviceVerdicts[deviceKey] ?? .auto },
                    set: { v in
                        if v == .auto { prefs.deviceVerdicts.removeValue(forKey: deviceKey) }
                        else { prefs.deviceVerdicts[deviceKey] = v }
                    })) {
                    ForEach(DeviceVerdict.allCases, id: \.self) { v in
                        Text(v.label).tag(v)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                Text("自动识别为：\(attribution.devices.first { $0.key == deviceKey }?.capability.label ?? "未探明")")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .smooseHelp(.deviceRow)
    }
}

// MARK: - 修饰键透传

struct ModifierBypassRow: View {
    let title: String
    @Binding var mask: UInt64
    var help: HelpKey? = nil

    private static let options: [(String, UInt64)] = [
        ("⌘", CGEventFlags.maskCommand.rawValue),
        ("⌥", CGEventFlags.maskAlternate.rawValue),
        ("⌃", CGEventFlags.maskControl.rawValue),
        ("⇧", CGEventFlags.maskShift.rawValue),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12))
            HStack(spacing: 8) {
                ForEach(Self.options, id: \.1) { option in
                    Toggle(option.0, isOn: Binding(
                        get: { (mask & option.1) != 0 },
                        set: { on in
                            if on { mask |= option.1 } else { mask &= ~option.1 }
                        }))
                        .toggleStyle(.switch)
                }
                Spacer()
                Button("清除") { mask = 0 }
                    .font(.system(size: 10))
                    .smooseHelp(.bypassModifiers)
            }
        }
        .smooseHelp(help)
    }
}

// MARK: - 首次授权引导

struct OnboardingView: View {
    var onDone: () -> Void

    @State private var trusted = ScrollEngine.trusted(prompt: false)
    /// 系统设置跳转失败必须可见：旧实现直接 NSWorkspace.open(url)，
    /// 系统设置进程卡死时只会弹一句英文 "not responding"，App 自己什么都不说。
    @State private var launchFailure: String?
    private let ticker = Timer.publish(every: 0.8, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: trusted ? "checkmark.seal.fill" : "hand.raised.fill")
                .font(.system(size: 44))
                .foregroundStyle(trusted ? .green : .orange)

            Text(trusted ? "已授权" : "还差一步：辅助功能权限")
                .font(.title2.bold())
            Text("Smoose 在 HID 层接管滚轮事件，需要这个权限才能工作。滚动条不再一格一跳地走。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                step(1, "点「去授权」，打开「隐私与安全性」")
                step(2, "在「辅助功能」里勾选 Smoose")
                step(3, "回到这个窗口，上面会变成绿色 ✓")
            }
            .frame(width: 360)

            HStack(spacing: 10) {
                Button("去授权") { requestAuthorization() }
                .buttonStyle(.borderedProminent)
                if launchFailure != nil {
                    Button("重试") { requestAuthorization() }
                        .controlSize(.small)
                }
                Button(trusted ? "开始使用" : "稍后", action: onDone)
            }
            if let launchFailure {
                Text(launchFailure)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
            }
            Text("手动路径：\(AccessibilitySettingsLauncher.manualPath)。菜单栏图标为绿点即表示已生效，随时可在那里调参数。")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
        }
        .padding(28)
        .onReceive(ticker) { _ in
            let now = ScrollEngine.trusted(prompt: false)
            if now != trusted { trusted = now }
        }
        .onChange(of: trusted) { _, newValue in
            if newValue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { onDone() }
            }
        }
    }

    /// 用带 completion 的重载接住失败：成功清除提示，失败显示具体原因 + 重试。
    private func requestAuthorization() {
        NSApp.activate(ignoringOtherApps: true)
        _ = ScrollEngine.trusted(prompt: true)
        launchFailure = nil
        Task { @MainActor in
            switch await AccessibilitySettingsLauncher.open() {
            case .opened:
                launchFailure = nil
            case .failed(let reason):
                launchFailure = AccessibilitySettingsLauncher.failureMessage(reason: reason)
            }
        }
    }

    private func step(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index)").font(.system(size: 11, weight: .bold, design: .monospaced))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor.opacity(0.18)))
            Text(text).font(.system(size: 12))
            Spacer()
        }
    }
}

// MARK: - 组件

struct LabeledSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var unit: String = ""
    /// 有解释时：滑条下方常驻一行小字，同时整行挂悬停气泡。
    /// 常驻小字在窗口变窄或字号变大时会被压缩，悬停那条路不占布局。
    var help: HelpKey? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(verbatim: "\(String(format: "%.2f", value))\(unit)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
            if let help {
                Text(HelpText.text(help)).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .smooseHelp(help)
    }
}

// MARK: - 滚动曲线预览

/// 把当前「顺滑度」的插值曲线画出来，让滑条位置和实际手感对得上。
/// 没有这个预览时，用户只能来回拖滑条试手感，不知道自己调到哪一档。
struct ScrollCurvePreview: View {
    let profile: ScrollProfile
    /// 菜单栏面板宽度只有 320，去掉底部说明文字，只留图和数字
    var compact: Bool = false

    /// 采样窗口固定 0.5s：短于此看不出尾巴差别，长于此所有档位都贴顶。
    private static let duration: Double = 0.5

    private var samples: [(t: Double, progress: Double)] {
        ScrollCurve.samples(tau: profile.tau, duration: Self.duration)
    }

    private var settling: Double {
        ScrollCurve.settlingTime(tau: profile.tau)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("曲线预览").font(.system(size: 11, weight: .medium))
                Spacer()
                Text(verbatim: String(format: "95%% 到位 %.0f ms", settling * 1000))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Canvas { ctx, size in
                let pts = samples
                guard pts.count > 1 else { return }
                // 网格：0.5 与 1.0 两条虚线，给曲线一个参照
                for frac in [0.5, 1.0] {
                    var grid = Path()
                    let y = size.height * (1 - frac)
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(grid, with: .color(.secondary.opacity(0.18)),
                               style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                }
                var path = Path()
                for (i, p) in pts.enumerated() {
                    let x = size.width * (p.t / Self.duration)
                    let y = size.height * (1 - p.progress)
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                ctx.stroke(path, with: .color(.accentColor),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                // 末端点：标出「一格滚完」的最终位置
                if let last = pts.last {
                    let end = CGPoint(x: size.width, y: size.height * (1 - last.progress))
                    ctx.fill(Path(ellipseIn: CGRect(x: end.x - 2.5, y: end.y - 2.5,
                                                    width: 5, height: 5)),
                             with: .color(.accentColor))
                }
            }
            .frame(height: 54)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.06))
            )
            if !compact {
                Text("横轴 0–500ms，纵向是这一格滚轮走完的进度；尾巴越长越顺滑，越陡越干脆。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("滚动曲线预览，95% 到位约 \(Int(settling * 1000)) 毫秒"))
    }
}

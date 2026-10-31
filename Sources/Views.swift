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
                .toggleStyle(.switch)
                .font(.system(size: 13, weight: .medium))

            VStack(alignment: .leading, spacing: 10) {
                LabeledSlider(title: "距离倍率", value: $prefs.global.speed, range: 0.2...8, unit: "×",
                              help: "≈4× 接近 Chrome/Safari 原生距离，≈1.5× 接近原生 AppKit 控件")
                LabeledSlider(title: "滚轮行数", value: $prefs.global.wheelLines, range: 0.2...5, unit: " 行",
                              help: "每格滚轮走多少行（只影响滚轮鼠标，触控板不受影响；1 = 系统原样）")
                LabeledSlider(title: "顺滑度", value: $prefs.global.smoothness, range: 0...1, unit: "",
                              help: "越大尾巴越长，越小越干脆")
                LabeledSlider(title: "最小步长", value: $prefs.global.minStep, range: 0...30, unit: "px",
                              help: "低于此值的微动也会被放大，避免轻推无反应")
                ScrollCurvePreview(profile: prefs.global, compact: true)
            }
            .disabled(!prefs.masterEnabled)

            Divider()
            Section("轴") {
                Toggle("垂直平滑", isOn: $prefs.global.smoothVertical)
                Toggle("水平平滑", isOn: $prefs.global.smoothHorizontal)
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
                if let id = active.bundleID {
                    NavState.shared.focusAppID = id
                    NavState.shared.selectedTab = 2   // 每应用
                }
                openSmooseSettings()
            } label: {
                Label("为 \(active.name ?? "当前 App") 微调", systemImage: "slider.horizontal.3")
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

struct SettingsWindow: View {
    @StateObject private var nav = NavState.shared

    var body: some View {
        // 注意：使用 TabView(selection:) 时每个 tab 都必须设 .tag(n)，否则点击未设 tag 的页
        // 会让 selection 变 nil 并卡在最后一个有 tag 的页（2026-10-15 踩过）。
        TabView(selection: $nav.selectedTab) {
            GeneralTab().tabItem { Label("滚动", systemImage: "arrow.up.and.down") }.tag(0)
            PointerTab().tabItem { Label("指针", systemImage: "cursorarrow") }.tag(1)
            AppRulesTab().tabItem { Label("按应用", systemImage: "macwindow.on.rectangle") }.tag(2)
            ButtonsTab().tabItem { Label("按键", systemImage: "rectangle.3.offgrid") }.tag(3)
            AboutTab().tabItem { Label("关于", systemImage: "info.circle") }.tag(4)
        }
        // 固定 width/height 会把 NSHostingView 的约束锁死，窗口边缘拖不动；
        // 改成下限约束，允许用户按需放大（App.swift 里 styleMask 已含 .resizable）。
        .frame(minWidth: 560, minHeight: 520)
    }
}

struct GeneralTab: View {
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        Form {
            Section("全局") {
                Toggle("启用平滑滚动", isOn: $prefs.masterEnabled)
                Toggle("忽略触控板 / Magic Mouse（推荐）", isOn: $prefs.ignoreTrackpad)
            }
            Section("曲线") {
                LabeledSlider(title: "距离倍率", value: $prefs.global.speed, range: 0.2...8, unit: "×",
                              help: "≈4× 接近 Chrome/Safari 原生距离，≈1.5× 接近原生 AppKit 控件")
                LabeledSlider(title: "滚轮行数", value: $prefs.global.wheelLines, range: 0.2...5, unit: " 行",
                              help: "每格滚轮走多少行（只影响滚轮鼠标，触控板不受影响）")
                LabeledSlider(title: "顺滑度", value: $prefs.global.smoothness, range: 0...1, unit: "",
                              help: "插值时间常数，越大越顺滑")
                LabeledSlider(title: "最小步长", value: $prefs.global.minStep, range: 0...30, unit: "px",
                              help: "量化下限")
                ScrollCurvePreview(profile: prefs.global)
            }
            Section("轴向与方向") {
                HStack {
                    Toggle("垂直平滑", isOn: $prefs.global.smoothVertical)
                    Toggle("垂直反向", isOn: $prefs.global.reverseVertical)
                }
                HStack {
                    Toggle("水平平滑", isOn: $prefs.global.smoothHorizontal)
                    Toggle("水平反向", isOn: $prefs.global.reverseHorizontal)
                }
            }
            Section("临时透传") {
                ModifierBypassRow(
                    title: "按住以下键时不接管滚动",
                    mask: Binding(get: { prefs.global.bypassModifiers },
                                 set: { prefs.global.bypassModifiers = $0 })
                )
                Text("做精细操作（PR / 时间线 / 表格）时，按住 ⌥ 之类即可临时回到原生逐格滚动。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section("按住加速") {
                ModifierBypassRow(
                    title: "按住以下键时滚得更远",
                    mask: Binding(get: { prefs.global.boostModifiers },
                                 set: { prefs.global.boostModifiers = $0 })
                )
                LabeledSlider(title: "加速倍数", value: $prefs.global.boostFactor, range: 1.2...6, unit: "×",
                              help: "按住上面的键时，距离倍率再乘这个数；松开立刻恢复")
                Text("滚长文档 / 长网页时按住加速键，平时仍保持温和手感。"
                     + "与「按住透传」配同一个键时，以透传为准。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section("预设") {
                HStack {
                    ForEach(Array(ScrollProfile.presets.keys.sorted()), id: \.self) { name in
                        Button(name) {
                            if let p = ScrollProfile.presets[name] { prefs.global = p }
                        }
                    }
                    Spacer()
                    Button("恢复默认") { prefs.resetGlobal() }
                }
            }
            Section("开机") {
                LaunchToggle()
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Menu {
                    ForEach(candidates, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "?") {
                            if let id = app.bundleIdentifier, prefs.apps[id] == nil {
                                prefs.apps[id] = prefs.global
                            }
                        }
                    }
                    Divider()
                    Button("当前前台应用：\(active.name ?? "无")") {
                        if let id = active.bundleID, prefs.apps[id] == nil {
                            prefs.apps[id] = prefs.global
                        }
                    }
                } label: { Label("添加应用", systemImage: "plus") }
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
                    .labelsHidden()
                Button {
                    prefs.apps.removeValue(forKey: id)
                } label: { Image(systemName: "trash") }
                .buttonStyle(.plain)
            }
            // 常用两个参数直接可见，不用展开「细节参数」
            LabeledSlider(title: "距离倍率", value: $profile.speed, range: 0.2...8, unit: "×")
                .disabled(!profile.enabled)
            LabeledSlider(title: "顺滑度", value: $profile.smoothness, range: 0...1, unit: "")
                .disabled(!profile.enabled)
            DisclosureGroup("细节参数", isExpanded: $expanded) {
                LabeledSlider(title: "距离倍率", value: $profile.speed, range: 0.2...8, unit: "×")
                LabeledSlider(title: "滚轮行数", value: $profile.wheelLines, range: 0.2...5, unit: " 行")
                LabeledSlider(title: "顺滑度", value: $profile.smoothness, range: 0...1, unit: "")
                LabeledSlider(title: "最小步长", value: $profile.minStep, range: 0...30, unit: "px")
                HStack {
                    Toggle("垂直平滑", isOn: $profile.smoothVertical)
                    Toggle("水平平滑", isOn: $profile.smoothHorizontal)
                }
                HStack {
                    Toggle("垂直反向", isOn: $profile.reverseVertical)
                    Toggle("水平反向", isOn: $profile.reverseHorizontal)
                }
                ModifierBypassRow(title: "按住时透传滚动",
                                 mask: Binding(get: { profile.bypassModifiers },
                                              set: { profile.bypassModifiers = $0 }))
                Divider()
                Text("侧键绑定覆盖（留空走全局）").font(.system(size: 10)).foregroundStyle(.secondary)
                ForEach(3...5, id: \.self) { button in
                    Picker("按键 \(button)", selection: appBinding(for: button)) {
                        Text("跟随全局").tag(ButtonAction?.none)
                        ForEach(ButtonAction.allCases) { action in
                            Text(action.label).tag(ButtonAction?.some(action))
                        }
                    }
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
    @State private var lastDetectedButton: Int?
    @State private var testMonitor: Any?
    @State private var testLocalMonitor: Any?

    var body: some View {
        Form {
            Section("鼠标按键") {
                Toggle("交换后/前侧键（4 ↔ 5）", isOn: $prefs.swapBackForward)
                Toggle("抬起时触发（默认按下触发）", isOn: $prefs.triggerOnMouseUp)
                ForEach(3...5, id: \.self) { button in
                    Picker("按键 \(button)\(subtitle(for: button))", selection: binding(for: button)) {
                        ForEach(ButtonAction.allCases) { action in
                            Text(action.label).tag(action)
                        }
                    }
                }
            }
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
            Section {
                Text("绑定会吞掉该按键的原生点击事件。Logitech 侧键在 HID++ 模式下可能无法识别为按钮 4/5。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

// MARK: - 关于

struct AboutTab: View {
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var monitor: Monitor
    @ObservedObject private var updater = Updater.shared
    @State private var trusted = ScrollEngine.trusted(prompt: false)
    @State private var feedDraft: String = ""
    @State private var feedSaved = false

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

            Divider().frame(maxWidth: 420)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("诊断").font(.headline)
                    Text("辅助功能权限：\(trusted ? "已授权" : "未授权")")
                    Text("回环拦截计数：\(ScrollEngine.shared.echoGuardCount)")
                    Text("最近 Δ：\(String(format: "%.1f", monitor.rawDelta)) · \(monitor.sourceName)")
                }
                .font(.system(size: 11))
                VStack(spacing: 6) {
                    Button("请求/检查权限") {
                        _ = ScrollEngine.trusted(prompt: true)
                        trusted = ScrollEngine.trusted(prompt: false)
                    }
                    Button("重置全部设置") {
                        UserDefaults.standard.removeObject(forKey: "smoose.state")
                        prefs.load()
                    }
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
    @ObservedObject private var controller = PointerController.shared

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

            Form {
                Section("指针加速度") {
                    Toggle("接管并提供线性追踪（关掉 macOS 的加速曲线）", isOn: $prefs.pointerAccelManaged)
                    LabeledSlider(title: "加速度数值", value: $prefs.pointerAccelerationValue, range: 0...6, unit: "",
                                  help: "0 = 严格线性（推荐，等于 Windows/Linux 手感）；系统默认通常 2.5")
                    .disabled(!prefs.pointerAccelManaged)
                    HStack {
                        Button("取 0（线性）") { prefs.pointerAccelerationValue = 0 }
                        Button("取 2.5（接近系统默认）") { prefs.pointerAccelerationValue = 2.5 }
                    }
                    .disabled(!prefs.pointerAccelManaged)
                    Toggle("同时应用到内置触控板", isOn: $prefs.pointerIncludeBuiltIn)
                }
                Section("光标放大") {
                    Toggle("快速移动鼠标时放大光标图标", isOn: $prefs.cursorZoomEnabled)
                        .onChange(of: prefs.cursorZoomEnabled) { _, v in
                            CursorZoomController.shared.apply(v)
                        }
                    Text("即系统自带的「摇动鼠标指针以定位」：快速来回移动鼠标时，光标会膨胀放大，方便找到它。开关写入系统偏好，与「系统设置 → 辅助功能 → 显示」里的同名开关共享。")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section("设备") {
                    if controller.devices.isEmpty {
                        Text("尚未发现指针设备").foregroundStyle(.secondary).font(.system(size: 11))
                    } else {
                        ForEach(controller.devices) { device in
                            PointerDeviceRow(device: device, controller: controller)
                        }
                    }
                }
                Section("指针速度") {
                    Toggle("自定义移动速度倍率", isOn: $prefs.pointerSpeedManaged)
                    LabeledSlider(title: "速度倍率", value: $prefs.pointerSpeedFactor, range: 0.2...4, unit: "×",
                                  help: "1.0 = 系统原速。通过重写鼠标移动增量实现，按住拖拽时保持系统原速以保证选区精度。")
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
                Section("状态") {
                    Text(controller.appliedDescription)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(controller.lastWriteOk ? Color.secondary : Color.red)
                    Text("加速度存在 HID 进程内存里，重启或注销后回到系统默认；勾选「登录时启动」可开机自动套用。")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Section("罗技专属（Logitech HID++ 硬件直控）") {
                    LogitechSectionView()
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("重新检测") { controller.refresh(force: true) }
                Button("恢复系统默认") {
                    prefs.pointerAccelManaged = false
                    controller.restoreDefaults()
                    controller.refresh(force: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LogitechSectionView: View {
    @ObservedObject private var logi = LogitechHIDPP.shared
    @State private var selectedDPI: Int = 1000

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: logi.isConnected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(logi.isConnected ? Color.green : Color.secondary)
                Text(logi.statusMessage)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Button("刷新") { logi.scan() }
                    .font(.system(size: 11))
            }

            if logi.isConnected {
                HStack(spacing: 8) {
                    Text("硬件传感器 DPI：")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Picker("DPI", selection: $selectedDPI) {
                        ForEach([400, 800, 1000, 1200, 1600, 2000, 2400, 3200], id: \.self) { dpi in
                            Text("\(dpi) DPI").tag(dpi)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedDPI) { _, newDpi in
                        logi.setDPI(newDpi)
                    }
                }
                Text("无需常驻体积庞大的 Logi Options+，直接通过罗技 HID++ 协议向板载芯片写入 DPI 硬件预设。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct PointerDeviceRow: View {
    let device: PointerController.MouseDevice
    @ObservedObject var controller: PointerController

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: device.builtIn ? "laptopcomputer" : "computermouse")
                    .foregroundStyle(.secondary)
                Text(device.name).font(.system(size: 12, weight: .medium))
                if device.builtIn {
                    Text("内置").font(.system(size: 9)).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15)).cornerRadius(3)
                }
                Spacer()
                Text(device.transport).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            let accel = controller.currentAcceleration(for: device)
            let res = controller.currentResolution(for: device)
            Text(verbatim: "实时  加速度 \(String(format: "%.3f", accel / 65536))"
                + " · 分辨率 \(Int(res / 65536))（只读）")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 修饰键透传

struct ModifierBypassRow: View {
    let title: String
    @Binding var mask: UInt64

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
            }
        }
    }
}

// MARK: - 首次授权引导

struct OnboardingView: View {
    var onDone: () -> Void

    @State private var trusted = ScrollEngine.trusted(prompt: false)
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
                step(1, "点「去授权」，macOS 会弹出系统确认框")
                step(2, "在「辅助功能」列表里勾选 Smoose")
                step(3, "回到这个窗口，上面会变成绿色 ✓")
            }
            .frame(width: 360)

            HStack(spacing: 10) {
                Button("去授权") {
                    NSApp.activate(ignoringOtherApps: true)
                    _ = ScrollEngine.trusted(prompt: true)
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                Button(trusted ? "开始使用" : "稍后", action: onDone)
            }
            Text("菜单栏图标为绿点即表示已生效，随时可在那里调参数。")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
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
    var help: String? = nil

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
                Text(help).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
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

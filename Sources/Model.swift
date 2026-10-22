import Foundation
import Combine

// MARK: - 滚动参数档

struct ScrollProfile: Codable, Equatable {
    var enabled: Bool = true
    var smoothVertical: Bool = true
    var smoothHorizontal: Bool = true
    var reverseVertical: Bool = false
    var reverseHorizontal: Bool = false

    /// 距离倍率：每次滚轮事件最终走多远
    /// ≈4×：接近 Chrome / Safari 的原生行滚动距离；≈1.5×：接近原生 AppKit 控件的行滚动距离
    var speed: Double = 3.2
    var wheelLines: Double = 1.0
    /// 顺滑度 0...1 → 指数插值时间常数
    var smoothness: Double = 0.45
    /// 最小步长（px）：抹平极小 delta，避免「卡住不动」
    var minStep: Double = 6.0
    /// 按住这些修饰键时跳过接管、原样透传（CGEventFlags 位掩码）
    var bypassModifiers: UInt64 = 0

    /// 指数逼近时间常数（秒）。越大尾巴越长越顺滑
    var tau: Double { 0.006 + smoothness * smoothness * 0.26 }

    // 兼容旧配置：缺失 wheelLines 等新字段时用默认值
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        smoothVertical = try c.decodeIfPresent(Bool.self, forKey: .smoothVertical) ?? true
        smoothHorizontal = try c.decodeIfPresent(Bool.self, forKey: .smoothHorizontal) ?? true
        reverseVertical = try c.decodeIfPresent(Bool.self, forKey: .reverseVertical) ?? false
        reverseHorizontal = try c.decodeIfPresent(Bool.self, forKey: .reverseHorizontal) ?? false
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 3.2
        wheelLines = try c.decodeIfPresent(Double.self, forKey: .wheelLines) ?? 1.0
        smoothness = try c.decodeIfPresent(Double.self, forKey: .smoothness) ?? 0.45
        minStep = try c.decodeIfPresent(Double.self, forKey: .minStep) ?? 6.0
        bypassModifiers = try c.decodeIfPresent(UInt64.self, forKey: .bypassModifiers) ?? 0
    }

    static let presets: [String: ScrollProfile] = {
        var crisp = ScrollProfile()
        crisp.smoothness = 0.12
        crisp.minStep = 12
        crisp.speed = 3.0

        var silky = ScrollProfile()
        silky.smoothness = 0.85
        silky.minStep = 3
        silky.speed = 3.6

        var browser = ScrollProfile()
        browser.speed = 4.0
        browser.smoothness = 0.4

        var nativeApp = ScrollProfile()
        nativeApp.speed = 1.6
        nativeApp.smoothness = 0.5

        // 聊天软件（微信 / QQ / Slack / Discord）：这类 App 自带滚动惯性，
        // 全局倍率叠上去会「起飞」，用较低倍率 + 较短尾巴
        var chat = ScrollProfile()
        chat.speed = 0.8
        chat.smoothness = 0.45
        chat.minStep = 2.5

        var bypass = ScrollProfile()
        bypass.enabled = false

        return ["默认": ScrollProfile(),
                "干脆": crisp,
                "丝滑": silky,
                "浏览器": browser,
                "原生 App": nativeApp,
                "聊天软件": chat,
                "跳过此 App": bypass]
    }()
}

// MARK: - 鼠标按键动作

enum ButtonAction: String, Codable, CaseIterable, Identifiable {
    case none
    case missionControl
    case launchpad
    case appSwitcher
    case showDesktop
    case back
    case forward
    case spaceLeft
    case spaceRight
    case screenshot
    case copy
    case paste
    case appExpose

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "不执行操作"
        case .missionControl: return "调度中心 Mission Control"
        case .launchpad: return "启动台 Launchpad"
        case .appSwitcher: return "切换应用 ⌘⇥"
        case .showDesktop: return "显示桌面"
        case .back: return "浏览器后退 ⌘["
        case .forward: return "浏览器前进 ⌘]"
        case .spaceLeft: return "左移一个桌面"
        case .spaceRight: return "右移一个桌面"
        case .screenshot: return "截图面板 ⇧⌘5"
        case .copy: return "复制 ⌘C"
        case .paste: return "粘贴 ⌘V"
        case .appExpose: return "App Exposé ⌃↓"
        }
    }
}

// MARK: - 持久化结构

struct StoredState: Codable {
    var masterEnabled: Bool = true
    var ignoreTrackpad: Bool = true
    var global: ScrollProfile = ScrollProfile()
    var apps: [String: ScrollProfile] = [:]
    var launchAtLogin: Bool = false
    var bindings: [String: String] = [:]
    var swapBackForward: Bool = false
    var triggerOnMouseUp: Bool = false
    var appBindings: [String: [String: String]] = [:]

    // 指针（LinearMouse 那一半）
    var pointerAccelManaged: Bool = false
    var pointerAccelerationValue: Double = 0
    var pointerIncludeBuiltIn: Bool = false
    var pointerSpeedManaged: Bool = false
    var pointerSpeedFactor: Double = 1.0
    /// 快速移动鼠标时放大光标图标
    var cursorZoomEnabled: Bool = false
    /// 每天自动检查一次更新（用户仍可随时手动检查）
    var autoCheckUpdates: Bool = true

    // 兼容旧版配置：缺失的键取默认值，避免新增字段后旧 JSON 解码失败丢配置
    init(masterEnabled: Bool = true, ignoreTrackpad: Bool = true, global: ScrollProfile = ScrollProfile(),
         apps: [String: ScrollProfile] = [:], launchAtLogin: Bool = false, bindings: [String: String] = [:],
         pointerAccelManaged: Bool = false, pointerAccelerationValue: Double = 0,
         pointerIncludeBuiltIn: Bool = false, pointerSpeedManaged: Bool = false,
        pointerSpeedFactor: Double = 1.0, cursorZoomEnabled: Bool = false,
        autoCheckUpdates: Bool = true,
        swapBackForward: Bool = false,
        triggerOnMouseUp: Bool = false, appBindings: [String: [String: String]] = [:]) {
        self.masterEnabled = masterEnabled
        self.ignoreTrackpad = ignoreTrackpad
        self.global = global
        self.apps = apps
        self.launchAtLogin = launchAtLogin
        self.bindings = bindings
        self.pointerAccelManaged = pointerAccelManaged
        self.pointerAccelerationValue = pointerAccelerationValue
        self.pointerIncludeBuiltIn = pointerIncludeBuiltIn
        self.pointerSpeedManaged = pointerSpeedManaged
        self.pointerSpeedFactor = pointerSpeedFactor
        self.cursorZoomEnabled = cursorZoomEnabled
        self.autoCheckUpdates = autoCheckUpdates
        self.swapBackForward = swapBackForward
        self.triggerOnMouseUp = triggerOnMouseUp
        self.appBindings = appBindings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        masterEnabled = try c.decodeIfPresent(Bool.self, forKey: .masterEnabled) ?? true
        ignoreTrackpad = try c.decodeIfPresent(Bool.self, forKey: .ignoreTrackpad) ?? true
        global = try c.decodeIfPresent(ScrollProfile.self, forKey: .global) ?? ScrollProfile()
        apps = try c.decodeIfPresent([String: ScrollProfile].self, forKey: .apps) ?? [:]
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        bindings = try c.decodeIfPresent([String: String].self, forKey: .bindings) ?? [:]
        pointerAccelManaged = try c.decodeIfPresent(Bool.self, forKey: .pointerAccelManaged) ?? false
        pointerAccelerationValue = try c.decodeIfPresent(Double.self, forKey: .pointerAccelerationValue) ?? 0
        pointerIncludeBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .pointerIncludeBuiltIn) ?? false
        pointerSpeedManaged = try c.decodeIfPresent(Bool.self, forKey: .pointerSpeedManaged) ?? false
        pointerSpeedFactor = try c.decodeIfPresent(Double.self, forKey: .pointerSpeedFactor) ?? 1.0
        cursorZoomEnabled = try c.decodeIfPresent(Bool.self, forKey: .cursorZoomEnabled) ?? false
        autoCheckUpdates = try c.decodeIfPresent(Bool.self, forKey: .autoCheckUpdates) ?? true
        swapBackForward = try c.decodeIfPresent(Bool.self, forKey: .swapBackForward) ?? false
        triggerOnMouseUp = try c.decodeIfPresent(Bool.self, forKey: .triggerOnMouseUp) ?? false
        appBindings = try c.decodeIfPresent([String: [String: String]].self, forKey: .appBindings) ?? [:]
    }

    /// 按键绑定解析：per-app 覆盖 > global。返回 nil 表示该 App 没有覆盖、走全局。
    func bindings(for bundleID: String?) -> [String: String] {
        if let id = bundleID, let custom = appBindings[id], !custom.isEmpty { return custom }
        return bindings
    }

    func profile(for bundleID: String?) -> ScrollProfile? {
        guard masterEnabled else { return nil }
        let p: ScrollProfile
        if let id = bundleID, let custom = apps[id] {
            p = custom
        } else {
            p = global
        }
        return p.enabled ? p : nil
    }
}

// MARK: - 全局偏好

/// 设置窗口的导航状态：让菜单栏面板能一键跳到「每应用」并聚焦当前 App
final class NavState: ObservableObject {
    static let shared = NavState()
    /// 0 滚动 / 1 每应用 / 2 指针 / 3 按键 / 4 关于
    @Published var selectedTab: Int = 0
    /// 需要聚焦（自动展开 + 高亮）的 bundle id
    @Published var focusAppID: String?
}

final class Preferences: ObservableObject {
    static let shared = Preferences()

    @Published var masterEnabled: Bool = true
    @Published var ignoreTrackpad: Bool = true
    @Published var global: ScrollProfile = ScrollProfile()
    @Published var apps: [String: ScrollProfile] = [:]
    @Published var launchAtLogin: Bool = false
    @Published var bindings: [String: String] = [:]
    @Published var pointerAccelManaged: Bool = false
    @Published var pointerAccelerationValue: Double = 0
    @Published var pointerIncludeBuiltIn: Bool = false
    @Published var pointerSpeedManaged: Bool = false
    @Published var pointerSpeedFactor: Double = 1.0
    /// 快速移动鼠标时放大光标（系统「摇动鼠标指针以定位」）
    @Published var cursorZoomEnabled: Bool = false
    /// 自动检查更新（默认开；关掉后只有手动「检查更新」会联网）
    @Published var autoCheckUpdates: Bool = true
    @Published var swapBackForward: Bool = false
    @Published var triggerOnMouseUp: Bool = false
    @Published var appBindings: [String: [String: String]] = [:]

    private static let key = "smoose.state"
    private var saver: AnyCancellable?

    init() {
        load()
        saver = objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.persist() }
        }
    }

    var stored: StoredState {
        StoredState(masterEnabled: masterEnabled,
                    ignoreTrackpad: ignoreTrackpad,
                    global: global,
                    apps: apps,
                    launchAtLogin: launchAtLogin,
                    bindings: bindings,
                    pointerAccelManaged: pointerAccelManaged,
                    pointerAccelerationValue: pointerAccelerationValue,
                    pointerIncludeBuiltIn: pointerIncludeBuiltIn,
                    pointerSpeedManaged: pointerSpeedManaged,
                    pointerSpeedFactor: pointerSpeedFactor,
                    cursorZoomEnabled: cursorZoomEnabled,
                    autoCheckUpdates: autoCheckUpdates,
                    swapBackForward: swapBackForward,
                    triggerOnMouseUp: triggerOnMouseUp,
                    appBindings: appBindings)
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let s = try? JSONDecoder().decode(StoredState.self, from: data) else { return }
        masterEnabled = s.masterEnabled
        ignoreTrackpad = s.ignoreTrackpad
        global = s.global
        apps = s.apps
        launchAtLogin = s.launchAtLogin
        bindings = s.bindings
        pointerAccelManaged = s.pointerAccelManaged
        pointerAccelerationValue = s.pointerAccelerationValue
        pointerIncludeBuiltIn = s.pointerIncludeBuiltIn
        pointerSpeedManaged = s.pointerSpeedManaged
        pointerSpeedFactor = s.pointerSpeedFactor
        cursorZoomEnabled = s.cursorZoomEnabled
        autoCheckUpdates = s.autoCheckUpdates
        swapBackForward = s.swapBackForward
        triggerOnMouseUp = s.triggerOnMouseUp
        appBindings = s.appBindings
    }

    func persist() {
        let s = stored
        ScrollEngine.shared.apply(s)
        PointerController.shared.apply(force: false)
        guard let data = try? JSONEncoder().encode(s) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    func resetGlobal() {
        global = ScrollProfile()
    }
}

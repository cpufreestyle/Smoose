import Foundation
import IOKit
import IOKit.hid
import IOKit.hidsystem

/// 「关闭加速」的正确语义（对标 LinearMouse `PointerDevice.pointerAcceleration`）。
///
/// **2026-11-06 二次纠正**：把 `HIDMouseAcceleration` 写成 0 只是「最小加速度」，
/// 系统仍然走速度相关的加速曲线 —— 低速增益 < 1，起步发黏、速度上来才跟手，
/// 正是用户说的「静止一段时间后启动慢，然后慢慢恢复正常」。
/// 静置 70 秒采样读数一直是 0，把全部 HID 服务也改成 0 后用户反馈「还是黏」，
/// 才确认「0 ≠ 关闭加速」，前两轮盯的「值被系统重置」根本没发生。
///
/// LinearMouse 的做法（已核对源码 `Modules/PointerKit/.../PointerDevice.swift`）：
///  - 值 **-1**（IOFixed = -65536）表示「加速与灵敏度均禁用」，即 1:1 线性；
///  - macOS Sonoma+ 还要把**设备实例**的 `HIDUseLinearScalingMouseAcceleration` 置 1，
///    才会切到线性缩放路径。该键在 `IOHIDSystem` 的全局默认字典里是 1，
///    但设备实例上可能是 null —— 只写全局/只写 0 都不生效。
enum PointerAccelPolicy {
    static let linearKey = "HIDUseLinearScalingMouseAcceleration"
    static let ioFixedScale: Double = 65536.0
    static let disabledIOFixed: Int = -65536

    /// UI 数值 0 = 线性（1:1）；> 0 = 自定义加速度（系统曲线）。
    static func plan(value: Double) -> (ioFixed: Int, linear: Int) {
        if value <= 0.0001 { return (disabledIOFixed, 1) }
        return (Int((value * ioFixedScale).rounded()), 0)
    }

    static func isLinear(value: Double) -> Bool { value <= 0.0001 }

    /// 线性缩放键不是所有设备都支持：本机 USB Receiver 写入回显成功、读回仍是 null
    /// （`hidutil --set` 用整数 1 / 布尔 true 都试过，结果一样）。LinearMouse 用
    /// `initialUseLinearScalingMouseAcceleration != nil` 判断支持与否，不支持时回退到
    /// 只写 -1 —— -1 本身就是「加速与灵敏度均禁用」，不需要 linear 标志。
    /// 返回 (是否支持, 应存入签名的读数, 本次是否算成功)。
    /// 不支持时**必须**返回 ok=true：否则界面会常驻红色「写入未生效」，
    /// 且把「实际回读 nil」存进签名后又会短路，看起来像修好了其实是失败态。
    static func linearOutcome(before: Int?, after: Int?, expected: Int)
        -> (supported: Bool, settled: Int?, ok: Bool) {
        let supported = before != nil || after != nil
        if !supported { return (false, nil, true) }
        let ok = after == expected
        // 成功存期望值；失败存实际回读值，让下一轮签名继续不同从而重试。
        return (true, ok ? expected : after, ok)
    }

    // MARK: - 设备范围（2026-11-06 第三轮修正）

    /// 内建触控板**恒不参与**加速度写入。真机实测：写 `HIDMouseAcceleration = -1`
    /// 读回 0.000（写入未生效），线性缩放标志也不支持；把它算进 eligible 只会让
    /// 「状态」区整段常驻红字，而那台设备其实从来没被接管过 —— 是「假失败」。
    /// 用枚举而不是 Bool，是为了让「为什么跳过」能在断言里表达清楚。
    static func scope(builtIn: Bool) -> PointerAccelScope {
        builtIn ? .systemManagedBuiltIn : .externalMouse
    }

    /// 只返回真正要写入的 registryID。参数用 (rid, builtIn) 元组，
    /// 便于 harness 不碰 IOKit 就能断言筛选结果。
    /// 旧开关 `pointerIncludeBuiltIn` **不再**影响设备范围：它只保留存档兼容，
    /// 曾经把不支持写入的触控板拉进列表，造成状态区误报。
    static func eligible(_ devices: [(rid: UInt64, builtIn: Bool)]) -> [UInt64] {
        devices.compactMap { scope(builtIn: $0.builtIn) == .externalMouse ? $0.rid : nil }
    }
}

/// 加速度接管的设备分类：跳过也要有明确原因。
enum PointerAccelScope: Equatable {
    case externalMouse
    case systemManagedBuiltIn
}

/// 状态区合成：跳过项必须**可见**，但绝不参与成功判定。
/// 「跳过就报绿」和「跳过就报红」都是假的：前者掩盖未接管，后者把硬件能力缺失
/// 误报成写入失败（旧版整段红字就是这么来的）。
enum PointerAccelStatus {
    /// 带设备名 + 原因，不能是空字符串（静默跳过＝另一种假绿）。
    static func skippedLine(name: String) -> String {
        "\(name)：内建触控板由系统管理（不写入加速度）"
    }

    /// 整体成功只由「真正执行过加速度写入的外接鼠标」决定。
    /// 空结果必须判红：只有触控板、或外接设备读不到参数时，不能报「已接管」。
    static func allOK(_ writeResults: [Bool]) -> Bool {
        !writeResults.isEmpty && writeResults.allSatisfy { $0 }
    }
}

/// 加速度接管签名的输入快照（纯数据，供 harness 离线断言）。
struct PointerAccelSnapshot {
    var managed: Bool
    var value: Double
    /// 历史兼容位：设备范围已不由开关决定，apply 恒传 false；
    /// 保留字段是为了不改动已有存档结构与 I 段签名断言。
    var includeBuiltIn: Bool
    /// (registryID, 当前加速度读数)；nil = 该设备读不到参数，不参与托管
    var readings: [(rid: UInt64, current: Double?)]
    /// (registryID, HIDUseLinearScalingMouseAcceleration 当前读数)。
    /// 默认空数组让 I 段旧构造继续编译；K 段专门验它参与签名。
    var linear: [(rid: UInt64, flag: Int?)] = []
}

enum PointerAccelSignature {
    /// 签名**必须**包含每个设备的当前加速度读数**和**线性缩放标志。
    ///
    /// 只由「配置值 + registryID 列表」组成时，系统把 HID 参数改回去完全看不见，
    /// apply(force:false) 会永久短路。2026-11-06 又补上 linear 读数：设备重新枚举时
    /// 线性缩放标志也会丢，漏掉它同样会「读数全绿、手感没变」。
    static func make(_ s: PointerAccelSnapshot) -> String {
        let devs = s.readings.map { r in
            "\(r.rid):" + (r.current.map { String(Int($0.rounded())) } ?? "na")
        }.sorted().joined(separator: ",")
        let lin = s.linear.map { r in
            "\(r.rid):" + (r.flag.map { "\($0)" } ?? "na")
        }.sorted().joined(separator: ",")
        return "\(s.managed)|\(s.value)|\(s.includeBuiltIn)|\(devs)|L:\(lin)"
    }
}

/// 指针控制：直接改写 IOHIDSystem 的 HID 参数，等价于 LinearMouse 的核心能力。
///
/// 实现要点 / 踩坑记录：
///  1. 参数都是 IOFixed（16.16）整数：HIDMouseAcceleration = 163840 → 2.5
///  2. 老路线 `IOServiceOpen(IOHIDSystem, kIOHIDServerConnectType)` 在现代 macOS 被拒绝
///     （返回 0xE00002BD），必须走 `IOHIDEventSystemClient` + `IOHIDServiceClient`
///  3. 每个设备的加速度存在哪个键由 `HIDPointerAccelerationType` 指定
///     （外接鼠标通常是 HIDMouseAcceleration，触控板是 HIDTrackpadAcceleration）
///  4. `HIDPointerResolution`（指针速度）只能从 IORegistry 读到，写不回去
///     —— 所以在现代 macOS 上「指针速度倍率」做不到，这里只做加速度控制
final class PointerController: ObservableObject {
    static let shared = PointerController()

    struct MouseDevice: Identifiable {
        let client: IOHIDServiceClient
        let registryID: UInt64
        let name: String
        let transport: String
        let builtIn: Bool
        let accelKey: String
        var id: UInt64 { registryID }
    }

    @Published private(set) var devices: [MouseDevice] = []
    @Published private(set) var baselines: [UInt64: Double] = [:]
    /// 首次见到设备时的线性缩放标志，供「恢复系统默认」用；缺失 = 原本没这个属性。
    private var linearBaselines: [UInt64: Int] = [:]
    @Published private(set) var appliedDescription: String = "尚未初始化"
    @Published private(set) var lastWriteOk: Bool = true

    private let hidClient = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    /// 兜底轮询：8 秒一次，只读缓存设备的当前加速度，对漂移的设备重写。
    /// 2026-11-06：原实现是 60 秒 + 「配置值 + rid 列表」签名短路，系统把 HID 参数
    /// 重置回默认时两者都不变，于是永远不会纠正。轮询本身不再全量枚举 IOKit
    ///（设备插拔改由 IOHIDManager 回调驱动），所以 8 秒一次只是几次属性读。
    private var pollTimer: Timer?
    private var hidManager: IOHIDManager?
    private var matchCallback: IOHIDDeviceCallback?
    private var removalCallback: IOHIDDeviceCallback?
    private var pendingRefresh: DispatchWorkItem?

    private static let accelTypeKey = "HIDPointerAccelerationType"
    private static let accelFallbackKey = "HIDMouseAcceleration"
    private static let resolutionKey = "HIDPointerResolution"

    private var appliedSignature = ""

    // MARK: - 生命周期

    func start() {
        refresh(force: true)
        startDeviceWatch()
        // 兜底轮询：只在「已接管加速度」时才有意义；直接 apply 而不重新枚举设备。
        pollTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
            guard let self, Preferences.shared.pointerAccelManaged else { return }
            self.apply(force: false)
        }
        // 配置变更 → 立刻重新套用。用户拖「加速度数值」滑条时不再等下一个轮询周期，
        // 这是原来 6 秒轮询唯一真正有用的场景，现在改成事件驱动。
        NotificationCenter.default.addObserver(forName: .smoosePointerConfigChanged, object: nil,
                                               queue: .main) { [weak self] _ in
            self?.refresh(force: false)
        }
    }

    // MARK: - 设备发现

    func refresh(force: Bool) {
        guard let services = IOHIDEventSystemClientCopyServices(hidClient) as? [IOHIDServiceClient] else {
            return
        }

        var found: [MouseDevice] = []
        var newBaselines = baselines
        var newLinearBaselines = linearBaselines

        for service in services {
            guard IOHIDServiceClientConformsTo(service,
                                               UInt32(kHIDPage_GenericDesktop),
                                               UInt32(kHIDUsage_GD_Mouse)) != 0 else { continue }
            let name = (prop(service, "Product") as? String) ?? "未知指针设备"
            let transport = (prop(service, "Transport") as? String) ?? ""
            let builtInFlag = (prop(service, "Built-In") as? NSNumber)?.boolValue
            let builtIn = builtInFlag ?? (transport == "FIFO" || transport.localizedCaseInsensitiveContains("SPI"))
            let accelKey = (prop(service, Self.accelTypeKey) as? String) ?? Self.accelFallbackKey
            guard let rid = (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value else { continue }

            found.append(MouseDevice(client: service,
                                     registryID: rid,
                                     name: name,
                                     transport: transport,
                                     builtIn: builtIn,
                                     accelKey: accelKey))

            // 首次见到该设备 → 记录系统默认加速度（供显示与「恢复系统默认」）。
            // 不能拿设备当前读数当默认：App 可能已经接管过（上一轮写成 0 或 -1），
            // 真机截图就出现过「系统默认 -1.000」，导致恢复按钮写回 -1 等于没恢复。
            if baselines[rid] == nil {
                let accel = Self.systemDefaultAcceleration()
                    ?? (prop(service, accelKey) as? NSNumber)?.doubleValue
                    ?? (prop(service, Self.accelFallbackKey) as? NSNumber)?.doubleValue
                if let accel { newBaselines[rid] = accel }
                if let lin = (prop(service, PointerAccelPolicy.linearKey) as? NSNumber)?.intValue {
                    newLinearBaselines[rid] = lin
                }
            }
        }

        DispatchQueue.main.async {
            self.devices = found
            self.baselines = newBaselines
            self.linearBaselines = newLinearBaselines
            self.apply(force: force)
        }
    }

    // MARK: - 应用

    func apply(force: Bool) {
        let prefs = Preferences.shared
        // 未开启「接管加速度」时不碰任何设备，把控制权完全交还系统
        guard prefs.pointerAccelManaged else {
            appliedSignature = ""
            DispatchQueue.main.async {
                self.lastWriteOk = true
                self.appliedDescription = "未接管加速度（系统默认）"
            }
            return
        }
        // 内建触控板恒不参与加速度写入（本机实测写 -1 读回 0）。
        // 旧开关 pointerIncludeBuiltIn 只是存档兼容字段，不再作为筛选条件。
        let eligible = devices.filter {
            PointerAccelPolicy.scope(builtIn: $0.builtIn) == .externalMouse
        }
        let skipped = devices.filter {
            PointerAccelPolicy.scope(builtIn: $0.builtIn) == .systemManagedBuiltIn
        }
        let want = prefs.pointerAccelerationValue
        let plan = PointerAccelPolicy.plan(value: want)
        let readings = eligible.map { (rid: $0.registryID,
                                       current: Self.readAcceleration($0),
                                       linear: Self.readLinearFlag($0)) }
        let signature = PointerAccelSignature.make(PointerAccelSnapshot(
            managed: true, value: want, includeBuiltIn: false,
            readings: readings.map { (rid: $0.rid, current: $0.current) },
            linear: readings.map { (rid: $0.rid, flag: $0.linear) }))
        // 加速度读数与线性缩放标志都参与签名：任一被系统改回去，这里必然不同
        if !force && signature == appliedSignature { return }

        var lines: [String] = []
        /// 只记录真正执行过写入的设备结果；跳过的触控板不进这个数组。
        var writeResults: [Bool] = []
        var settledAccel: [(rid: UInt64, current: Double?)] = []
        var settledLinear: [(rid: UInt64, flag: Int?)] = []
        for (index, device) in eligible.enumerated() {
            let beforeLinear = readings[index].linear
            guard let base = baselines[device.registryID] else {
                lines.append("\(device.name)：该设备不暴露加速度参数")
                settledAccel.append((rid: device.registryID, current: nil))
                settledLinear.append((rid: device.registryID, flag: nil))
                continue
            }
            // 先切线性缩放路径再写加速度：LinearMouse 改 resolution 后也要重套
            // acceleration 才生效，顺序反了可能只落地一半。
            _ = IOHIDServiceClientSetProperty(
                device.client, PointerAccelPolicy.linearKey as CFString,
                NSNumber(value: plan.linear))
            let okAccel = IOHIDServiceClientSetProperty(
                device.client, device.accelKey as CFString,
                NSNumber(value: plan.ioFixed))
            // 写后读回：setProperty 返回 true 但值没落地是真实存在的情况
            let backAccel = Self.readAcceleration(device)
            let backLinear = Self.readLinearFlag(device)
            let outcome = PointerAccelPolicy.linearOutcome(before: beforeLinear,
                                                           after: backLinear,
                                                           expected: plan.linear)
            let good = okAccel
                && (backAccel.map { abs($0 - Double(plan.ioFixed)) < 1 } ?? false)
                && outcome.ok
            writeResults.append(good)
            // 成功时存「期望值」，失败时存「实际回读值」—— 后者让下一轮签名继续不同，
            // 从而重试，而不是把一次失败固化成永久短路（旧实现的坑）。
            settledAccel.append((rid: device.registryID,
                                 current: good ? Double(plan.ioFixed) : backAccel))
            settledLinear.append((rid: device.registryID, flag: outcome.settled))
            let linearText = outcome.supported
                ? (backLinear.map { "\($0)" } ?? "na")
                : "不支持(回退 -1)"
            let mode = PointerAccelPolicy.isLinear(value: want)
                ? "线性 1:1（加速与灵敏度均禁用）"
                : String(format: "加速度 %.3f", want)
            lines.append("\(device.name)  \(mode)"
                         + " · 线性标志 \(linearText)"
                         + " · 回读 \(String(format: "%.3f", (backAccel ?? -1) / 65536.0))"
                         + "  系统默认 \(String(format: "%.3f", base / 65536.0))"
                         + (good ? "" : "  ⚠️ 写入未生效"))
        }
        // 跳过的触控板必须显式出现在状态行（不带警告），且不参与成功判定。
        for device in skipped {
            lines.append(PointerAccelStatus.skippedLine(name: device.name))
        }
        // 一台都没写成功不能报绿：只有触控板 / 外接设备读不到参数 = 实际没接管。
        let allOK = PointerAccelStatus.allOK(writeResults)

        appliedSignature = PointerAccelSignature.make(PointerAccelSnapshot(
            managed: true, value: want, includeBuiltIn: false,
            readings: settledAccel, linear: settledLinear))

        DispatchQueue.main.async {
            self.lastWriteOk = allOK
            self.appliedDescription = lines.isEmpty ? "没有可管理的指针设备" : lines.joined(separator: "\n")
        }
    }

    // MARK: - 设备插拔 / 重枚举

    /// 设备插入、拔除、以及鼠标省电挂起后被重新枚举时立刻全量重刷，不等 8 秒轮询。
    /// didWakeNotification 只覆盖整机睡眠唤醒，覆盖不到「鼠标自己睡了又醒」这一条，
    /// 而那正是 HIDMouseAcceleration 被系统恢复成默认的触发点。
    private func startDeviceWatch() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDPrimaryUsagePageKey: UInt32(kHIDPage_GenericDesktop),
            kIOHIDPrimaryUsageKey: UInt32(kHIDUsage_GD_Mouse)
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = manager
        // 单例与进程同寿命，passUnretained 即可（不必像 retain 那样永久泄漏一次）
        let box = Unmanaged.passUnretained(self).toOpaque()
        let fire: IOHIDDeviceCallback = { ctx, _, _, _ in
            guard let ctx else { return }
            Unmanaged<PointerController>.fromOpaque(ctx).takeUnretainedValue().scheduleForceRefresh()
        }
        matchCallback = fire
        removalCallback = fire
        IOHIDManagerRegisterDeviceMatchingCallback(manager, fire, box)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, fire, box)
    }

    /// 一个接收器常会连着冒出好几个 matching 回调，0.15s 合并成一次全量重刷。
    private func scheduleForceRefresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingRefresh?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.refresh(force: true) }
            self.pendingRefresh = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
        }
    }

    private static func readAcceleration(_ d: MouseDevice) -> Double? {
        guard let n = IOHIDServiceClientCopyProperty(d.client, d.accelKey as CFString) as? NSNumber else {
            return nil
        }
        return n.doubleValue
    }

    /// 系统默认加速度藏在 `IOHIDSystem` 的全局 `HIDParameters` 字典里
    /// （`com.apple.mouse.scaling` 对应的就是它的 HIDMouseAcceleration）。
    /// 走 IORegistry 只读，不需要 `IOServiceOpen`（`kIOHIDServerConnectType` 在现代
    /// macOS 会被拒 0xE00002BD）。读不到时由调用方降级到设备当前读数。
    private static func systemDefaultAcceleration() -> Double? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault,
                                            "IOService:/IOResources/IOHIDSystem")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let raw = IORegistryEntryCreateCFProperty(
            entry, "HIDParameters" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let dict = raw as? [String: Any],
              let n = dict[Self.accelFallbackKey] as? NSNumber else { return nil }
        return n.doubleValue
    }

    private static func readLinearFlag(_ d: MouseDevice) -> Int? {
        guard let n = IOHIDServiceClientCopyProperty(
            d.client, PointerAccelPolicy.linearKey as CFString) as? NSNumber else {
            return nil
        }
        return n.intValue
    }

    /// 恢复系统原始加速度：加速度值和「线性缩放」标志都要还原，
    /// 只把加速度写回 163840 而把 linear=1 留在设备上是「假恢复」。
    /// 全量还原（含内建触控板）：旧版本曾在勾选开关时写过触控板，
    /// 这里负责把那些历史写入一并清回原始值；新版本不会再写它。
    func restoreDefaults() {
        for device in devices {
            if let base = baselines[device.registryID] {
                _ = IOHIDServiceClientSetProperty(device.client, device.accelKey as CFString,
                                                  NSNumber(value: Int(base)))
            }
            // 首次枚举时设备上没这个属性 → 写 0（关闭线性缩放）回到系统曲线。
            let flag = linearBaselines[device.registryID] ?? 0
            _ = IOHIDServiceClientSetProperty(device.client,
                                              PointerAccelPolicy.linearKey as CFString,
                                              NSNumber(value: flag))
        }
        appliedSignature = "restored"
    }

    // MARK: - 读取

    private func prop(_ client: IOHIDServiceClient, _ key: String) -> CFTypeRef? {
        IOHIDServiceClientCopyProperty(client, key as CFString)
    }

    func prop(_ client: IOHIDServiceClient, key: String) -> CFTypeRef? {
        prop(client, key)
    }

    /// 当前加速度读数（用于界面显示）
    func currentAcceleration(for device: MouseDevice) -> Double {
        (prop(device.client, device.accelKey) as? NSNumber)?.doubleValue ?? 0
    }

    /// 当前线性缩放标志（用于界面显示；nil = 设备没这个属性）
    func currentLinearScaling(for device: MouseDevice) -> Int? {
        (prop(device.client, PointerAccelPolicy.linearKey) as? NSNumber)?.intValue
    }

    /// 指针分辨率（只读，写不回去，仅供展示）
    func currentResolution(for device: MouseDevice) -> Double {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(device.registryID))
        guard entry != 0 else { return 0 }
        defer { IOObjectRelease(entry) }
        guard let raw = IORegistryEntryCreateCFProperty(entry, Self.resolutionKey as CFString,
                                                        kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let number = raw as? NSNumber else { return 0 }
        return number.doubleValue
    }
}

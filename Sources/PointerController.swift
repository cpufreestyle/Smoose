import Foundation
import IOKit
import IOKit.hidsystem

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
    @Published private(set) var appliedDescription: String = "尚未初始化"
    @Published private(set) var lastWriteOk: Bool = true

    private let hidClient = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private var pollTimer: Timer?

    private static let accelTypeKey = "HIDPointerAccelerationType"
    private static let accelFallbackKey = "HIDMouseAcceleration"
    private static let resolutionKey = "HIDPointerResolution"

    private var appliedSignature = ""

    // MARK: - 生命周期

    func start() {
        refresh(force: true)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: true) { [weak self] _ in
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

            // 首次见到该设备 → 记录原始加速度，之后所有设置都相对它
            if baselines[rid] == nil {
                let accel = (prop(service, accelKey) as? NSNumber)?.doubleValue
                            ?? (prop(service, Self.accelFallbackKey) as? NSNumber)?.doubleValue
                if let accel { newBaselines[rid] = accel }
            }
        }

        DispatchQueue.main.async {
            self.devices = found
            self.baselines = newBaselines
            self.apply(force: force)
        }
    }

    // MARK: - 应用

    func apply(force: Bool) {
        let prefs = Preferences.shared
        // 未开启「接管加速度」时不碰任何设备，把控制权完全交还系统
        guard prefs.pointerAccelManaged else {
            DispatchQueue.main.async {
                self.lastWriteOk = true
                self.appliedDescription = "未接管加速度（系统默认）"
            }
            return
        }
        let eligible = devices.filter { prefs.pointerIncludeBuiltIn || !$0.builtIn }
        let signature = "\(prefs.pointerAccelManaged)|\(prefs.pointerAccelerationValue)|\(prefs.pointerIncludeBuiltIn)|"
            + eligible.map { String($0.registryID) }.sorted().joined(separator: ",")
        if !force && signature == appliedSignature { return }
        appliedSignature = signature

        var lines: [String] = []
        var allOK = true
        for device in eligible {
            guard let base = baselines[device.registryID] else {
                lines.append("\(device.name)：该设备不暴露加速度参数")
                continue
            }
            let want = prefs.pointerAccelManaged ? prefs.pointerAccelerationValue : base
            // UI 数值是浮点（0...6），IOFixed 16.16 需要乘 65536
            let ioFixed = Int((want * 65536.0).rounded())
            let ok = IOHIDServiceClientSetProperty(device.client, device.accelKey as CFString,
                                                   NSNumber(value: ioFixed))
            allOK = allOK && ok
            let back = (prop(device.client, device.accelKey) as? NSNumber)?.doubleValue ?? -1
            // want 已经是 UI 侧的浮点值（0...6），写出去时才乘 65536；
            // 回读值 / 基线是 IOFixed，要除回来。三者必须同一量纲才能对比
            // （早先把 want 又除了一次 65536，显示成 0.000，看着像写入失败 —— 2026-10-26 修）
            lines.append("\(device.name)  \(device.accelKey): \(String(format: "%.3f", want))"
                         + " 回读 \(String(format: "%.3f", back / 65536))"
                         + "  系统默认 \(String(format: "%.3f", base / 65536))")
        }

        DispatchQueue.main.async {
            self.lastWriteOk = allOK
            self.appliedDescription = lines.isEmpty ? "没有可管理的指针设备" : lines.joined(separator: "\n")
        }
    }

    /// 恢复系统原始加速度
    func restoreDefaults() {
        for device in devices {
            guard let base = baselines[device.registryID] else { continue }
            IOHIDServiceClientSetProperty(device.client, device.accelKey as CFString, NSNumber(value: Int(base)))
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

import Foundation
import Combine
import IOKit.hid
import CoreGraphics

/// 事件时间戳与设备最后一次上报的匹配窗口。
let DeviceAttributionWindowNanos: UInt64 = 50_000_000

// MARK: - 纯逻辑（harness 可直接编译断言）

/// 设备能力分类：按 HID 集合静态判定，不依赖事件表现。
enum DeviceCapability: String, Codable, Equatable {
    /// 真实触控面（Digitizer / TouchPad）：应受 `ignoreTrackpad` 保护。
    case touchSurface
    /// 滚轮类指针设备（GenericDesktop / Mouse）：应被平滑接管。
    case wheelMouse
    /// 读不到描述符：回落到事件启发式。
    case unknown

    var label: String {
        switch self {
        case .touchSurface: return "触控板"
        case .wheelMouse: return "滚轮鼠标"
        case .unknown: return "未知"
        }
    }
}

/// 设备持久键。
///
/// `registryID` 重新插拔后会变，不能当持久键；这里与 `GamePerf.PointerDeviceRef`
/// 用同一套物理身份（PID / LocationID），避免出现两套互相不认的设备身份。
enum DeviceKey {
    static func make(builtIn: Bool, productID: UInt32, locationID: UInt32, product: String) -> String {
        if builtIn { return "builtin" }
        if productID != 0, locationID != 0 { return "pid:\(productID)@loc:\(locationID)" }
        if productID != 0 { return "pid:\(productID)@name:\(product)" }
        return product.isEmpty ? "unknown" : "name:\(product)"
    }
}

/// 能力归类的优先级：一个设备可能有多个 HID 集合，触控面结论必须压过鼠标集合。
enum DeviceCapabilityClassifier {
    static func classify(conformsTouchSurface: Bool, conformsMouse: Bool) -> DeviceCapability {
        if conformsTouchSurface { return .touchSurface }
        if conformsMouse { return .wheelMouse }
        return .unknown
    }

    /// 合并同一设备键下多个集合的判定（只升不降）。
    static func merge(_ a: DeviceCapability, _ b: DeviceCapability) -> DeviceCapability {
        if a == .touchSurface || b == .touchSurface { return .touchSurface }
        if a == .wheelMouse || b == .wheelMouse { return .wheelMouse }
        return .unknown
    }
}

/// 三层判定（设计文档 §6）：设备显式覆盖 → 设备能力 → 事件启发式。
///
/// 不变式：`capability == nil` 且 `verdict == .auto` 时返回 `continuous && ignoreTrackpad`，
/// 与 v1.4.6 的实现逐字等价。
enum DeviceScrollPolicy {
    static func shouldIgnore(continuous: Bool,
                             ignoreTrackpad: Bool,
                             verdict: DeviceVerdict,
                             capability: DeviceCapability?) -> Bool {
        switch verdict {
        case .touchSurface: return true
        case .wheelMouse: return false
        case .auto: break
        }
        switch capability {
        case .touchSurface: return true
        case .wheelMouse: return false
        case .unknown, .none: return continuous && ignoreTrackpad
        }
    }
}

/// 只把「当前还插着的设备」当作候选。
///
/// 旧实现直接遍历 `lastSeenByKey`：拔掉接收器后那 50ms 内如果再来一个滚轮事件，
/// 已拔掉的设备仍会按旧时间戳抢走归属。这里把在线设备集合显式当成输入，
/// 纯函数形态便于 harness 用真源码钉死这个边界；同时间戳按设备键排序，避免字典遍历顺序
/// 让归属在两台设备间随机摇摆。
enum DeviceAttributionPolicy {
    static func closestKey(connectedKeys: Set<String>,
                           lastSeen: [String: UInt64],
                           timestamp: UInt64,
                           windowNanos: UInt64 = DeviceAttributionWindowNanos) -> String? {
        var bestKey: String?
        var bestDelta = UInt64.max
        for key in connectedKeys {
            guard let seen = lastSeen[key] else { continue }
            let delta = timestamp >= seen ? timestamp - seen : seen - timestamp
            guard delta <= windowNanos else { continue }
            let tieBreak = bestKey.map { key < $0 } ?? true
            if delta < bestDelta || (delta == bestDelta && tieBreak) {
                bestDelta = delta
                bestKey = key
            }
        }
        return bestKey
    }
}

/// 归属结果（供设置页展示与判定使用）。
struct AttributedDevice: Identifiable, Equatable {
    var key: String
    var name: String
    var capability: DeviceCapability
    var lastSeenNanos: UInt64
    var id: String { key }
}

// MARK: - 影子监听

/// 「事件 → 来源设备」归属。
///
/// CGEvent 本身不带设备标识，这里用 IOHIDManager **非独占**监听鼠标 / 触控面集合，
/// 每个设备只记录「最后一次上报的 mach 时间」，再由 `handleWheel` 用事件时间戳
/// 在 50ms 窗口内就近匹配。全程只读：不 open 设备、不 seize、不改写任何输入。
///
/// 任何环节失败（无输入监控权限 / 匹配不到 / 时间窗失配）都让 `device(for:)` 返回 nil，
/// 判定自动回落到事件启发式 —— 即当前版本的行为。
final class DeviceAttribution: ObservableObject {
    static let shared = DeviceAttribution()

    /// 当前插着的设备（设置页展示用）。插拔后刷新，否则「自动识别为」会停在窗口打开那一刻。
    @Published private(set) var devices: [AttributedDevice] = []

    /// 关联窗口：人手不可能在 50ms 内交替驱动两台设备产生连续滚动，
    /// 而单设备连发间隔通常 8–16ms，窗口足够覆盖。
    static let windowNanos: UInt64 = DeviceAttributionWindowNanos

    private let lock = NSLock()
    private var capabilityByKey: [String: DeviceCapability] = [:]
    private var nameByKey: [String: String] = [:]
    private var lastSeenByKey: [String: UInt64] = [:]
    /// 当前插着的设备（IOHIDDevice 裸指针 → 设备键）。插拔只在这个线程上改。
    private var keyByDevice: [UnsafeMutableRawPointer: String] = [:]

    private var manager: IOHIDManager?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var callbacks: [Any] = []

    /// 监听是否真的起来了。false 时功能整体降级，但滚动接管照常。
    private(set) var isRunning = false

    private init() {}

    // MARK: 生命周期

    func start() {
        guard !isRunning else { return }
        // 输入监控权限被明确拒绝时不要反复尝试：注册回调不会成功，
        // 且每次 open 都可能再次打扰用户。设备恒为 nil，判定回落启发式。
        if Self.inputMonitoringDenied {
            NSLog("[Smoose] 设备归属：输入监控权限被拒，降级为事件启发式")
            return
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: Int(kHIDPage_GenericDesktop),
             kIOHIDDeviceUsageKey: Int(kHIDUsage_GD_Mouse)],
            [kIOHIDDeviceUsagePageKey: Int(kHIDPage_GenericDesktop),
             kIOHIDDeviceUsageKey: Int(kHIDUsage_GD_Pointer)],
            [kIOHIDDeviceUsagePageKey: Int(kHIDPage_Digitizer),
             kIOHIDDeviceUsageKey: Int(kHIDUsage_Dig_TouchPad)],
            [kIOHIDDeviceUsagePageKey: Int(kHIDPage_Digitizer),
             kIOHIDDeviceUsageKey: Int(kHIDUsage_Dig_TouchScreen)],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let box = Unmanaged.passUnretained(self).toOpaque()

        let matched: IOHIDDeviceCallback = { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<DeviceAttribution>.fromOpaque(ctx).takeUnretainedValue()
                .register(device: device)
        }
        let removed: IOHIDDeviceCallback = { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<DeviceAttribution>.fromOpaque(ctx).takeUnretainedValue()
                .unregister(device: device)
        }
        let input: IOHIDValueCallback = { ctx, _, sender, value in
            guard let ctx, let sender else { return }
            let ts = IOHIDValueGetTimeStamp(value)
            guard ts != 0 else { return }
            Unmanaged<DeviceAttribution>.fromOpaque(ctx).takeUnretainedValue()
                .noteInput(device: sender, timestamp: ts)
        }
        callbacks = [matched, removed, input]
        IOHIDManagerRegisterDeviceMatchingCallback(manager, matched, box)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, removed, box)
        IOHIDManagerRegisterInputValueCallback(manager, input, box)

        self.manager = manager
        // 注意：IOHIDManager 是 CF 类型（__NSCFType），**不能**放进 weak 捕获列表 ——
        // 会直接触发 "Cannot form weak reference to instance of class __NSCFType" 崩溃（12:53 真机踩到）。
        let mgr = manager
        let t = Thread { [weak self, mgr] in
            guard let self else { return }
            let rl = CFRunLoopGetCurrent()!
            self.lock.lock(); self.runLoop = rl; self.lock.unlock()
            IOHIDManagerScheduleWithRunLoop(mgr, rl, CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            // 先登记一次已插入设备：部分设备在 schedule 后不会再补发 match 回调。
            if let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> {
                for d in set { self.register(device: d) }
            }
            self.lock.lock()
            self.isRunning = true
            let devices = Set(self.keyByDevice.values).count
            self.lock.unlock()
            // 真机验收唯一可靠信号：这条日志不出现 = 归属没起来（滚动仍照常）。
            NSLog("[Smoose] 设备归属监听已启动，登记 %d 台设备", devices)
            CFRunLoopRun()
        }
        t.name = "Smoose.DeviceAttribution"
        t.qualityOfService = QualityOfService.userInteractive
        self.thread = t
        t.start()
    }

    func stop() {
        lock.lock()
        let rl = runLoop
        let mgr = manager
        runLoop = nil
        manager = nil
        isRunning = false
        lastSeenByKey.removeAll()
        capabilityByKey.removeAll()
        nameByKey.removeAll()
        keyByDevice.removeAll()
        lock.unlock()
        guard let mgr else { return }
        if let rl { CFRunLoopStop(rl) }
        IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        DispatchQueue.main.async { [weak self] in self?.devices = [] }
    }

    private static var inputMonitoringDenied: Bool {
        // kIOHIDRequestTypeListenEvent 在 10.15 之前不存在；这里部署目标已是 14，可直接调用。
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeDenied
    }

    // MARK: 设备表（只在影子监听线程上被调用）

    private func register(device: IOHIDDevice) {
        let product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? ""
        let transport = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String) ?? ""
        let productID = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.uint32Value ?? 0
        let locationID = (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber)?.uint32Value ?? 0
        let builtInFlag = (IOHIDDeviceGetProperty(device, "Built-In" as CFString) as? NSNumber)?.boolValue
        let builtIn = builtInFlag ?? (transport == "FIFO" || transport.localizedCaseInsensitiveContains("SPI"))

        let key = DeviceKey.make(builtIn: builtIn, productID: productID,
                                 locationID: locationID, product: product)
        let touches = IOHIDDeviceConformsTo(device, UInt32(kHIDPage_Digitizer), UInt32(kHIDUsage_Dig_TouchPad))
            || IOHIDDeviceConformsTo(device, UInt32(kHIDPage_Digitizer), UInt32(kHIDUsage_Dig_TouchScreen))
        let mouse = IOHIDDeviceConformsTo(device, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse))
        let capability = DeviceCapabilityClassifier.classify(conformsTouchSurface: touches, conformsMouse: mouse)

        lock.lock()
        capabilityByKey[key] = DeviceCapabilityClassifier.merge(capabilityByKey[key] ?? .unknown, capability)
        if !product.isEmpty { nameByKey[key] = product }
        keyByDevice[Unmanaged.passUnretained(device).toOpaque()] = key
        lock.unlock()
        publishDevices()
    }

    private func unregister(device: IOHIDDevice) {
        lock.lock()
        if let key = keyByDevice.removeValue(forKey: Unmanaged.passUnretained(device).toOpaque()),
           !keyByDevice.values.contains(key) {
            // 同一物理设备可能有多个 HID 集合（接收器尤其常见）：最后一个集合移除时
            // 才清掉缓存，否则按同一设备键重新登记时会带着旧能力和旧时间戳复活。
            lastSeenByKey.removeValue(forKey: key)
            capabilityByKey.removeValue(forKey: key)
            nameByKey.removeValue(forKey: key)
        }
        lock.unlock()
        publishDevices()
    }

    private func noteInput(device: UnsafeMutableRawPointer, timestamp: UInt64) {
        lock.lock()
        if let key = keyByDevice[device] {
            if timestamp > (lastSeenByKey[key] ?? 0) { lastSeenByKey[key] = timestamp }
        }
        lock.unlock()
    }

    // MARK: 查询（tap 线程）

    /// 按事件时间戳找最近活跃的设备；窗口外或表为空返回 nil。
    func device(forTimestamp timestamp: UInt64) -> AttributedDevice? {
        lock.lock(); defer { lock.unlock() }
        let connectedKeys = Set(keyByDevice.values)
        guard let key = DeviceAttributionPolicy.closestKey(
            connectedKeys: connectedKeys,
            lastSeen: lastSeenByKey,
            timestamp: timestamp,
            windowNanos: Self.windowNanos) else { return nil }
        return AttributedDevice(key: key,
                                name: nameByKey[key] ?? key,
                                capability: capabilityByKey[key] ?? .unknown,
                                lastSeenNanos: lastSeenByKey[key] ?? 0)
    }

    /// `@Published` 必须在主线程改；监听线程只做快照，赋值转回主线程。
    private func publishDevices() {
        let snapshot = connectedDevices()
        DispatchQueue.main.async { [weak self] in self?.devices = snapshot }
    }

    /// 设置页用：当前插着的设备 + 已知能力。
    func connectedDevices() -> [AttributedDevice] {
        lock.lock(); defer { lock.unlock() }
        var seen: Set<String> = []
        var out: [AttributedDevice] = []
        for key in keyByDevice.values where !seen.contains(key) {
            seen.insert(key)
            out.append(AttributedDevice(key: key,
                                        name: nameByKey[key] ?? key,
                                        capability: capabilityByKey[key] ?? .unknown,
                                        lastSeenNanos: lastSeenByKey[key] ?? 0))
        }
        return out.sorted { $0.key < $1.key }
    }
}

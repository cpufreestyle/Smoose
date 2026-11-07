import Foundation
import IOKit
import IOKit.hid

// MARK: - HID++ 2.0 / 0x2201 (Adjustable DPI) 协议常量与纯函数
//
// 2026-11-06 真机探针结论（见 HANDOFF §4.9）：
//  - address 字节 = (function << 4) | swId(0x8)，所以 fn0..3 是 0x08/0x18/0x28/0x38。
//    旧实现写 0x03，且把 feature ID 的高字节 0x22 当成 feature index —— 设备从未接受过。
//  - feature index 必须由 root feature 的 getFeature(0x2201) 查询得到，本机 pid=0xc547 是 7，
//    另一个接收器 pid=0xc548 返回 0（明确不支持），不能对所有 0xFF00 设备无差别下发。
//  - DPI 列表是 16-bit big-endian 序列：具体档位 / 0xE000+step 步长编码 / 0x0000 结束。
//    本机回报 `00 00 64 e0 32 64 00` → 档位 [100, 25600]、步长 50，当前 5400、默认 1600。
//  报文格式对齐 libratbag `src/hidpp20.c` 的 ADJUSTABLE_DPI 实现。

public enum HIDPPDPICommand {
    public static let featureID: UInt16 = 0x2201
    public static let swID: UInt8 = 0x08
    public static let getSensorCount: UInt8 = 0x08
    public static let getSensorDPIList: UInt8 = 0x18
    public static let getSensorDPI: UInt8 = 0x28
    public static let setSensorDPI: UInt8 = 0x38
    public static let getFeature: UInt8 = 0x08   // root feature (index 0), fn0
}

public struct HIDPPDPIList: Equatable {
    public let sensorIndex: Int
    public let values: [Int]
    public let step: Int?
    public var min: Int { values.min() ?? 0 }
    public var max: Int { values.max() ?? 0 }
}

public enum HIDPPDPIParser {
    /// `p` 是响应的 parameters 区（从第 4 字节起，已去掉 reportID/devIdx/subId/address）。
    /// 返回 nil 表示报文太短或没解析出任何档位 —— 此时绝不能拿硬编码档位兜底。
    public static func parseList(_ p: [UInt8]) -> HIDPPDPIList? {
        guard p.count >= 3 else { return nil }
        var i = 1
        var values: [Int] = []
        var step: Int?
        while i + 1 < p.count {
            let v = (Int(p[i]) << 8) | Int(p[i + 1])
            if v == 0 { break }
            if v > 0xE000 { step = v - 0xE000 } else { values.append(v) }
            i += 2
        }
        guard !values.isEmpty else { return nil }
        return HIDPPDPIList(sensorIndex: Int(p[0]), values: values, step: step)
    }

    /// GET_SENSOR_DPI 响应：p[0]=sensorIndex，p[1..2]=当前 DPI，p[3..4]=默认 DPI（big-endian）
    public static func parseCurrent(_ p: [UInt8]) -> (current: Int, defaultValue: Int)? {
        guard p.count >= 5 else { return nil }
        return ((Int(p[1]) << 8) | Int(p[2]), (Int(p[3]) << 8) | Int(p[4]))
    }

    /// UI 档位 = 设备回报的具体档位 + 落在 [min,max] 且对齐步长的常用档位 + 当前值。
    /// 不再写死 400...3200：设备上限是多少就给到多少（本机 25600）。
    public static func selectableDPIs(_ list: HIDPPDPIList, current: Int? = nil) -> [Int] {
        let common = [100, 200, 400, 800, 1000, 1200, 1600, 2000, 2400, 3200,
                      4000, 6400, 8000, 12800, 16000, 25600]
        var out = Set(list.values)
        for v in common where v >= list.min && v <= list.max {
            if let s = list.step, s > 0, (v - list.min) % s != 0 { continue }
            out.insert(v)
        }
        if let c = current, c >= list.min && c <= list.max { out.insert(c) }
        return out.sorted()
    }

    /// SET_SENSOR_DPI 长报文（20 字节）。featureIndex 必须来自 getFeature 查询。
    public static func setRequest(featureIndex: UInt8, sensor: Int, dpi: Int) -> [UInt8] {
        var req = [UInt8](repeating: 0, count: 20)
        req[0] = 0x11                       // long report
        req[1] = 0x01                       // paired device index
        req[2] = featureIndex               // 不能用 0x22（那是 feature ID 高字节）
        req[3] = HIDPPDPICommand.setSensorDPI
        req[4] = UInt8(truncatingIfNeeded: sensor)
        let d = min(65535, max(0, dpi))
        req[5] = UInt8(truncatingIfNeeded: d >> 8)
        req[6] = UInt8(truncatingIfNeeded: d)
        return req
    }
}

/// 写入结果：只有「读回 == 目标值」才算成功。
/// 旧实现忽略 `IOHIDDeviceSetReport` 返回值、不读回，却无条件显示「已应用硬件 DPI」= 假绿。
public enum HIDPPDPIWriteVerdict: Equatable {
    case verified
    case setReportFailed
    case echoMismatch(Int)
    case readBackMismatch(Int)
    case noReadBack

    public var ok: Bool { self == .verified }

    public var reason: String {
        switch self {
        case .verified: return "读回确认"
        case .setReportFailed: return "报文未被驱动接受"
        case .echoMismatch(let v): return "设备回显 \(v) 与目标不符"
        case .readBackMismatch(let v): return "读回 \(v) 与目标不符"
        case .noReadBack: return "写入后读不到当前 DPI"
        }
    }
}

public enum HIDPPDPIWrite {
    /// 纯函数，便于 harness 反向验证：任一环缺失都必须判红。
    /// `echo == 0` 表示协议 v0 不回显（libratbag 允许），但仍必须读回校验。
    public static func verdict(setReportOK: Bool, echo: Int?, readBack: Int?, target: Int)
        -> HIDPPDPIWriteVerdict {
        guard setReportOK else { return .setReportFailed }
        if let e = echo, e != 0, e != target { return .echoMismatch(e) }
        guard let r = readBack else { return .noReadBack }
        return r == target ? .verified : .readBackMismatch(r)
    }
}

// MARK: - 硬件 DPI 快捷键切换后的自动同步（2026-11-06）
//
// 为什么是「主动读」而不是「等通知」：Solaar notifications.py 里 0x2201 没有
// DPI 变更分支，DPI 变化只在 ONBOARD_PROFILES(address 0x10) 事件里给出
// resolution_index，报文本身不带 DPI 数值；不少鼠标按 DPI 键根本不发通知。
// 所以唯一可靠的做法是周期性 GET_SENSOR_DPI(0x28) 读设备当前值。
//
// 为什么是「长连接」：接收器休眠后头 2~3 个 HID++ 请求会超时
// （真机 476ms / 489ms / 313ms），预热后每个 GET 约 25ms；每次重新打开都要重付
// 这笔预热成本。所以设置页可见期间保持一条连接，离开页面 / App 自己写入时释放。
//
// 为什么用 None 而不是 SeizeDevice：第一轮探针误判「None 收不到响应」，后来独立
// 进程 15/15 全部读到当前 DPI，证明那只是设备休眠预热，不是打开权限问题。
// None 不独占 HID++ 接口，Logi Options+ / Solaar 可以和 Smoose 并存；
// 只有 App 自己写入/探测时才由那两条链路短暂 seize，且会先停掉同步连接。

public enum HIDPPDPISyncOutcome: Equatable {
    case noChange
    case readFailed
    case ignoredWhileWriting
    case outOfRange(Int)
    case hardwareChanged(Int)
}

public enum HIDPPDPISync {
    /// 预热后单次 GET 约 25ms；300ms 一次既跟手也不让 HID++ 接口一直忙。
    public static let pollInterval: TimeInterval = 0.3
    public static let backoffThreshold = 3
    public static let backoffInterval: TimeInterval = 1.5
    /// 接收器休眠后的头几个请求必超时；不预热会把「刚打开页面」误报成读取失败。
    public static let warmupRequests = 3

    /// 同步决策：刻意区分「读失败 / 越界 / 正在写入 / 真变更」。
    /// 把读失败当成 noChange 会静默吞掉硬件切换，是另一种假绿。
    public static func outcome(baseline: Int, observed: Int?,
                               capability: HIDPPDPIList, writing: Bool)
        -> HIDPPDPISyncOutcome {
        guard !writing else { return .ignoredWhileWriting }
        guard let v = observed, v > 0 else { return .readFailed }
        guard v >= capability.min && v <= capability.max else { return .outOfRange(v) }
        return v == baseline ? .noChange : .hardwareChanged(v)
    }

    /// 硬件切换只更新显示，绝不回写硬件；文案必须把这一点说清楚。
    public static func hardwareStatus(_ dpi: Int) -> String {
        "鼠标快捷键切换 DPI → \(dpi) DPI（已同步显示，未回写硬件）"
    }

    public static func failureStatus(failures: Int, kept: Int) -> String {
        "自动同步读失败（连续 \(failures) 次），保留上次值 \(kept) DPI；可点「刷新」重新探测"
    }

    public static func outOfRangeStatus(_ dpi: Int, min: Int, max: Int) -> String {
        "设备回报 \(dpi) DPI 超出能力范围 \(min)–\(max)，本次同步已忽略"
    }

    public static func badge(watching: Bool) -> String {
        watching ? "自动同步中 · 硬件切档即时跟随"
                 : "自动同步已暂停（回到本页自动恢复）"
    }
}

// MARK: - 同步 HID++ 会话（只在后台串行队列使用，不阻塞主线程）

private final class HIDPPSession {
    let dev: IOHIDDevice
    private let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var responses: [[UInt8]] = []
    private var ctx: UnsafeMutableRawPointer?

    init(dev: IOHIDDevice) {
        self.dev = dev
        buf.initialize(repeating: 0, count: 64)
        ctx = Unmanaged.passUnretained(self).toOpaque()
    }

    deinit { buf.deallocate() }

    func start() {
        let cb: IOHIDReportCallback = { ctx, _, _, _, _, report, len in
            guard let ctx else { return }
            Unmanaged<HIDPPSession>.fromOpaque(ctx).takeUnretainedValue().responses.append(
                Array(UnsafeBufferPointer(start: report, count: max(0, len))))
        }
        IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, cb, ctx)
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    /// 返回命中的完整响应报文（20 字节）；超时重试 tries 次后返回 nil。
    func request(_ subId: UInt8, _ address: UInt8, _ params: [UInt8], tries: Int = 3) -> [UInt8]? {
        for _ in 0..<tries {
            var req: [UInt8] = [0x11, 0x01, subId, address] + params
            if req.count < 20 { req += [UInt8](repeating: 0, count: 20 - req.count) }
            responses = []
            let rc = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x11, &req, req.count)
            guard rc == kIOReturnSuccess else { continue }
            for _ in 0..<3 { CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.25, false) }
            if let hit = responses.first(where: {
                $0.count >= 7 && $0[0] == 0x11 && $0[1] == 0x01 && $0[2] == subId && $0[3] == address
            }) { return hit }
        }
        return nil
    }

    /// 自动同步轮询专用：命中即返回，不固定等 0.75s。
    /// 长连接预热后一次 GET 约 25ms；失败才等到 timeout，避免把每次轮询拖成 0.75s。
    func requestOnce(_ subId: UInt8, _ address: UInt8, _ params: [UInt8],
                     timeout: CFTimeInterval) -> [UInt8]? {
        var req: [UInt8] = [0x11, 0x01, subId, address] + params
        if req.count < 20 { req += [UInt8](repeating: 0, count: 20 - req.count) }
        responses = []
        let rc = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x11, &req, req.count)
        guard rc == kIOReturnSuccess else { return nil }
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        repeat {
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.02, false)
            if let hit = responses.first(where: {
                $0.count >= 7 && $0[0] == 0x11 && $0[1] == 0x01 && $0[2] == subId && $0[3] == address
            }) { return hit }
        } while CFAbsoluteTimeGetCurrent() < deadline
        return nil
    }

    /// 写入专用：返回 (setReport 是否成功, 设备回显 DPI)。
    func write(_ subId: UInt8, _ address: UInt8, _ params: [UInt8])
        -> (ok: Bool, echo: Int?) {
        var req: [UInt8] = [0x11, 0x01, subId, address] + params
        if req.count < 20 { req += [UInt8](repeating: 0, count: 20 - req.count) }
        responses = []
        let rc = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x11, &req, req.count)
        for _ in 0..<3 { CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.25, false) }
        if let hit = responses.first(where: {
            $0.count >= 7 && $0[0] == 0x11 && $0[1] == 0x01 && $0[2] == subId && $0[3] == address
        }) {
            let p = Array(hit[4...])
            if p.count >= 3 { return (rc == kIOReturnSuccess, (Int(p[1]) << 8) | Int(p[2])) }
        }
        return (rc == kIOReturnSuccess, nil)
    }

    func close() {
        IOHIDDeviceUnscheduleFromRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}

/// 设置页可见期间保持的一条非独占长连接，专用线程 + 自己的 runloop 轮询当前 DPI。
/// 只读：整个类里没有任何 SET_SENSOR_DPI / 0x38 报文，也不调用 SeizeDevice。
private final class HIDPPWatchSession {
    private let info: HIDPPProbeInfo
    private let onReading: (Int?) -> Void
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false
    private let done = DispatchSemaphore(value: 0)

    init(info: HIDPPProbeInfo, onReading: @escaping (Int?) -> Void) {
        self.info = info
        self.onReading = onReading
    }

    func start() {
        let t = Thread { [weak self] in
            guard let self else { return }
            self.run()
        }
        t.name = "app.smoose.hidpp.dpi-watch"
        t.start()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// 释放 seize 后再返回，否则 App 自己的写入 / 重新探测会拿到 ExclusiveAccess 失败。
    func stop() {
        lock.lock()
        cancelled = true
        let alreadyFinished = finished
        lock.unlock()
        if !alreadyFinished { _ = done.wait(timeout: .now() + 1.5) }
    }

    private func run() {
        defer {
            lock.lock(); finished = true; lock.unlock()
            done.signal()
        }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x046D] as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            onReading(nil); return
        }
        var target: IOHIDDevice?
        for dev in set {
            let page = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue ?? 0
            let devPID = UInt16(truncatingIfNeeded:
                (IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? NSNumber)?.uint64Value ?? 0)
            if page == 0xFF00, devPID == info.pid { target = dev; break }
        }
        guard let dev = target,
              IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            onReading(nil); return
        }
        let session = HIDPPSession(dev: dev)
        session.start()
        defer { session.close() }

        // 接收器休眠后头 2~3 个请求会超时（真机 476 / 489 / 313ms），
        // 不预热就会把刚打开页面的头几轮误报成「读取失败」。
        for _ in 0..<HIDPPDPISync.warmupRequests {
            if isCancelled { return }
            _ = session.requestOnce(info.featureIndex, HIDPPDPICommand.getSensorDPI,
                                    [UInt8(truncatingIfNeeded: info.sensor)], timeout: 0.4)
        }

        var failures = 0
        while !isCancelled {
            let resp = session.requestOnce(info.featureIndex, HIDPPDPICommand.getSensorDPI,
                                           [UInt8(truncatingIfNeeded: info.sensor)], timeout: 0.25)
            let value = resp.flatMap { HIDPPDPIParser.parseCurrent(Array($0[4...]))?.current }
            onReading(value)
            failures = value == nil ? failures + 1 : 0
            let pause = failures >= HIDPPDPISync.backoffThreshold
                ? HIDPPDPISync.backoffInterval : HIDPPDPISync.pollInterval
            // 分片 sleep，让 stop() 最多 50ms 就能打断（否则要等满 1.5s 退避）。
            let slices = max(1, Int(pause / 0.05))
            for _ in 0..<slices where !isCancelled {
                Thread.sleep(forTimeInterval: pause / Double(slices))
            }
        }
    }
}

// MARK: - 探测结果

struct HIDPPProbeInfo {
    var pid: UInt16
    var featureIndex: UInt8
    var sensor: Int
    var capability: HIDPPDPIList
    var current: Int
    var defaultDPI: Int
}

enum HIDPPProbeOutcome {
    case success(HIDPPProbeInfo)
    case unsupported(String)
    case noResponse(String)
    case noDevice
}

private enum HIDPPProbe {
    /// 在后台线程完整跑一遍探测。自己枚举设备，避免跨线程传 IOHIDDevice。
    static func run() -> HIDPPProbeOutcome {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x046D] as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return .noDevice }
        let candidates = set.filter {
            let page = (IOHIDDeviceGetProperty($0, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue ?? 0
            return page == 0xFF00
        }
        guard !candidates.isEmpty else { return .noDevice }

        var sawUnsupported = false
        var sawDevice = false
        for dev in candidates {
            let pid = UInt16(truncatingIfNeeded:
                (IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? NSNumber)?.uint64Value ?? 0)
            guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) == kIOReturnSuccess else {
                continue
            }
            sawDevice = true
            let s = HIDPPSession(dev: dev)
            s.start()
            defer { s.close() }

            guard let feat = s.request(0x00, HIDPPDPICommand.getFeature, [0x22, 0x01]), feat.count >= 5 else {
                continue
            }
            let index = feat[4]
            if index == 0 { sawUnsupported = true; continue }   // 该接收器明确不支持

            guard let listResp = s.request(index, HIDPPDPICommand.getSensorDPIList, [0x00]),
                  let list = HIDPPDPIParser.parseList(Array(listResp[4...])) else { continue }
            guard let curResp = s.request(index, HIDPPDPICommand.getSensorDPI, [0x00]),
                  let cur = HIDPPDPIParser.parseCurrent(Array(curResp[4...])) else { continue }

            return .success(HIDPPProbeInfo(pid: pid, featureIndex: index, sensor: list.sensorIndex,
                                           capability: list, current: cur.current,
                                           defaultDPI: cur.defaultValue))
        }
        if sawDevice {
            return sawUnsupported
                ? .unsupported("设备不支持 HID++ 0x2201（Adjustable DPI）特性")
                : .noResponse("设备未响应 HID++ 探测（可能处于休眠或接收器未配对）")
        }
        return .noDevice
    }
}

private enum HIDPPWrite {
    /// 在后台线程执行「写入 → 回显 → 读回」，返回纯函数判定结果。
    static func run(pid: UInt16, featureIndex: UInt8, sensor: Int, target: Int)
        -> (verdict: HIDPPDPIWriteVerdict, current: Int?) {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x046D] as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return (.setReportFailed, nil)
        }
        for dev in set {
            let page = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue ?? 0
            let devPID = UInt16(truncatingIfNeeded:
                (IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? NSNumber)?.uint64Value ?? 0)
            guard page == 0xFF00, devPID == pid,
                  IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) == kIOReturnSuccess else { continue }
            let s = HIDPPSession(dev: dev)
            s.start()
            defer { s.close() }

            let req = HIDPPDPIParser.setRequest(featureIndex: featureIndex, sensor: sensor, dpi: target)
            // setRequest 前 4 字节是 reportID/devIdx/subId/address，后面才是 parameters
            let params = Array(req[4...])
            let w = s.write(featureIndex, HIDPPDPICommand.setSensorDPI, params)
            var readBack: Int?
            if let curResp = s.request(featureIndex, HIDPPDPICommand.getSensorDPI, [UInt8(truncatingIfNeeded: sensor)]) {
                readBack = HIDPPDPIParser.parseCurrent(Array(curResp[4...]))?.current
            }
            return (HIDPPDPIWrite.verdict(setReportOK: w.ok, echo: w.echo,
                                          readBack: readBack, target: target), readBack)
        }
        return (.setReportFailed, nil)
    }
}

// MARK: - 对外控制器

public enum DPIProbeState: Equatable {
    case idle
    case probing
    case ready(HIDPPDPIList, current: Int, defaultDPI: Int)
    case unsupported(String)
    case failed(String)

    public var capability: HIDPPDPIList? {
        if case .ready(let l, _, _) = self { return l }
        return nil
    }
}

public final class LogitechHIDPP: ObservableObject {
    public static let shared = LogitechHIDPP()

    public struct LogiDevice: Identifiable, Equatable {
        public let id: String
        public let name: String
        public let isReceiver: Bool
        /// 0 / 空 = 尚未读到真实值，绝不填假档位
        public var currentDPI: Int = 0
        public var supportedDPIs: [Int] = []
    }

    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var devices: [LogiDevice] = []
    @Published public private(set) var statusMessage: String = "未连接罗技设备"
    @Published public private(set) var probeState: DPIProbeState = .idle
    @Published public private(set) var selectableDPIs: [Int] = []
    @Published public private(set) var currentDPI: Int = 0
    @Published public private(set) var isWatching: Bool = false
    @Published public private(set) var syncStatus: String = HIDPPDPISync.badge(watching: false)

    private var hidManager: IOHIDManager?
    /// 设备插拔回调（IOHIDManager 事件驱动，替代原来的 5 秒全量轮询）。
    private var matchCallback: IOHIDDeviceCallback?
    private var removalCallback: IOHIDDeviceCallback?
    private let queue = DispatchQueue(label: "app.smoose.hidpp", qos: .userInitiated)
    private var probing = false
    private var probeGeneration = 0
    private var probeInfo: HIDPPProbeInfo?

    // 自动同步：窗口 + 本页都可见才开连接。刻意**不看 App 是否前台**——
    // 硬件 DPI 快捷键恰恰是在 Smoose 不是前台时按的，失活就停等于永远同步不上。
    // 连接用 None 非独占打开，不会挡住 Logi Options+ / Solaar。
    private var windowVisible = false
    private var dpiPageVisible = false
    private var isWriting = false
    private var watchSession: HIDPPWatchSession?
    private var syncGeneration = 0
    private var syncFailures = 0

    private static let logitechVendorID = 0x046D

    public init() { setupManager() }

    private func setupManager() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [kIOHIDVendorIDKey: Self.logitechVendorID]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.hidManager = manager

        scan()
        let box = Unmanaged.passRetained(self).toOpaque()
        // IOHIDDeviceCallback 是 4 参 (context, result, device, sender)。
        matchCallback = { ctx, _, _, _ in
            guard let ctx else { return }
            Unmanaged<LogitechHIDPP>.fromOpaque(ctx).takeUnretainedValue().scan()
        }
        removalCallback = { ctx, _, _, _ in
            guard let ctx else { return }
            Unmanaged<LogitechHIDPP>.fromOpaque(ctx).takeUnretainedValue().scan()
        }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, matchCallback!, box)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, removalCallback!, box)
    }

    public func scan() {
        guard let manager = hidManager,
              let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !set.isEmpty else {
            DispatchQueue.main.async {
                self.isConnected = false
                self.devices = []
                self.probeInfo = nil
                self.probeState = .idle
                self.selectableDPIs = []
                self.currentDPI = 0
                self.statusMessage = "未发现罗技外设"
                self.updateWatch()   // 设备拔了就立刻释放 seize
            }
            return
        }

        var foundDevices: [LogiDevice] = []
        var hasReceiver = false
        for dev in set {
            let prod = (IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String) ?? "Logitech Device"
            let page = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue ?? 0
            if page == 0xFF00 { hasReceiver = true }
            let item = LogiDevice(id: "\(dev.hashValue)", name: prod,
                                  isReceiver: prod.localizedCaseInsensitiveContains("Receiver"))
            if !foundDevices.contains(where: { $0.name == prod }) { foundDevices.append(item) }
        }

        DispatchQueue.main.async {
            self.devices = foundDevices
            self.isConnected = !foundDevices.isEmpty
            // 不再凭 usagePage 就宣称「支持 HID++ 2.0」——是否支持由真实探测决定。
            self.statusMessage = hasReceiver
                ? "发现罗技 USB Receiver，正在探测 HID++ DPI 能力…"
                : "已连接罗技设备，正在探测 HID++ DPI 能力…"
            self.probeIfNeeded()
        }
    }

    /// 手动刷新入口（UI「刷新」按钮）。
    public func refresh() {
        probeGeneration += 1      // 作废仍在跑的旧探测，避免旧结果覆盖新状态
        probing = false
        probeInfo = nil
        probeState = .idle
        // 重新探测要自己 seize 设备，必须先释放同步长连接，否则 ExclusiveAccess 失败。
        updateWatch()
        scan()
        probeIfNeeded()
    }

    private func probeIfNeeded() {
        guard isConnected, !probing, probeInfo == nil else { return }
        probing = true
        probeGeneration += 1
        let generation = probeGeneration
        probeState = .probing
        statusMessage = "正在向设备查询 HID++ DPI 能力…"
        queue.async { [weak self] in
            let outcome = HIDPPProbe.run()
            DispatchQueue.main.async {
                guard let self, generation == self.probeGeneration else { return }
                self.probing = false
                self.apply(outcome)
            }
        }
    }

    private func apply(_ outcome: HIDPPProbeOutcome) {
        switch outcome {
        case .success(let info):
            probeInfo = info
            adoptCurrentDPI(info.current, info: info)
            statusMessage = "HID++ 0x2201 已探测：\(info.capability.min)–\(info.capability.max) DPI"
                + "（步进 \(info.capability.step ?? 0)），当前 \(info.current) DPI"
        case .unsupported(let why):
            probeInfo = nil
            probeState = .unsupported(why)
            selectableDPIs = []
            currentDPI = 0
            statusMessage = why + "；不显示档位，也不下发写入"
        case .noResponse(let why):
            probeInfo = nil
            probeState = .failed(why)
            selectableDPIs = []
            currentDPI = 0
            statusMessage = why + "；可点「刷新」重试"
        case .noDevice:
            probeInfo = nil
            probeState = .idle
            selectableDPIs = []
            currentDPI = 0
            statusMessage = "未发现 HID++ 接口（0xFF00）"
        }
        // 探测成功且页面可见 → 起同步；探测失败 → 释放已有连接。
        updateWatch()
    }

    /// 只有通过真实探测拿到能力才允许写入；写入后必须读回确认。
    public func setDPI(_ targetDPI: Int) {
        guard let info = probeInfo else {
            statusMessage = "未探测到 HID++ DPI 能力，拒绝下发写入"
            return
        }
        guard targetDPI >= info.capability.min && targetDPI <= info.capability.max else {
            statusMessage = "目标 DPI 超出设备回报范围 \(info.capability.min)–\(info.capability.max)"
            return
        }
        // 写入要自己 seize 设备：先释放同步长连接，否则 ExclusiveAccess 直接失败。
        isWriting = true
        updateWatch()
        statusMessage = "正在写入 \(targetDPI) DPI…"
        queue.async { [weak self] in
            let result = HIDPPWrite.run(pid: info.pid, featureIndex: info.featureIndex,
                                        sensor: info.sensor, target: targetDPI)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isWriting = false
                if result.verdict.ok {
                    self.adoptCurrentDPI(targetDPI, info: info)
                    self.statusMessage = "已应用硬件 DPI: \(targetDPI)（读回确认）"
                } else {
                    // 失败绝不更新 currentDPI，也不说「已应用」。
                    self.statusMessage = "写入失败：\(result.verdict.reason)"
                }
                self.syncFailures = 0
                self.updateWatch()   // 写入结束后恢复同步
            }
        }
    }

    // MARK: - 硬件 DPI 自动同步（对外只有「开/关可见性」，没有下发写入的入口）

    public func setSettingsVisible(_ visible: Bool) {
        windowVisible = visible
        updateWatch()
    }

    public func setDPIPageVisible(_ visible: Bool) {
        dpiPageVisible = visible
        updateWatch()
    }

    /// 门禁：设置窗口可见 + 指针页可见 + 没有正在写入 + 已拿到能力。
    /// 不含「App 是否前台」：用户按鼠标 DPI 键时 Smoose 通常不是前台。
    /// 条件不成立立刻关掉连接，让 App 自己的写入/探测能拿到独占访问。
    private func updateWatch() {
        let want = windowVisible && dpiPageVisible && !isWriting && probeInfo != nil
        if want {
            guard watchSession == nil, let info = probeInfo else { return }
            syncGeneration += 1
            let generation = syncGeneration
            let session = HIDPPWatchSession(info: info) { [weak self] reading in
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.syncGeneration else { return }
                    self.handleSyncReading(reading)
                }
            }
            watchSession = session
            isWatching = true
            syncStatus = HIDPPDPISync.badge(watching: true)
            syncFailures = 0
            session.start()
        } else if let session = watchSession {
            syncGeneration += 1        // 作废在途回调，避免旧会话覆盖新状态
            watchSession = nil
            isWatching = false
            syncStatus = HIDPPDPISync.badge(watching: false)
            session.stop()
        }
    }

    /// 只更新「显示状态」，绝不调用 setDPI / 下发 0x38 报文。
    private func handleSyncReading(_ reading: Int?) {
        guard let info = probeInfo else { return }
        let outcome = HIDPPDPISync.outcome(baseline: currentDPI, observed: reading,
                                           capability: info.capability, writing: isWriting)
        switch outcome {
        case .hardwareChanged(let dpi):
            adoptCurrentDPI(dpi, info: info)
            syncFailures = 0
            statusMessage = HIDPPDPISync.hardwareStatus(dpi)
        case .readFailed:
            syncFailures += 1
            if syncFailures >= HIDPPDPISync.backoffThreshold {
                statusMessage = HIDPPDPISync.failureStatus(failures: syncFailures, kept: currentDPI)
            }
        case .outOfRange(let dpi):
            statusMessage = HIDPPDPISync.outOfRangeStatus(dpi, min: info.capability.min,
                                                          max: info.capability.max)
        case .noChange:
            syncFailures = 0
        case .ignoredWhileWriting:
            break
        }
    }

    /// 统一维护 currentDPI / probeState / 可选档位 / 设备列表，避免几处状态不同步。
    /// 当前值不在设备具体档位里时 selectableDPIs 会把它加进去，Picker 选中项才有效。
    private func adoptCurrentDPI(_ dpi: Int, info: HIDPPProbeInfo) {
        currentDPI = dpi
        probeState = .ready(info.capability, current: dpi, defaultDPI: info.defaultDPI)
        selectableDPIs = HIDPPDPIParser.selectableDPIs(info.capability, current: dpi)
        for i in 0..<devices.count {
            devices[i].currentDPI = dpi
            devices[i].supportedDPIs = selectableDPIs
        }
    }
}

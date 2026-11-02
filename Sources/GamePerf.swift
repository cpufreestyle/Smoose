import Foundation
import Combine
import IOKit
import IOKit.hidsystem

// MARK: - 时基

/// `CGEvent.timestamp` 与 `mach_absolute_time()` 是同一时基，但两者都是「tick」不是「ns」，
/// 换算必须过 timebase。2026-11-02 实测：回调里 `mach_absolute_time() - event.timestamp`
/// 落在 0.2~8.8 ms（M 系列 Mac timebase 125/3），量级合理，证明可以直接相减。
///
/// 反面教材：`ScrollEngine.post()` 里合成事件时间戳用的是
/// `CACurrentMediaTime() * 1e9`，那个和 mach tick 差了几个数量级（实测
/// CACurrentMediaTime()*1e9 ≈ 4.3e14，而 event.timestamp ≈ 1.04e13），
/// **绝不能混用**。所以这里一律以 mach_absolute_time 为准。
enum MachClock {
    static let info: (numer: UInt32, denom: UInt32) = {
        var i = mach_timebase_info(numer: 0, denom: 0)
        mach_timebase_info(&i)
        // 极少数平台 denom 可能是 0，兜底成 1/1，避免除零
        if i.denom == 0 { return (1, 1) }
        return (i.numer, i.denom)
    }()

    static func ns(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(info.numer) / Double(info.denom)
    }

    static func ms(_ ticks: UInt64) -> Double { ns(ticks) / 1_000_000.0 }

    /// 间隔 tick 数。a 早于 b 时夹到 0，绝不返回负数（时钟回拨不能造出负延迟）。
    static func diff(_ a: UInt64, _ b: UInt64) -> UInt64 { a >= b ? a - b : 0 }

    /// 毫秒数换算成 tick 数（给采样窗口用）
    static func ticks(forMs ms: Double) -> UInt64 {
        guard ms > 0 else { return 0 }
        let ns = ms * 1_000_000.0
        return UInt64((ns * Double(info.denom) / Double(info.numer)).rounded())
    }

    /// 把事件时间戳归一到 mach tick 时基。**进来的一切时间戳都必须过这里。**
    ///
    /// 2026-11-02 实测：`CGEvent.timestamp` 的时基不统一，HID 事件和注入事件不是一套：
    ///   · 真实鼠标等 HID 设备事件 —— mach tick，与 `mach_absolute_time()` 同基
    ///     （tap 回调内实测比值 1.0000，差值 0.13~5.09 ms，量级合理）；
    ///   · 经 `CGEvent.post(tap: .cghidEventTap)` 注入的事件 —— **开机以来的纳秒数**
    ///     （同一时刻 tick ≈ 1.05e13、纳秒 ≈ 4.38e14，比值 41.6662 ≈ timebase 125/3；
    ///      按 uptime 5 天 1.6 小时反查也完全吻合）。
    /// 不归一化的后果（都实测复现过）：纳秒值永远大于 now，`diff` 恒为 0，
    /// 于是 2 秒窗口过滤整体失效、事件率被算小约 41.67 倍、指针延迟恒显示 0。
    /// 交接文档里「timestamp 与 mach_absolute_time 同时基」那条只对 HID 事件成立，
    /// 别据此跳过归一化。
    static func normalize(_ ts: UInt64, now: UInt64) -> UInt64 {
        // 纳秒值比当前 tick 大一个数量级以上。用 8 倍做判据：
        // timebase 最小 1/1（此时两者同值，判据不可能误触），
        // 而纳秒与 tick 之间至少差 1 倍，8 倍留足了余量。
        if ts > now &* 8 {
            return UInt64((Double(ts) * Double(info.denom) / Double(info.numer)).rounded())
        }
        return ts
    }
}

// MARK: - 纯统计（可离线断言）

enum PerfStats {
    static func mean(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        var s = 0.0
        for x in xs { s += x }
        return s / Double(xs.count)
    }

    /// 分位数（线性插值）。`xs` **必须已按升序排好**；p ∈ [0,1]，越界夹住。
    /// 空数组返回 0，单元素数组返回该元素（p 无关）—— 调用方据此区分「无数据」。
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let q = min(1, max(0, p))
        let pos = q * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down))
        let hi = min(sorted.count - 1, lo + 1)
        let frac = pos - Double(lo)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
    }
}

// MARK: - 事件环（tap 热路径零分配）

/// 固定容量事件环。tap 回调 / display link 回调里只做 append：
/// 不分配内存、不排序、不加新锁（锁由 GamePerfProbe 自己管）。
/// 满了就覆盖最旧的 —— 我们只关心最近 2 秒，丢掉更早的没有损失。
struct EventRing {
    private var t: [UInt64]
    private var a: [Int32]
    private var b: [Int32]
    private var next = 0
    private(set) var total = 0

    init(capacity: Int) {
        let n = max(1, capacity)
        t = [UInt64](repeating: 0, count: n)
        a = [Int32](repeating: 0, count: n)
        b = [Int32](repeating: 0, count: n)
    }

    var capacity: Int { t.count }
    var count: Int { min(total, capacity) }

    mutating func append(_ t: UInt64, _ a: Int32, _ b: Int32) {
        self.t[next] = t
        self.a[next] = a
        self.b[next] = b
        next = (next + 1) % capacity
        total += 1
    }

    mutating func reset() {
        next = 0
        total = 0
    }

    /// 由旧到新的快照（最多 capacity 条）。只在统计线程调用，可以分配。
    func snapshot() -> [(UInt64, Int32, Int32)] {
        guard total > 0 else { return [] }
        let n = count
        var out: [(UInt64, Int32, Int32)] = []
        out.reserveCapacity(n)
        let start = (next - n + capacity) % capacity
        for i in 0..<n {
            let idx = (start + i) % capacity
            out.append((t[idx], a[idx], b[idx]))
        }
        return out
    }
}

// MARK: - 设备静态参数

/// 设备引用。由 PointerController 提供，GamePerf 自己不碰 IOHIDEventSystemClient，
/// 这样 GamePerf.swift 能单独编译进 harness 探针（不把整个 App 依赖图拖进来）。
struct PointerDeviceRef: Equatable {
    var registryID: UInt64
    var name: String
    var transport: String
    var builtIn: Bool
}

struct GameDeviceInfo: Identifiable, Equatable {
    var id: UInt64
    var name: String
    var transport: String
    var builtIn: Bool
    /// 设备上报间隔（µs）。IORegistry 的 `ReportInterval`，是鼠标板载配置的真实值。
    /// 2026-11-02 实测：G502 X 接收器 = 1000 µs（1000 Hz），内置触控板 = 8000 µs（125 Hz）。
    var reportIntervalUs: Double
    /// 换算出的回报率（Hz）
    var pollingHz: Double { reportIntervalUs > 0 ? 1_000_000.0 / reportIntervalUs : 0 }

    var pollingLabel: String {
        reportIntervalUs > 0 ? String(format: "%.0f Hz", pollingHz) : "读不到"
    }
}

/// 从 IORegistry 读上报间隔。
///
/// 注意 `ReportInterval` **只能从 IORegistry 读**：2026-11-02 实测
/// `IOHIDServiceClientCopyProperty` 对 `ReportInterval` / `HIDReportInterval` /
/// `HIDPointerResolution` 全部返回 nil，必须像 `PointerController.currentResolution`
/// 那样按 registryID 走 `IOServiceGetMatchingService`。
struct GameDeviceReader {
    static let reportIntervalKey = "ReportInterval"

    static func read(_ refs: [PointerDeviceRef]) -> [GameDeviceInfo] {
        refs.map { ref in
            GameDeviceInfo(id: ref.registryID,
                           name: ref.name,
                           transport: ref.transport,
                           builtIn: ref.builtIn,
                           reportIntervalUs: reportIntervalUs(registryID: ref.registryID))
        }
    }

    static func reportIntervalUs(registryID: UInt64) -> Double {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID))
        guard entry != 0 else { return 0 }
        defer { IOObjectRelease(entry) }
        guard let raw = IORegistryEntryCreateCFProperty(entry, reportIntervalKey as CFString,
                                                        kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let n = raw as? NSNumber else { return 0 }
        return n.doubleValue
    }
}

// MARK: - 就绪度评级

enum GameReadiness: String, CaseIterable {
    case competitive = "竞技级"
    case good = "良好"
    case fair = "一般"
    case poor = "需处理"

    var symbol: String {
        switch self {
        case .competitive: return "bolt.fill"
        case .good: return "checkmark.circle.fill"
        case .fair: return "exclamationmark.circle.fill"
        case .poor: return "xmark.octagon.fill"
        }
    }
}

struct PerfCheck: Identifiable, Equatable {
    var label: String
    var pass: Bool
    var detail: String
    var id: String { label }
}

/// 评级与建议都是纯函数：UI 与 harness 共用同一份阈值，
/// 不会出现「界面显示良好、harness 按另一套数字判」的漂移（G 段吃过副本漂移的亏）。
enum GameGrade {
    static func checks(pollingHz: Double,
                       measuredHz: Double,
                       jitterP99Ms: Double,
                       latencyP99Ms: Double,
                       frameDropRatio: Double) -> [PerfCheck] {
        var out: [PerfCheck] = []
        out.append(PerfCheck(label: "回报率",
                             pass: pollingHz >= 500,
                             detail: pollingHz > 0 ? String(format: "%.0f Hz", pollingHz) : "读不到"))
        // macOS 会在 HID 层合并 mouseMoved，实测达成率通常到不了 100%，
        // 所以阈值放到 50%，不拿 100% 当合格线（否则永远红）。
        let ratio = pollingHz > 0 ? measuredHz / pollingHz : 0
        out.append(PerfCheck(label: "事件达成率",
                             pass: pollingHz > 0 && ratio >= 0.5,
                             detail: pollingHz > 0 ? String(format: "%.0f%%", ratio * 100) : "无设备"))
        // jitter / latency 为 0 表示还没采到样本，不算失败也不算通过（UI 另行显示采样中）
        out.append(PerfCheck(label: "移动抖动 p99",
                             pass: jitterP99Ms > 0 && jitterP99Ms <= 2.0,
                             detail: jitterP99Ms > 0 ? String(format: "%.2f ms", jitterP99Ms) : "采样中"))
        out.append(PerfCheck(label: "指针延迟 p99",
                             pass: latencyP99Ms > 0 && latencyP99Ms <= 8.0,
                             detail: latencyP99Ms > 0 ? String(format: "%.2f ms", latencyP99Ms) : "采样中"))
        out.append(PerfCheck(label: "显示稳定性",
                             pass: frameDropRatio <= 0.02,
                             detail: String(format: "%.1f%%", frameDropRatio * 100)))
        return out
    }

    static func grade(_ checks: [PerfCheck]) -> GameReadiness {
        guard !checks.isEmpty else { return .fair }
        switch checks.filter({ !$0.pass }).count {
        case 0: return .competitive
        case 1: return .good
        case 2: return .fair
        default: return .poor
        }
    }

    static func advice(pollingHz: Double,
                       measuredHz: Double,
                       jitterP99Ms: Double,
                       latencyP99Ms: Double,
                       frameDropRatio: Double,
                       sampling: Bool) -> [String] {
        if sampling {
            return ["正在采样：移动鼠标约 2 秒，各项指标与建议就会出来。"]
        }
        var out: [String] = []
        if pollingHz > 0, pollingHz < 500 {
            out.append("设备回报率只有 \(String(format: "%.0f", pollingHz)) Hz。G502 X 支持 1000 Hz，在 G HUB 里把「报告速率」调到 1000 Hz（USB 模式下才生效）。")
        }
        if pollingHz > 0, measuredHz / pollingHz < 0.5 {
            out.append("macOS 层每秒只收到 \(String(format: "%.0f", measuredHz)) 次移动事件，合并损耗偏大。这是系统行为，不是 Smoose 造成的；若同时还装了别的鼠标/滚轮工具，退出它能减少重复拦截。")
        }
        if jitterP99Ms > 2.0 {
            out.append("移动抖动 p99 达 \(String(format: "%.2f", jitterP99Ms)) ms。优先换主板后置 USB 口、去掉 USB 延长线/Hub，无线接收器尽量插近一点。")
        }
        if latencyP99Ms > 8.0 {
            out.append("指针延迟 p99 达 \(String(format: "%.2f", latencyP99Ms)) ms。看看是不是有别的辅助功能工具在抢 Accessibility 事件，或后台占用偏高。")
        }
        if frameDropRatio > 0.02 {
            out.append("显示掉帧 \(String(format: "%.1f", frameDropRatio * 100))%。游戏内锁帧或降画质能减少掉帧；外接高刷屏时确认走的是独显/高带宽口。")
        }
        if out.isEmpty {
            out.append("各项指标都在竞技级区间，当前配置适合 FPS / MOBA。")
        }
        return out
    }
}

// MARK: - 探针

/// 鼠标游戏性能探针。采集全部挂在已有的两个回调上，不新开 tap、不加轮询：
///   · 指针 / 侧键 —— ScrollEngine 的 CGEvent tap 已经拦了 mouseMoved 与 otherMouseDown/Up
///   · 显示帧 —— ScrollEngine 的 CVDisplayLink 本来就在跑
/// 所以这个功能对 Smoose 自身是零额外系统开销。
final class GamePerfProbe: ObservableObject {
    static let shared = GamePerfProbe()

    /// 锁序：只可能是 ScrollEngine.lock → GamePerfProbe.lock（tap 回调里 ScrollEngine
    /// 先拿自己的锁再调 record*）。统计线程只拿 GamePerfProbe.lock，不反向，
    /// 所以不会死锁。
    private let lock = NSLock()
    private var pointerRing = EventRing(capacity: 2048)
    private var latencyRing = EventRing(capacity: 512)
    private var frameRing = EventRing(capacity: 1024)
    private var wheelRing = EventRing(capacity: 256)
    private var buttonRing = EventRing(capacity: 64)
    /// 侧键按下时间戳，按 button 号存；UP 到来时算时长
    private var downAt: [Int: UInt64] = [:]

    /// 设备参数来源。App 启动时注入 PointerController；探针/harness 可换假的。
    var deviceSource: () -> [PointerDeviceRef] = { [] }

    /// 采样窗口（毫秒）。2 秒：短到能反映「刚才那一把」，长到够算出 p99。
    static let windowMs: Double = 2000

    // 设备
    @Published private(set) var devices: [GameDeviceInfo] = []
    // 指针
    @Published private(set) var pointerRateHz: Double = 0
    @Published private(set) var pointerJitterP50Ms: Double = 0
    @Published private(set) var pointerJitterP99Ms: Double = 0
    @Published private(set) var pointerJitterMaxMs: Double = 0
    @Published private(set) var pointerLatencyP50Ms: Double = 0
    @Published private(set) var pointerLatencyP99Ms: Double = 0
    @Published private(set) var pointerLatencyMaxMs: Double = 0
    @Published private(set) var pointerSamples: Int = 0
    // 显示
    @Published private(set) var refreshHz: Double = 0
    @Published private(set) var frameDropRatio: Double = 0
    @Published private(set) var frameSamples: Int = 0
    // 滚轮 / 侧键
    @Published private(set) var wheelRateHz: Double = 0
    @Published private(set) var sideButtonMs: Double = 0
    // 结论
    @Published private(set) var checks: [PerfCheck] = []
    @Published private(set) var readiness: GameReadiness = .fair
    @Published private(set) var advice: [String] = []
    /// true = 指针样本还不够，界面应显示「采样中」而不是评级
    @Published private(set) var sampling: Bool = true

    private var timer: DispatchSourceTimer?
    private var lastDeviceSignature = ""

    /// App 里一律用 `.shared`；不设 private 是为了让 harness 探针能开一个
    /// 独立实例、灌合成事件进去断言统计逻辑（否则只能测单例，互相污染）。
    init() {}

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.recompute() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func reset() {
        lock.lock()
        pointerRing.reset()
        latencyRing.reset()
        frameRing.reset()
        wheelRing.reset()
        buttonRing.reset()
        downAt.removeAll()
        lock.unlock()
        pointerRateHz = 0
        pointerJitterP50Ms = 0
        pointerJitterP99Ms = 0
        pointerJitterMaxMs = 0
        pointerLatencyP50Ms = 0
        pointerLatencyP99Ms = 0
        pointerLatencyMaxMs = 0
        pointerSamples = 0
        refreshHz = 0
        frameDropRatio = 0
        frameSamples = 0
        wheelRateHz = 0
        sideButtonMs = 0
        checks = []
        advice = []
        sampling = true
    }

    // MARK: - 采集（热路径，务必保持廉价）

    /// 记一次 mouseMoved。`eventTimestamp` 直接取 CGEvent.timestamp（mach 时基）。
    func recordPointer(eventTimestamp: UInt64, dx: Int64, dy: Int64) {
        let now = mach_absolute_time()
        // 必须先归一化时基再算延迟：注入事件的 timestamp 是纳秒，直接相减得 0。
        let ts = MachClock.normalize(eventTimestamp, now: now)
        let us = Int32((MachClock.ns(MachClock.diff(now, ts)) / 1000.0).rounded())
        lock.lock()
        pointerRing.append(ts, Int32(clamping: dx), Int32(clamping: dy))
        latencyRing.append(now, us, 0)
        lock.unlock()
    }

    /// 记一帧（display link 回调里调）
    func recordFrame() { recordFrame(at: mach_absolute_time()) }

    /// 可注入时间戳的版本，给 harness 灌合成帧用
    func recordFrame(at ticks: UInt64) {
        lock.lock()
        frameRing.append(ticks, 0, 0)
        lock.unlock()
    }

    /// 记一次滚轮事件（不论最终是否被接管）
    func recordWheel() {
        lock.lock()
        wheelRing.append(mach_absolute_time(), 0, 0)
        lock.unlock()
    }

    /// 可注入时间戳的版本，给 harness 灌合成滚轮事件用
    func recordWheel(at ticks: UInt64) {
        lock.lock()
        wheelRing.append(ticks, 0, 0)
        lock.unlock()
    }

    /// 记一次侧键。只有 button 4/5 会经过我们的 tap，左右主键看不到 —— 界面已注明。
    func recordButton(button: Int, down: Bool) {
        let now = mach_absolute_time()
        lock.lock()
        if down {
            downAt[button] = now
        } else if let t = downAt.removeValue(forKey: button) {
            let us = Int32((MachClock.ns(MachClock.diff(now, t)) / 1000.0).rounded())
            buttonRing.append(now, us, 0)
        }
        lock.unlock()
    }

    // MARK: - 统计（每秒一次，主线程）

    /// 相邻事件间隔（毫秒，已升序排好，可直接喂 PerfStats.percentile）。
    ///
    /// 必须对空数组 / 单元素数组短路：`1..<count` 在 count < 1 时会触发
    /// Swift 运行时陷阱（Range requires lowerBound <= upperBound）。
    /// 2026-11-02：直接写 `for i in 1..<ts.count` 导致启动即崩（首帧采样为空）。
    static func intervals(of ts: [UInt64]) -> [Double] {
        guard ts.count >= 2 else { return [] }
        var out: [Double] = []
        out.reserveCapacity(ts.count - 1)
        for i in 1..<ts.count {
            out.append(MachClock.ms(MachClock.diff(ts[i], ts[i - 1])))
        }
        out.sort()
        return out
    }

    /// 重算一遍全部指标。正常由 1 Hz 定时器驱动；harness 直接调。
    func recompute() {
        let now = mach_absolute_time()
        let window = MachClock.ticks(forMs: Self.windowMs)

        lock.lock()
        let pointer = pointerRing.snapshot()
        let latency = latencyRing.snapshot()
        let frames = frameRing.snapshot()
        let wheels = wheelRing.snapshot()
        let buttons = buttonRing.snapshot()
        lock.unlock()

        refreshDevices()

        // —— 指针：事件率 + 间隔抖动 ——
        let ptr = pointer.filter { MachClock.diff(now, $0.0) <= window }
        let ptrTs = ptr.map { $0.0 }
        // 注意：这里必须走 intervals(of:)，不能直接写 `for i in 1..<ts.count`。
        // 2026-11-02 实测：启动后第一次 recompute 时用户还没动鼠标，ts 为空，
        // `1..<0` 会触发 Swift 运行时陷阱（Range requires lowerBound <= upperBound），
        // 整个 App 启动即崩。空数组必须单独短路。
        let intervals = Self.intervals(of: ptrTs)
        let spanSec = ptrTs.count >= 2 ? MachClock.ms(MachClock.diff(ptrTs.last!, ptrTs.first!)) / 1000.0 : 0
        let rate = spanSec > 0 ? Double(ptrTs.count) / spanSec : 0

        // —— 指针延迟 ——
        let lat = latency.filter { MachClock.diff(now, $0.0) <= window }.map { Double($0.1) / 1000.0 }.sorted()

        // —— 显示：刷新率 + 掉帧 ——
        let fr = frames.filter { MachClock.diff(now, $0.0) <= window }
        let frTs = fr.map { $0.0 }
        let fIntervals = Self.intervals(of: frTs)
        let medFrame = PerfStats.percentile(fIntervals, 0.5)
        let refresh = medFrame > 0 ? 1000.0 / medFrame : 0
        let dropped = medFrame > 0 ? fIntervals.filter { $0 > medFrame * 1.5 }.count : 0
        let dropRatio = fIntervals.isEmpty ? 0 : Double(dropped) / Double(fIntervals.count)

        // —— 滚轮 / 侧键 ——
        let wh = wheels.filter { MachClock.diff(now, $0.0) <= window }
        let whTs = wh.map { $0.0 }
        let whSpan = whTs.count >= 2 ? MachClock.ms(MachClock.diff(whTs.last!, whTs.first!)) / 1000.0 : 0
        let btn = buttons.filter { MachClock.diff(now, $0.0) <= window }.map { Double($0.1) / 1000.0 }

        pointerSamples = ptrTs.count
        pointerRateHz = rate
        pointerJitterP50Ms = PerfStats.percentile(intervals, 0.5)
        pointerJitterP99Ms = PerfStats.percentile(intervals, 0.99)
        pointerJitterMaxMs = intervals.last ?? 0
        pointerLatencyP50Ms = PerfStats.percentile(lat, 0.5)
        pointerLatencyP99Ms = PerfStats.percentile(lat, 0.99)
        pointerLatencyMaxMs = lat.last ?? 0
        frameSamples = fIntervals.count
        refreshHz = refresh
        frameDropRatio = dropRatio
        wheelRateHz = whSpan > 0 ? Double(whTs.count) / whSpan : 0
        sideButtonMs = PerfStats.mean(btn)

        // 取回报率最高的设备当「你的游戏鼠标」（触控板 125 Hz 会被正确忽略）
        let best = devices.filter { !$0.builtIn }.max { $0.pollingHz < $1.pollingHz } ?? devices.max { $0.pollingHz < $1.pollingHz }
        let polling = best?.pollingHz ?? 0

        let enough = ptrTs.count >= 8
        sampling = !enough
        let c = GameGrade.checks(pollingHz: polling,
                                 measuredHz: rate,
                                 jitterP99Ms: enough ? pointerJitterP99Ms : 0,
                                 latencyP99Ms: enough ? pointerLatencyP99Ms : 0,
                                 frameDropRatio: dropRatio)
        checks = c
        readiness = GameGrade.grade(c)
        advice = GameGrade.advice(pollingHz: polling,
                                  measuredHz: rate,
                                  jitterP99Ms: enough ? pointerJitterP99Ms : 0,
                                  latencyP99Ms: enough ? pointerLatencyP99Ms : 0,
                                  frameDropRatio: dropRatio,
                                  sampling: sampling)
    }

    /// 设备列表变了才重读 IORegistry（IORegistry 查询不便宜，不能每秒扫）
    private func refreshDevices() {
        let refs = deviceSource()
        let sig = refs.map { String($0.registryID) }.sorted().joined(separator: ",")
        guard sig != lastDeviceSignature else { return }
        lastDeviceSignature = sig
        devices = GameDeviceReader.read(refs)
    }
}

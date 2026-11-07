import Foundation
import IOKit
import IOKit.hid

// ⚠️ 手动开发探针：会**短暂改变鼠标硬件 DPI**，跑完必须写回原值。
// 不要放进 run_tests.sh 自动执行（harness 每次跑都会动用户硬件）。
//
// 目的：补齐「SET_SENSOR_DPI 只验过幂等写入（写当前值）」的验证缺口。
// 流程：独立只读会话读原值 → 写一个**不同的合法档位** → 读回确认真的变了
//       → 写回原值 → 用**另一个独立会话**再读一次确认恢复。
// 任何一步失败都会尽力恢复原值，并以非零退出码报红。
//
// 报文与 App 的 HIDPPDPIParser.setRequest / HIDPPWrite.run 完全同构：
//   长报文 20B = [0x11, 0x01, featureIndex, 0x38, sensor, dpi>>8, dpi, 0...]
//   featureIndex 必须来自 getFeature(0x2201)，不能用 0x22。
//
// 编译运行（macOS / Xcode CLT）：
//   SWIFTC=$(/usr/bin/xcrun --find swiftc); SDK=$(/usr/bin/xcrun --show-sdk-path)
//   "$SWIFTC" -disable-sandbox -O -sdk "$SDK" \
//     Probe/HIDPPNonIdempotentRoundTrip.swift -o /tmp/hidpp_nonidem && /tmp/hidpp_nonidem

final class Session {
    let dev: IOHIDDevice
    var responses: [[UInt8]] = []
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    var ctx: UnsafeMutableRawPointer?

    init(_ dev: IOHIDDevice) {
        self.dev = dev
        buf.initialize(repeating: 0, count: 64)
        ctx = Unmanaged.passUnretained(self).toOpaque()
    }
    deinit { buf.deallocate() }

    func start() {
        let cb: IOHIDReportCallback = { c, _, _, _, _, r, n in
            guard let c else { return }
            Unmanaged<Session>.fromOpaque(c).takeUnretainedValue().responses.append(
                Array(UnsafeBufferPointer(start: r, count: max(0, n))))
        }
        IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, cb, ctx)
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    func stop() {
        IOHIDDeviceUnscheduleFromRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    /// 发 HID++ 长报文并等匹配的响应。tries>1 用于唤醒休眠的接收器。
    func request(_ sub: UInt8, _ addr: UInt8, _ params: [UInt8], tries: Int = 3)
        -> (rc: IOReturn, hit: [UInt8]?) {
        var lastRC: IOReturn = IOReturn(-1)
        for _ in 0..<tries {
            var r: [UInt8] = [0x11, 0x01, sub, addr] + params
            r += [UInt8](repeating: 0, count: 20 - r.count)
            responses = []
            lastRC = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x11, &r, r.count)
            let deadline = CFAbsoluteTimeGetCurrent() + 0.8
            repeat {
                CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.02, false)
                if let h = responses.first(where: {
                    $0.count >= 7 && $0[0] == 0x11 && $0[1] == 0x01
                        && $0[2] == sub && $0[3] == addr
                }) { return (lastRC, h) }
            } while CFAbsoluteTimeGetCurrent() < deadline
        }
        return (lastRC, nil)
    }
}

func be(_ p: [UInt8], _ i: Int) -> Int { (Int(p[i]) << 8) | Int(p[i + 1]) }
func hx(_ a: [UInt8]) -> String { a.map { String(format: "%02x", $0) }.joined(separator: " ") }

/// GET_SENSOR_DPI 响应：parameters 区 p[0]=sensor, p[1..2]=当前 DPI (big-endian)
func currentDPI(_ hit: [UInt8]?) -> Int? {
    guard let h = hit, h.count >= 8 else { return nil }
    let p = Array(h[4...])
    guard p.count >= 3 else { return nil }
    return be(p, 1)
}

func sensorIndex(_ hit: [UInt8]?) -> UInt8 {
    guard let h = hit, h.count >= 5 else { return 0 }
    return h[4]
}

func writeDPI(_ s: Session, _ idx: UInt8, _ sensor: UInt8, _ value: Int)
    -> (rc: IOReturn, hit: [UInt8]?, echo: Int?) {
    let w = s.request(idx, 0x38,
                      [sensor, UInt8(truncatingIfNeeded: value >> 8),
                       UInt8(truncatingIfNeeded: value)], tries: 1)
    let echo: Int? = w.hit.flatMap { h -> Int? in
        let p = Array(h[4...])
        return p.count >= 3 ? be(p, 1) : nil
    }
    return (w.rc, w.hit, echo)
}

func openDevice(_ dev: IOHIDDevice, _ option: IOOptionBits) -> IOReturn {
    IOHIDDeviceOpen(dev, option)
}

func closeDevice(_ dev: IOHIDDevice) {
    IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
}

/// 尽力把硬件写回原值；读回不一致就重试，最多 4 次。
func restore(_ s: Session, _ idx: UInt8, _ sensor: UInt8, _ original: Int) -> Bool {
    for attempt in 1...4 {
        let w = writeDPI(s, idx, sensor, original)
        let got = currentDPI(s.request(idx, 0x28, [sensor]).hit)
        print("[restore] 第 \(attempt) 次 SET(\(original)) rc=\(w.rc) 回显=\(w.echo.map(String.init) ?? "nil") 读回=\(got.map(String.init) ?? "nil")")
        if got == original { return true }
    }
    return false
}

func fail(_ reason: String) -> Never {
    print("==> FAIL: \(reason)")
    exit(1)
}

// MARK: - 主流程

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x046D] as CFDictionary)
IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
    fail("枚举 Logitech HID 设备失败")
}

for dev in devices {
    let page = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue ?? 0
    let pid = (IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? NSNumber)?.uint64Value ?? 0
    guard page == 0xFF00 else { continue }   // 0xFF00 = Logitech HID++ 接口
    print("设备 pid=0x\(String(format: "%04x", pid))")

    // ---- 阶段 1：非独占只读，先摸清原值与合法档位；这一步绝不改硬件 ----
    let rcNone = openDevice(dev, IOOptionBits(kIOHIDOptionsTypeNone))
    print("[1] open(None) rc=\(rcNone)")
    guard rcNone == kIOReturnSuccess else { fail("非独占打开失败 rc=\(rcNone)") }
    let s0 = Session(dev)
    s0.start()
    for _ in 0..<3 { _ = s0.request(0x00, 0x08, [0x22, 0x01]) }   // 唤醒接收器
    guard let feat = s0.request(0x00, 0x08, [0x22, 0x01]).hit, feat.count >= 5, feat[4] != 0 else {
        // 另一个接收器明确不支持 0x2201（index=0）或无响应：换下一个设备，不算本次失败。
        print("    pid=0x\(String(format: "%04x", pid)) 不支持 0x2201，跳过")
        s0.stop()
        closeDevice(dev)
        continue
    }
    let idx = feat[4]
    guard let listHit = s0.request(idx, 0x18, [0x00]).hit else { fail("GET_SENSOR_DPI_LIST 无响应") }
    let lp = Array(listHit[4...])
    var values: [Int] = [], step: Int?
    var i = 1
    while i + 1 < lp.count {
        let v = be(lp, i)
        if v == 0 { break }
        if v > 0xE000 { step = v - 0xE000 } else { values.append(v) }
        i += 2
    }
    guard let lo = values.min(), let hi = values.max(), lo < hi else {
        fail("档位列表解析失败：\(hx(listHit))")
    }
    let sensor = sensorIndex(s0.request(idx, 0x28, [0x00]).hit)
    var readings: [Int] = []
    for _ in 0..<3 {
        guard let v = currentDPI(s0.request(idx, 0x28, [sensor]).hit) else { fail("写前读当前 DPI 失败") }
        readings.append(v)
    }
    guard readings.allSatisfy({ $0 == readings[0] }) else { fail("写前连续 3 次读数不一致：\(readings)") }
    let before = readings[0]
    print("[2] featureIndex=\(idx) sensor=\(sensor) 范围=\(lo)...\(hi) 步长=\(step.map(String.init) ?? "无")")
    print("[3] 原值 = \(before) DPI（连续 3 次一致）")

    // 选一个「不同于原值」的最小扰动档位：步长优先，其次 ±50。
    let stride = (step ?? 50) > 0 ? (step ?? 50) : 50
    var target: Int? = nil
    for candidate in [before + stride, before - stride] {
        if candidate >= lo && candidate <= hi && candidate != before
            && (lo...hi).contains(candidate) && (candidate - lo) % stride == 0 {
            target = candidate
            break
        }
    }
    guard let target else { fail("找不到一个不同于原值的合法档位（原值 \(before)，范围 \(lo)...\(hi)，步长 \(stride)）") }
    print("[4] 目标档位 = \(target) DPI（≠ 原值 \(before)）")

    s0.stop()
    closeDevice(dev)

    // ---- 阶段 2：独占写入，与 App 的 HIDPPWrite.run 同款连接方式 ----
    var rcSeize = openDevice(dev, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
    var mode = "SeizeDevice（与 App 写入路径一致）"
    if rcSeize != kIOReturnSuccess {
        // 常见原因：Smoose 的 DPI 同步长连接正占着设备。降级为非独占并如实标注。
        rcSeize = openDevice(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        mode = "None（SeizeDevice 失败，降级；与 App 写入路径不完全一致）"
    }
    print("[5] open(\(mode)) rc=\(rcSeize)")
    guard rcSeize == kIOReturnSuccess else { fail("写入会话打开失败 rc=\(rcSeize)") }
    let s1 = Session(dev)
    s1.start()
    for _ in 0..<3 { _ = s1.request(0x00, 0x08, [0x22, 0x01]) }

    let w1 = writeDPI(s1, idx, sensor, target)
    let afterTarget = currentDPI(s1.request(idx, 0x28, [sensor]).hit)
    print("[6] SET(\(target)) rc=\(w1.rc) 回显=\(w1.echo.map(String.init) ?? "nil") 读回=\(afterTarget.map(String.init) ?? "nil")")
    guard w1.rc == kIOReturnSuccess else {
        _ = restore(s1, idx, sensor, before)
        fail("SET 报文失败 rc=\(w1.rc)")
    }
    guard afterTarget == target else {
        // 关键负例：若 SET 其实没生效（旧实现的假绿），读回仍是 before，这里必须报红。
        _ = restore(s1, idx, sensor, before)
        fail("写入 \(target) 后读回是 \(afterTarget.map(String.init) ?? "nil")，不等于目标值（写入未生效）")
    }
    print("    ✓ 非幂等写入生效：\(before) → \(target)（读回确认）")

    guard restore(s1, idx, sensor, before) else {
        fail("⚠️ 无法写回原值 \(before)，请手动把鼠标 DPI 调回 \(before)")
    }
    print("[7] ✓ 已写回原值 \(before)")
    s1.stop()
    closeDevice(dev)

    // ---- 阶段 3：第三个独立会话复核，避免同连接缓存造成「恢复成功」假绿 ----
    let rcFinal = openDevice(dev, IOOptionBits(kIOHIDOptionsTypeNone))
    guard rcFinal == kIOReturnSuccess else { fail("最终复核会话打开失败 rc=\(rcFinal)") }
    let s2 = Session(dev)
    s2.start()
    for _ in 0..<3 { _ = s2.request(0x00, 0x08, [0x22, 0x01]) }
    guard let final = currentDPI(s2.request(idx, 0x28, [sensor]).hit) else {
        fail("最终独立复核读不到当前 DPI")
    }
    print("[8] 独立复核会话最终 DPI = \(final)")
    s2.stop()
    closeDevice(dev)
    guard final == before else { fail("⚠️ 最终 DPI 是 \(final)，不是原值 \(before)，请手动调回") }

    print("==> PASS: 非幂等 DPI 写入 \(before)→\(target)→\(before) 全程读回校验通过，硬件已恢复原值")
    exit(0)
}

fail("未找到任何支持 HID++ 0x2201 的接收器（usage page 0xFF00）")

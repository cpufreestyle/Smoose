import Foundation
import IOKit
import IOKit.hid

/// 只读探针：列出当前事件系统里**驱动指针**的 HID 服务及其加速度读数。
///
/// 与 `Probe/main.swift` 的区别：那个会 `IOHIDServiceClientSetProperty` 试写 0/163840/65536
/// 再还原（现场验证用）；本探针**一个字节都不写**，只读，用于「手感不对时先取证」：
/// 用户报「鼠标有段时间被控制 / 起步发黏」时，先用它确认线性接管到底在不在生效。
///
/// 为什么必须自己探、不能只看 App 状态区：
/// 状态区读的是 App 自己写后的回读，而「写进去之后系统又改回去」这件事
/// 只有独立进程的读数能发现（2026-11-10 真机实测：App 没在跑时两个指针服务
/// 读数是 0，启动 App 后才变 -65536）。
///
/// 数值语义（IOFixed，65536 = 1.0，与 LinearMouse `PointerDevice.pointerAcceleration` 对齐）：
///  · -65536（-1.000）= 加速与灵敏度均禁用，严格 1:1 线性 ← Smoose 接管后的目标值
///  · 0（0.000）      = **最小加速度**，不是关闭！系统仍走速度相关加速曲线，
///                      低速增益 < 1，正是「刚起步 / 停久了再动时像被拽住，手速上来才正常」
///  · 163840（2.500） = 系统默认值（未接管）
///
/// 约束（本探针顺带证明）：该值写在外接鼠标的 HID 设备实例上，且只在 Smoose
/// 运行时被维持；App 退出后事件系统会把参数还回去。想保持线性就让 App 一直开着。
///
/// 运行：`swiftc Probe/AccelReadProbe.swift -o /tmp/accelread -framework IOKit && /tmp/accelread`
let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
guard let arr = IOHIDEventSystemClientCopyServices(client) as NSArray? else {
    print("读不到 IOHIDEventSystemClient 的服务列表"); exit(1)
}

func prop(_ s: IOHIDServiceClient, _ k: String) -> NSNumber? {
    IOHIDServiceClientCopyProperty(s, k as CFString) as? NSNumber
}

/// 只把「驱动指针」的服务算进来：符合 GenericDesktop / Mouse 用法。
/// 同一只 Logitech 接收器会同时暴露鼠标 / 键盘 / 消费类控制等多个集合，
/// 键盘与 consumer 集合上的加速度键与指针手感无关，不能混进判定。
var pointerServices: [(rid: UInt64, name: String, key: String, accel: Double?, linear: Int?)] = []
var skipped: [(name: String, reason: String)] = []

for case let s as IOHIDServiceClient in arr {
    let conforms = IOHIDServiceClientConformsTo(s, UInt32(kHIDPage_GenericDesktop),
                                               UInt32(kHIDUsage_GD_Mouse))
    guard conforms != 0 else { continue }
    let name = IOHIDServiceClientCopyProperty(s, "Product" as CFString).map { "\($0)" } ?? "未知设备"
    let builtIn = prop(s, "Built-In")?.boolValue
        ?? (prop(s, "Transport") as? String)?.localizedCaseInsensitiveContains("FIFO") == true
    // 与 PointerController.refresh 同一套键选择逻辑：优先设备自述的加速度类型键。
    let key = (IOHIDServiceClientCopyProperty(s, "HIDPointerAccelerationType" as CFString) as? String)
        ?? "HIDMouseAcceleration"
    // 内建触控板按设计恒不接管（写 -1 读回 0，线性标志也不支持），单列不参与判定。
    if builtIn {
        skipped.append((name, "内建设备由系统管理（Smoose 不写）"))
        continue
    }
    guard let rid = (IOHIDServiceClientGetRegistryID(s) as? NSNumber)?.uint64Value else { continue }
    pointerServices.append((rid: rid,
                            name: name,
                            key: key,
                            accel: prop(s, key)?.doubleValue,
                            linear: prop(s, "HIDUseLinearScalingMouseAcceleration")?.intValue))
}

func verdict(_ v: Double?) -> String {
    guard let v else { return "读不到（设备不暴露该参数）" }
    switch v {
    case -65536: return "线性 1:1（加速已关闭）✅"
    case 0:      return "最小加速度 ⚠️ 系统加速曲线仍在（起步发黏的来源）"
    case 163840: return "系统默认 2.500（未被接管）"
    default:     return String(format: "%.3f", v / 65536.0)
    }
}

print("── 指针服务加速度读数（只读，\(pointerServices.count) 个外接指针服务）")
for s in pointerServices {
    print("  \(s.name)  rid=\(s.rid)  key=\(s.key)")
    print("      HIDMouseAcceleration = \(s.accel.map { String(format: "%.0f", $0) } ?? "nil")"
        + "（\(s.accel.map { String(format: "%.3f", $0 / 65536.0) } ?? "?")）"
        + "  HIDUseLinearScalingMouseAcceleration = \(s.linear.map { "\($0)" } ?? "nil")")
    print("      → \(verdict(s.accel))")
}
for s in skipped { print("  \(s.name)：\(s.reason)") }

let linear = pointerServices.filter { $0.accel == -65536 }.count
let total = pointerServices.count
print("── 汇总：\(linear)/\(total) 个外接指针服务处于线性 1:1")
if total > 0 && linear < total {
    print("── 结论：有指针服务没被接管。若 Smoose 正在运行，等 8 秒轮询/重试；")
    print("         若 Smoose 没运行，启动它即可（写入只在 App 运行时被维持）。")
    exit(2)
}
if total == 0 {
    print("── 结论：没有可接管的外接指针服务（只剩内建设备时 Smoose 状态区也应为空/跳过）。")
    exit(3)
}
print("── 结论：全部外接指针服务均为线性 1:1，macOS 加速曲线已关闭。")
exit(0)

import Foundation

// HID++ 2.0 / 0x2201 (Adjustable DPI) 协议层（平台无关）
//
// 2026-11-12 从 LogitechHIDPP.swift 抽出：整段只依赖 Foundation，
// 不碰 IOKit / AppKit / RunLoop，任何平台接上自己的 HID 传输层即可复用。
// 这里只有「报文编解码 + 档位计算 + 写入结果判定」；设备枚举、SetReport、
// 接收器轮询与 DPI 自动同步策略仍留在 LogitechHIDPP.swift（macOS / IOKit 专属）。
//
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

import Foundation

/// 按住加速键时的滚动距离倍率（对应 Mos 的 scroll boost）。
///
/// 纯函数，便于离线断言：只有「开关打开 + 至少配了一个修饰键 + 本次事件确实带着它」
/// 三条同时满足才放大，其余一律返回 1.0（不改变手感）。
/// 之所以读事件自带的 flags 而不是自己维护按键状态，是因为滚轮事件本身就携带
/// 当前修饰键，省掉一个 flagsChanged 监听和它的状态同步问题。
struct ScrollBoost {
    static let maxScale: Double = 10.0

    static func scale(enabled: Bool, modifiers: UInt64, factor: Double, eventFlags: UInt64) -> Double {
        // 必须是「配置的键全都按住」才算命中。用 != 0 是「任意命中」语义，
        // 配了 ⌘+⌥ 时只按 ⌘ 就会误触发加速（S5b 断言抓到）。
        guard enabled, modifiers != 0, (eventFlags & modifiers) == modifiers else { return 1.0 }
        // 小于 1 的倍率不是「加速」，夹到 1；上限防止手滑写成 100 倍
        return min(maxScale, max(1.0, factor))
    }
}

/// 曲线预览用的采样（纯函数，可离线断言）。
///
/// 与引擎里 `ScrollAxis.advance` 的公式保持同一形状：
/// `x(t) = 1 - exp(-t / tau)`，再把 1 换成「这一格滚轮最终要走的总距离」。
/// 图中画的是「滚一格之后，位移如何随时间铺满」，所以看到的是尾巴长度而不是距离。
enum ScrollCurve {
    /// 采样归一化后的位移曲线，返回 (t, 0...1) 序列。
    /// - Parameters:
    ///   - tau: 指数时间常数（秒），来自 `ScrollProfile.tau`
    ///   - duration: 采样窗口（秒）。窗口太短看不出尾巴，太长曲线贴顶变平
    ///   - samples: 采样点数
    static func samples(tau: Double, duration: Double = 0.5, samples: Int = 64) -> [(t: Double, progress: Double)] {
        guard samples > 1, duration > 0 else { return [] }
        let safeTau = max(0.0001, tau)
        return (0..<samples).map { i in
            let t = duration * Double(i) / Double(samples - 1)
            return (t, 1 - exp(-t / safeTau))
        }
    }

    /// 曲线跑到 95% 所需时间（秒）——用来在界面上给出「尾巴多长」的可读数字。
    static func settlingTime(tau: Double, at progress: Double = 0.95) -> Double {
        let safeTau = max(0.0001, tau)
        let p = min(0.999, max(0.01, progress))
        return -safeTau * log(1 - p)
    }
}

/// 单个滚动轴的插值状态机（纯逻辑，可离线测试）
struct ScrollAxis {
    private(set) var target: Double = 0   // 期望总位移（px）
    private(set) var current: Double = 0  // 插值后的当前位置（px）
    private(set) var sent: Double = 0     // 已投递的位移（px）

    /// 平滑轴：把新 delta 累加到目标位置
    mutating func push(_ amount: Double) {
        target += amount
    }

    /// 连续滚动时的跟手性自适应：lag 越大，本帧时间常数越短（越跟手），
    /// 避免快速甩动后 lag 堆积导致「停住等追上」的顿挫（对齐 BTT ScrollPhaseManager 的思路）。
    private func adaptiveTau(baseTau: Double) -> Double {
        let lag = abs(target - current)
        guard lag > 24 else { return baseTau }
        // lag 24 → 1.0×；lag 800 → 约 0.55×；lag 1600+ → 0.4× 封底
        let k = min(1.0, 24.0 / lag)
        return max(baseTau * 0.4, baseTau * (0.4 + 0.6 * k))
    }

    /// 非平滑轴：立即到位，下一帧即投递（≤1 帧延迟）
    mutating func jump(_ amount: Double) {
        target += amount
        current = target
    }

    /// 推进一帧，返回本帧应投递的整数像素（不足 1px 的部分累积到下一帧）
    mutating func advance(dt: Double, tau: Double) -> Int32 {
        if tau <= 0 {
            current = target
        } else {
            current += (target - current) * (1.0 - exp(-dt / adaptiveTau(baseTau: tau)))
            if abs(target - current) < 0.05 { current = target }
        }

        // 极端情况下防止 lag 无界增长
        let lag = target - current
        if abs(lag) > 1600 { current = target - (lag > 0 ? 1600 : -1600) }

        let due = current - sent
        if abs(due) >= 1 {
            let whole = trunc(due)
            sent += whole
            return Int32(max(-512, min(512, whole)))
        }
        // 已到位：把 ≥0.5px 的余量结掉，保证距离守恒
        if abs(target - current) < 0.05 {
            if abs(due) >= 0.5 {
                let step: Double = due > 0 ? 1 : -1
                sent = target
                current = target
                return Int32(step)
            }
            sent = target
            current = target
        }
        return 0
    }

    mutating func reset() {
        target = 0
        current = 0
        sent = 0
    }

    var isIdle: Bool { sent == target && current == target }
}

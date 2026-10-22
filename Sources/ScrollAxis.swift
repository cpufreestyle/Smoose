import Foundation

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

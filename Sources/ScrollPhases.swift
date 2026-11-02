import Foundation

/// 合成滚动事件的相位字段值（移植 Mos `ScrollCore/ScrollPhase.swift` 的 PhaseValueMapping）。
///
/// 背景：Smoose 早期合成的滚动事件 `isContinuous=0`、`scrollPhase=0`、`momentumPhase=0`，
/// 在消费端（Chrome / Safari / 原生 NSScrollView）看来就是「物理鼠标滚轮 + 像素增量」，
/// 于是它们会套用自己的滚轮逻辑（行量化、自己的动量），Smoose 精心调出的曲线被二次加工 ——
/// 这正是「同一条曲线，Mos 里更跟手」的根因之一。
/// Mos 的做法是把合成事件标记成触控板滚动：`isContinuous=1` + 明确的相位，
/// 消费端就走「触控板像素滚动」路径，只认我们给出的像素量。
/// 字段 raw value 与 Smoose `ScrollEngine.F` 里的定义一一对应：
///   scroll   → CGEventField 99  (kCGScrollWheelEventScrollPhase)
///   momentum → CGEventField 123 (kCGScrollWheelEventMomentumPhase)
struct ScrollPhaseValue: Equatable {
    var scroll: Double
    var momentum: Double

    /// 手指阶段：首帧 / 过程 / 结束
    static let trackingBegan = ScrollPhaseValue(scroll: 1, momentum: 0)
    static let trackingChanged = ScrollPhaseValue(scroll: 2, momentum: 0)
    static let trackingEnded = ScrollPhaseValue(scroll: 4, momentum: 0)
    /// 惯性阶段：首帧 / 过程 / 结束
    static let momentumBegan = ScrollPhaseValue(scroll: 0, momentum: 1)
    static let momentumChanged = ScrollPhaseValue(scroll: 0, momentum: 2)
    static let momentumEnded = ScrollPhaseValue(scroll: 0, momentum: 3)
}

/// 合成事件上要写的三个字段值。
struct SyntheticScrollFields: Equatable {
    /// isContinuous（CGEventField 88）
    var cont: Int64
    /// scrollWheelEventScrollPhase（CGEventField 99）
    var scroll: Double
    /// scrollWheelEventMomentumPhase（CGEventField 123）
    var momentum: Double
    /// 不写任何字段（与老版本逐字节一致）
    static let none = SyntheticScrollFields(cont: 0, scroll: 0, momentum: 0)
}

/// 合成事件上实际要写的三个字段。抽成纯函数是为了让 harness 能直接断言
/// （引擎里 post() 是 private，H 段摸不到），也顺带把「关掉开关 = 完全回到老行为」
/// 这条契约固定下来：关闭时 cont / scroll / momentum 三者必须全是 0。
enum ScrollPhaseFields {
    static func write(simulateTrackpad: Bool, phase: ScrollPhaseValue?) -> SyntheticScrollFields {
        guard simulateTrackpad, let phase else { return .none }
        return SyntheticScrollFields(cont: 1, scroll: phase.scroll, momentum: phase.momentum)
    }
}

/// 手势相位状态机（移植 Mos `ScrollPhase` + `ScrollPoster.update/processing` 的输入节奏判定）。
///
/// 两种触发源，都必须传同一个时基的时间（引擎用 `CACurrentMediaTime()`）：
///   · `noteInput(now:)`   —— tap 回调里捕获到真实滚轮输入时
///   · `advance(now:posting:settled:)` —— 每帧显示链接收时
/// 状态迁移：
///   idle →(输入) tracking →(输入间隔 > continuationThreshold) momentum →(轴到位) idle
/// 每帧按需产出三种帧：`interrupt`（重新接管惯性时补的 MomentumEnd 零增量帧）、
/// `body`（本帧增量帧的相位）、`end`（轴到位后补的零增量收尾帧）。
struct ScrollPhaseTracker {
    enum Gesture: Equatable {
        case idle
        case tracking
        case momentum
    }

    /// 一帧要发的相位计划。全部为 nil 表示这一帧什么都不发（保持老行为）。
    struct Plan: Equatable {
        var interrupt: ScrollPhaseValue?
        var body: ScrollPhaseValue?
        var end: ScrollPhaseValue?
        var isEmpty: Bool { interrupt == nil && body == nil && end == nil }
    }

    /// 两帧输入间隔 ≤ 它 → 仍是「手指在滚」（tracking）；超过 → 进入惯性段（momentum）。
    /// 取值对齐 Mos `manualContinuationThreshold`（0.18s）。
    static let continuationThreshold: Double = 0.18
    /// 距上次输入 ≥ 它 → 视为一次新的独立手势，重新发 Began。
    /// 取值对齐 Mos `manualSeparationThreshold`（0.45s）。
    static let separationThreshold: Double = 0.45

    private(set) var gesture: Gesture = .idle
    /// 当前段（tracking / momentum）是否已经发过 Began。
    /// 只有真的投递了帧才置位：亚像素累积的帧没有增量，不能把 Began 提前消耗掉。
    private var begun = false
    private var lastInputAt: Double = -.infinity
    /// 下一帧需要先补一帧 MomentumEnd（惯性未走完时用户又滚了）
    private var pendingInterrupt = false

    /// 是否还有未收尾的手势（供「点击刹车」判断要不要补收尾帧）
    var isActive: Bool { gesture != .idle }

    mutating func noteInput(now: Double) {
        let separated = now - lastInputAt >= ScrollPhaseTracker.separationThreshold
        lastInputAt = now
        switch gesture {
        case .idle:
            gesture = .tracking
            begun = false
        case .tracking:
            // 隔太久没滚：当作新的一次手势，重新发 Began
            if separated { begun = false }
        case .momentum:
            // 尾巴还没走完就又滚：先补一帧 MomentumEnd，再开新的 Tracking
            pendingInterrupt = true
            gesture = .tracking
            begun = false
        }
    }

    mutating func reset() {
        gesture = .idle
        begun = false
        lastInputAt = -.infinity
        pendingInterrupt = false
    }

    /// 帧推进。
    /// - Parameters:
    ///   now: 当前时间（与 noteInput 同时基）
    ///   posting: 本帧是否真的有增量要投递（亚像素累积的帧没有）
    ///   settled: 两个轴是否都已到位
    mutating func advance(now: Double, posting: Bool, settled: Bool) -> Plan {
        guard gesture != .idle else { return Plan() }

        var plan = Plan()
        if pendingInterrupt {
            pendingInterrupt = false
            plan.interrupt = .momentumEnded
        }

        // 输入还新鲜 → 手指段；超过 continuationThreshold → 惯性段
        let freshInput = now - lastInputAt <= ScrollPhaseTracker.continuationThreshold
        let target: Gesture = freshInput ? .tracking : .momentum
        if target != gesture {
            gesture = target
            begun = false
        }

        if posting {
            plan.body = (gesture == .tracking)
                ? (begun ? .trackingChanged : .trackingBegan)
                : (begun ? .momentumChanged : .momentumBegan)
            begun = true
        }

        if settled {
            // 收尾帧：惯性段用 MomentumEnd，手指段用 TrackingEnd。
            // 消费端（Chrome 等）靠这帧知道自己该结束手势，不收尾会拖着不走。
            plan.end = (gesture == .momentum) ? .momentumEnded : .trackingEnded
            gesture = .idle
            begun = false
        }
        return plan
    }
}

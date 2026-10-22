import Foundation

func scenario(label: String,
              fps: Double = 120,
              speed: Double = 2.4,
              smoothness: Double = 0.45,
              notches: Int = 1,
              everyFrames: Int = 1,
              notchPx: Double = 10) {
    let tau = 0.006 + smoothness * smoothness * 0.26
    let dt = 1.0 / fps
    var axis = ScrollAxis()
    var total = 0.0
    var firstMove = -1
    var at90 = -1
    var idleAt = -1
    let expected = Double(notches) * notchPx * speed

    for f in 0..<1200 {
        if f % everyFrames == 0, f / everyFrames < notches {
            axis.push(notchPx * speed)
        }
        let d = axis.advance(dt: dt, tau: tau)
        total += Double(d)
        if d != 0, firstMove < 0 { firstMove = f }
        if at90 < 0, expected > 0, abs(total) >= abs(expected) * 0.9 { at90 = f }
        if axis.isIdle, f > everyFrames * notches {
            idleAt = f
            break
        }
    }

    print("── \(label)")
    print("   tau=\(String(format: "%.4f", tau))s 预期总距离=\(String(format: "%.1f", expected))px 实际=\(String(format: "%.1f", total))px")
    print("   首次移动=\(firstMove)帧(\(String(format: "%.0f", Double(firstMove) * dt * 1000))ms)  90%=\(at90)帧(\(String(format: "%.0f", Double(at90) * dt * 1000))ms)  归位=\(idleAt)帧(\(String(format: "%.0f", Double(idleAt) * dt * 1000))ms)")
    print("   余量 target=\(String(format: "%.1f", axis.target)) current=\(String(format: "%.1f", axis.current)) sent=\(String(format: "%.1f", axis.sent))")
}

// 反向 + 非平滑轴
func scenarioReverse() {
    let tau = 0.006 + 0.45 * 0.45 * 0.26
    var axis = ScrollAxis()
    axis.jump(-10 * 2.4)          // 反向 + 不做平滑
    var total = 0.0
    for _ in 0..<10 {
        total += Double(axis.advance(dt: 1.0 / 120.0, tau: 0))
        if axis.isIdle { break }
    }
    print("── 非平滑反向轴")
    print("   预期=-24.0px 实际=\(String(format: "%.1f", total))px")
}

print("=== Smoose 插值引擎离线验证 ===")
scenario(label: "单格滚轮 · 默认手感", notches: 1, everyFrames: 1)
scenario(label: "连续快速滚动 20 格（每 3 帧一格 ≈ 40Hz）", notches: 20, everyFrames: 3)
scenario(label: "疯狂甩动 60 格（每 1 帧一格 ≈ 120Hz）", notches: 60, everyFrames: 1)
scenario(label: "60Hz 屏幕 + 单格", fps: 60, notches: 1, everyFrames: 1)
scenario(label: "极低顺滑度 0.05（干脆）", smoothness: 0.05, notches: 1, everyFrames: 1)
scenario(label: "极高顺滑度 1.0（长尾）", smoothness: 1.0, notches: 1, everyFrames: 1)
scenarioReverse()

// 方向突变：先向下再向上
var axis = ScrollAxis()
let tau = 0.006 + 0.45 * 0.45 * 0.26
for _ in 0..<20 { _ = axis.advance(dt: 1.0 / 120.0, tau: tau); axis.push(24) }
for _ in 0..<10 { _ = axis.advance(dt: 1.0 / 120.0, tau: tau); axis.push(-24) }
print("── 方向突变后 target=\(String(format: "%.1f", axis.target)) current=\(String(format: "%.1f", axis.current))")

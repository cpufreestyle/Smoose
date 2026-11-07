# Smoose SPEC — 功能规格与验证契约

> 面向维护者：每个功能给出「契约」（用户可感知行为）与「断言」（harness / 手工可验证证据）。
> 改引擎 / 队列 / 持久化代码后运行 ./run_tests.sh，全部 PASS 才算完成。

## 布局

| 路径 | 职责 |
| --- | --- |
| Sources/ScrollAxis.swift | 单轴插值状态机（纯逻辑，可离线编译） |
| Sources/ScrollEngine.swift | HID 拦截（滚轮/侧键/鼠标移动）、帧驱动投递、指针速度倍率 |
| Sources/PointerController.swift | 指针加速度读写（IOHIDServiceClient） |
| Sources/Actions.swift | 侧键动作执行（合成键/打开 App） |
| Sources/Model.swift | StoredState 配置模型（UserDefaults smoose.state） |
| Sources/UpdateModel.swift | 自动更新纯逻辑：SemVer 比较 + 版本清单解析（可离线编译） |
| Sources/Updater.swift | 自动更新运行时：拉版本源 / 下载 / 解压 / 替换 / 重启 |
| Sources/Views.swift | 所有 SwiftUI 界面 |
| Sources/App.swift | @main：tap 安装 / 前台监听 / Onboarding |
| Tests/InterpTest.swift | 插值离线测试（需复制成 main.swift 编译） |
| Probe/main.swift | 指针加速度读写探针（写后还原，安全） |
| run_tests.sh | 一键 harness（见 §7） |
| build.sh | swiftc 构建 + 证书签名 + icns 打包 |

## 1. 滚动平滑（核心）

**契约**：滚轮鼠标滚动被重建为连续曲线；最终滚动距离精确等于 Σ(原始格 × 倍率)；滚一半停下，页面停在半路不跳变。

**断言（harness §A）**：
- A1 单格 1×：总投递 == 预期总距离（误差 0）
- A2 连续 20 格 / 3 帧间隔：总量守恒
- A3 疯狂 60 格 / 每帧：总量守恒，单帧投递 ≤ 512
- A4 反向 + 非平滑轴：总量守恒，无符号反转错误
- A5 τ 公式：tau = 0.006 + smoothness² × 0.26
- A6 lag 防失控：单轴 lag > 1600px 截断

## 2. 距离倍率 / 最小步长

**契约**：speed = 0.2…8.0；minStep 以下微推被放大到至少 minStep。

**断言**：A7 speed=2.4 单格 → 24px 精确；A8 minStep 放大首位 ≥ (minStep × speed) 整数部分。

## 3. 双轴 / 反向 / 忽略触控板

**契约**：垂直/水平独立平滑与反转；连续滚动事件（field 88/99/123 任一非零）在 ignoreTrackpad=true 时整事件透传。

**断言（手工 M1）**：触控板双指滚动；观察 tap 无合成事件。

## 4. 每应用配置

**契约**：apps[bundleID] = profile 覆盖全局；预设一键套用。

两条「配了却静默失效」的修复（2026-11-01，用户实测反馈）：

1. **套用预设不得清掉加速键**：点「浏览器 / 干脆 / 丝滑」等预设时，只覆盖曲线参数
   （speed / smoothness / minStep），用户自己在「按住加速」里配好的修饰键与倍率必须原样保留。
   旧行为是 `prefs.global = p` 整体替换，`boostModifiers` 被清回 0 → 加速功能失效且无任何提示。
   例外：「跳过此 App」预设的 `enabled=false` 必须保留（不能被保留逻辑顺手打开）。
2. **新建每应用规则按白名单给建议档**：微信 / QQ / Slack / Discord / Teams（`ScrollProfile.chatBundleIDs`）
   这类自带滚动惯性的 App，新建规则时直接套「聊天软件」预设（speed 0.8），
   其余 App 没有建议档、回落「沿用全局」——不被强行改手感。

**断言（harness §B）**：profile(for:) 命中 app 配置；masterEnabled=false 返回 nil。

**断言（harness §S18-S24）**：`ScrollProfile.preset(named:preservingBoostFrom:)` 保留
boostModifiers/boostFactor 且覆盖 speed；「跳过此 App」仍 enabled=false；未知预设名返回 nil；
五个聊天 bundle id 全部命中「聊天软件」预设；Safari / VSCode 无建议档；
聊天预设倍率必须低于全局默认（防「建议档反而更快」）。

## 5. 侧键绑定

**契约**：按钮 3（中）/4（后侧）/5（前侧）绑定 ButtonAction；按下吞原击键，合成动作。

动作表（以 Sources/Model.swift 为准）：missionControl / launchpad / appSwitcher(⌘⇥) / showDesktop / back(⌘[) / forward(⌘]) / spaceLeft(^←) / spaceRight(^→) / screenshot(⇧⌘5) / copy(⌘C) / paste(⌘V) / none

**断言（harness §C）**：ButtonAction.allCases.count == 12；label 非空。新增 case 步骤：Model 加 case+label → Actions 加分支 → 本表加行 → harness 计数更新。

## 6. 指针控制（加速度 / 速度）

**契约**：
- 加速度：pointerAccelManaged=true 时外接鼠标 HID 键写为 value × 65536（IOFixed）；关闭时绝对不碰设备。
- 速度倍率：pointerSpeedManaged=true 时 mouseMoved delta × factor(0.2…4)，亚像素余量累积；拖拽事件不处理（保选区精度）。
- 设置热更新立即生效。
- 签名：build.sh 用 Apple Development 证书（DR 绑定证书非 cdhash），重编译部署后 TCC 授权保持。证书名变化时改 build.sh 标识串。

**断言**：
- D1（--device）：合成 mouseMoved(+5,+3) 在 0.5/2.0/关闭三档下 delta 变换正确。
- D2（手工）：合成滚轮 → 一串 userData 魔法值合成事件，指数衰减，总像素 = 原始 × 倍率，无回环。
- D3（手工）：Probe 3 次写入回读 ok=true，还原基线。

## 7. 一键 harness：./run_tests.sh

| 步骤 | 验证 | 失败含义 |
| --- | --- | --- |
| A | ScrollAxis + InterpTest 离线编译运行 | 插值 / 距离守恒坏了 |
| B | profile(for:) 命中逻辑离线断言 | 每应用 / 总开关坏了 |
| C | ButtonAction 计数与 label 完整性 | 按键动作枚举被改动 |
| D | 自动更新决策（SemVer / 清单解析 / 系统门槛）离线断言 | 版本比较或 GitHub 清单解析坏了 |
| D（--device） | 速度倍率合成事件 | 引擎 tap / 热更新坏了 |
| E | ./build.sh 构建通过 | 编译回归 |
| F | ./scripts/release.sh 产出端独立复核 | 发布出来的包装不上 / bundle id 漂移 |
| G | 编译**真实** `Sources/UpdateModel.swift` 反 drift | harness 副本与真源码漂移 |
| G2 | 文本守卫 `Sources/Updater.swift` 的 `httpMessage` 分支 | 副本更新了、真源码没更新 |
| G3 | 文本守卫 `Sources/Updater.swift` 的 `relaunch` 退出路径 | `NSApp` 隐式解包崩溃回归 |
| F2 | `release.sh` 参数解析 + `gh` 路径解析 | `--repo owner/name` / Homebrew gh 路径回归 |
| H | 编译真实 `Sources/` 断言自动更新安全加固 | https 强制 / Team ID / sha256 / 拒 ad-hoc 回归 |
| H26–H28 | `Updater.replaceApp(at:target:)` 回滚契约 | 替换成功 / 验签失败回滚 / 新包缺失回滚 |
| H29–H30 | 签名身份 Authority 变化检测 | 提取证书 CN / ad-hoc 为空 / 提示重新授权 |
| S18–S24 | 编译**真实** `Sources/Model.swift`：预设保留加速键 / 聊天 App 建议档 | 套预设清掉 boost、白名单漏 App、建议档反而更快 |
| S25–S27 | 文本守卫 `Views.swift` ↔ `ScrollBoost.maxScale` 同源 | 滑条写死上限、引擎上限被改成 0 / NaN |
| S28–S29 | 编译真 `Sources/ScrollAxis.swift` 验键位冲突判定 + Views 接线 | 加速键与透传键同键时无提示 |
| S30 | 文本守卫 `LogitechHIDPP` 事件驱动 | 回到 5 秒轮询、漏注册 removal、Unmanaged 引用泄漏 |
| S31 | 文本守卫 `PointerController` / `Model.swift` 配置通知 | 通知没真发、签名没判空、轮询太长(>10s)或退化成全量枚举、漏插拔回调、读数没进签名 |
| S32 | 编译真 `Sources/Updater.swift` 验 `dismiss()` 不丢已安装更新 | 守卫被删、守卫顺序错、busy 守卫被拿掉 |
| S33–S34 | 文本守卫菜单栏 / 关于页更新出口 | 菜单栏不显示下载/安装/待重启、加回「稍后再说」、关于页出口被挤掉 |
| S35–S39 | 游戏页出口 / 合成事件相位 / 点击刹车 / 接线守卫 | 相位常量漂移、收尾帧丢失、UI 与引擎脱节 |
| **I**（2026-11-06） | 编译真 `PointerController.swift` 验加速度签名对 **HID 参数读数漂移**敏感（14 项） | 系统把 `HIDMouseAcceleration` 重置回默认后永久短路（静置后起步发黏） |

用法：
    ./run_tests.sh                                        # 普通终端，离线，PASS=27 FAIL=0
    SMOOSE_SWIFT_EXTRA=-disable-sandbox ./run_tests.sh    # 受限环境（CI / agent 沙箱，Swift 宏需子进程）

> ⚠️ **`--device` 的真实边界（2026-10-27 实测确认，勿再重复尝试）**：`--device` 段当前
> **不在 `run_tests.sh` 里实现**，SPEC 早期把它列为 D 段真机断言，但没有任何可执行断言。
> 原因是 macOS 在 CLI / harness 上下文里把这条路全堵了，逐条实测过：
>
> | 方案 | 实测结果 |
> | --- | --- |
> | CLI 进程装 `CGEventTap` + 合成事件 post 到 `.cghidEventTap` / `.cgSessionEventTap` / `.cgAnnotatedSessionEventTap` | tap 创建后 `tapIsEnabled` 立刻变 `false`，轮询 re-enable 也救不回；注入的 scrollWheel / mouseMoved **0 命中**。即便 `AXIsProcessTrustedWithOptions` 返回 true 也不管用 |
> | `lldb -p <pid>` attach 进已授权的 Smoose，Swift 表达式调 `handlePointerMove` | 能 attach，但产物 strip 过调试符号，`image lookup -s handlePointerMove` 空，`expr -l swift` 报 `cannot find 'ScrollEngine' in scope` |
> | `DYLD_INSERT_LIBRARIES` 注入断言 dylib 到 app 副本（bundle id 与真机一致以复用 TCC 授权） | app 副本起不来（`sandbox_extension_issue_file_to_process`）；换到合法路径后进程能起，但 `@_cdecl` 构造器不被触发、加 `__attribute__((constructor))` shim 后进程起不来。符号与 app 自身 `Sources/` 重复定义 |
>
> 结论：**指针速度改写这条链路目前没有可自动化的真机断言载体**。改 `handlePointerMove`
> 之后只能人工验证：开「指针速度倍率」→ 移动鼠标 → 手感是否随倍率变化。
> 相关源码逻辑由 H 段之外的编译期断言覆盖不到，请勿在 harness 里放一个假绿的 `--device`。

## 8. 配置注入与现场恢复

StoredState 注入用 <data> 包装 JSON（不是 <string>），defaults import 整份 plist；改完须重启 Smoose。
现场还原：关闭 pointerAccelManaged 后跑 Probe 一次可把加速度写回系统值；动 smoose.state 前先 defaults export 备份。

## 9. 未来功能落位规则

新功能必须同时落到：
1. SPEC.md 加「契约 + 断言」节
2. 可离线测的逻辑放纯逻辑文件（ScrollAxis 模式），配进 harness 某节
3. 真机 / 授权断言放 harness 的 --device 节
4. HANDOFF.md §8 勾掉对应项并更新「项目状态」表


## 10. 侧键高级绑定（2026-10-13 从 myMouseMagic 复刻）

**契约**：
- 交换后/前侧键：全局开关 `swapBackForward`，开启后 button 4 的事件按 button 5 处理（反之亦然）。
- 触发时机：`triggerOnMouseUp=false`（默认）按下触发；`true` 抬起触发。
- 每应用侧键覆盖：`appBindings[bundleID][buttonNumber] = actionRawValue`；留空的 App 走全局 `bindings`。
- 新动作 App Exposé：合成 ⌃↓（keycode 125 + maskControl）。

**断言（harness §C 扩展）**：
- C1 `ButtonAction.allCases.count == 13`（新增 appExpose）。
- C2 `StoredState.bindings(for:)` 纯逻辑测试：appBindings 有该 App 时覆盖 global；无时回退 global。
- C3 （手工 D3，--device）合成侧键 4/5 按下，观察键盘 tap 收到 ⌘C(8)/⌘V(9) 合成事件。

## 11. 滚轮行数（2026-10-14）

**契约**：`wheelLines` (0.2…5.0, 默认 1.0) 每格滚轮的行数缩放，只作用于离散滚轮事件（field 88/99/123 全零）；触控板 / Magic Mouse 的连续滚动不受影响。与距离倍率（speed）相乘生效：最终像素 = 原始格 × wheelLines × speed。

**断言**：
- E1（离线引擎日志，已验证）：注入 wheelLines=0.3，引擎内 `lineScale=0.3` 生效（rawY=10 → scaledY=3）。
- E2（手工）：真机浏览器滚动对比 0.5× vs 2× 的行距离（可感知差异明显）。
- E3：默认 1.0 时行为与改动前完全一致（回归安全）。

## 12. 跟手性优化（2026-10-14，反编译 BetterTouchTool 后移植）

契约：
- 自适应 tau：ScrollAxis.advance 里 lag 超过 24px 时按 24/lag 比例压缩时间常数（下限 baseTau 的 0.4 倍），快速甩动时越甩越跟手，消除「停住等追上」的顿挫。距离守恒不受影响（只改逼近速度不改目标）。
- 最小步长只对离散滚轮生效：prepare(continuous:) 为 true 时跳过 minStep 放大，触控板轻扫保留亚像素细节。

断言：
- F1（harness A 节）：距离守恒全过，自适应 tau 不改变最终投递总量。
- F2（离线）：lag 24px 时 tau 不变；lag 800px 时约 0.55 倍；lag 1600px 以上 0.4 倍封底。
- F3（手工）：真机连续快滚 20 格，确认尾段不停顿、总距离守恒。

## 13. 每应用滚轮调校（2026-10-14）

契约：
- 微信等聊天软件自带滚动惯性，全局倍率叠上去会过快。新增「聊天软件」预设：speed 0.8 / smoothness 0.45 / minStep 2.5。
- 每应用配置通过 apps[bundleID] 覆盖全局；bundle id 为 com.tencent.xinWeChat（微信）、com.tencent.qq（QQ）。

断言（真机已验）：
- G1 微信前台 → 引擎解析 speed=0.80（per-app 覆盖生效）。
- G2 其他 App 前台 → 引擎解析 speed=全局值（fallback 正常，Safari 实测 1.50）。
- G3 harness A/B/C/E 全过（预设新增不影响距离守恒与枚举计数）。

## 14. 反编译 myMouseMagic 深度复刻（2026-10-16）

契约：
- **抬起触发配对抑制**：`triggerOnMouseUp=true` 时 DOWN 被吞掉并记入 suppressedButtons；UP 到来时只有配对的那次才执行动作并被吞掉。孤立的 UP（无配对 DOWN）不触发、不吞。避免残留半边事件触发系统默认行为（myMouseMagic MouseEventService 的 suppressedButtons 模式）。
- **权限双向监测**：信任轮询常驻。授权被系统撤销时主动停 tap（Revoked 分支）；恢复授权后自动重建（Granted 分支）。之前只在「未授权→授权」单向恢复。
- **按键测试面板**：按键页新增「按键测试」区块，实时显示按下的鼠标按键编号。双监听：local monitor 捕获本 App 前台事件，global monitor 捕获其他 App 前台事件（myMouseMagic ButtonsSettingsViewController 的 localMonitor + globalMonitor 模式）。
- **单实例保护**：启动时检测同 bundleID 的其他进程，发现重复实例弹窗提醒后退出（myMouseMagic AppDelegate 的 alreadyRunning 模式）。防止 open -n 双启动导致双 event tap 冲突。
- **退出确认**：菜单栏面板退出按钮加二次确认弹窗，防止误触（myMouseMagic 的 quitConfirm 模式）。

断言（已验证）：
- H1 合成 button 3 / 4 事件 CGEventPostToPid 后，AX 树显示「检测到按键 3」「检测到按键 4」（真机验证通过）。
- H2 权限撤销后 System Events 收回信任 → 1 秒内 tap 停止；恢复信任 → 1 秒内 tap 重建（代码逻辑审查，未做真机撤销测试）。
- H3 harness A/B/C/E 全过（2026-10-16 PASS=4 FAIL=0）。
- H4 open -n 双启动：第二实例弹「已在运行」后自动终止，只剩一个进程（真机验证通过，2026-10-16）。

来源：rea-decompiler 反编译 myMouseMagic.app（com.biomsoft.myMouseMagic v1.0，Mach-O universal 866KB），报告位于 /tmp/rea-mmm/re-myMouseMagic.md。

## 15. 设置窗口多屏定位修复（2026-10-18）

契约：
- **现象**：用户报告「界面打不开」。实际是设置窗口能打开，但被还原到了左侧副屏（-1152,-1079 1152x2048 竖屏），主屏上看不到任何窗口。
- **根因**：SwiftUI `Settings` 场景把窗口位置持久化到 UserDefaults 的 `NSWindow Frame com_apple_SwiftUI_Settings_window`，其末尾四元组记录上次所在的屏幕。一旦该值是副屏，之后每次打开都还原到副屏。这不是崩溃，也不是代码缺陷，是 macOS 多屏窗口位置记忆的固有行为。
- **修复**：扩展现有的 5 秒 healTimer（原本只守护 status item），增加设置窗口位置检查——对每个可见的带标题栏窗口，若其中心点不在主屏 frame 内，则移动到主屏可见区域居中。与 status item 的自愈逻辑同源，不依赖任何委托回调。
- **设计取舍**：菜单栏图标本就固定在主屏（多屏/幽灵屏环境的既有决策），设置窗口跟随主屏是一致的。代价是用户无法把设置窗口留在副屏——下次 heal 会被移回。

断言（已验证）：
- I1 将 `NSWindow Frame com_apple_SwiftUI_Settings_window` 手工写为副屏坐标（`-781 533 560 600 -1152 13 1152 2018`），重启并 `open smoose://settings` 后，窗口落在主屏 (597,278)，`kCGWindowListOptionOnScreenOnly` 计数为 1。
- I2 App 重新持久化的 frame 变为 `476 202 560 600 0 0 1512 949`，末尾 `0 0 1512 949` 即主屏，证明位置已被纠正并记住。
- I3 harness A/B/C/E 全过（2026-10-18 PASS=4 FAIL=0）。

备注：排查过程中曾误判为 MichaelClip 的问题并做了大量无效改动，实际对象一直是 Smoose。教训：用户说「打不开」而未指明 App 时，应先确认目标进程与窗口状态再动手。

## 16. 指针 tab 图标符号名修正（2026-10-18）

契约：
- **现象**：用户报告「看不到图标」，截图显示 tab 栏「指针」只有文字没有图标。
- **根因**：tab 标签用了 `systemImage: "arrow.cursor"`，这不是 SF Symbols 的有效名称（有效名是 `cursorarrow`，内容区图标用的就是它）。无效符号名时图标退化为残缺/不渲染。
- **修复**：`Label("指针", systemImage: "arrow.cursor")` → `Label("指针", systemImage: "cursorarrow")`。同时核查了全部 9 处符号名，其余均有效。

断言（已验证）：
- J1 同状态对比（指针 tab 选中）截图：修复前图标是左边缘的残缺图形，修复后是完整居中的实心箭头。
- J2 内容区「指针卡片」的 `cursorarrow` 图标以 accent 蓝正常渲染（蓝色像素簇 + 箭头形状确认）。
- J3 tab 栏 5 个 tab 的图标全部渲染（粗渲染可见 5 个图标簇）。
- J4 harness A/B/C/E 全过（2026-10-18 PASS=4 FAIL=0）。

## 17. 桌面图标启动无反馈修复（2026-10-18）

契约：
- **现象**：用户报告「窗口只能显示状态栏打开 桌面无法显示」。桌面是指向 /Applications/Smoose.app 的别名，双击后 App 启动但屏幕无任何窗口。
- **根因**：Smoose 是 `LSUIElement = true` 的菜单栏 App，启动后只装 status item，不开窗口；且未实现 `applicationShouldHandleReopen`，双击别名（已运行时）只触发激活，不弹窗口。
- **修复**：
  1. 新增 `applicationShouldHandleReopen` → 打开设置窗口（App 已运行时双击别名/Dock 图标）。
  2. 冷启动后延迟 0.8s 检查 `NSApp.isActive`：被激活（用户双击）才开窗口；未激活（登录项启动）不开，避免每次登录弹窗。

断言（已验证）：
- K1 冷启动 `open ~/Desktop/Smoose`（桌面别名）→ 设置窗口出现在主屏 (597,278)，onscreen=1。
- K2 App 已运行时 `open` 别名 → 窗口保持 focused/main，onscreen=1。
- K3 harness A/B/C/E 全过（2026-10-18 PASS=4 FAIL=0）。
- K4 登录启动不开窗：由 `NSApp.isActive` 门禁保证（代码逻辑，未做注销登录实测）。

## 18. 桌面双击启动无窗口修复（2026-10-18，纯 AppKit 化）

契约：
- **现象**：用户报告「窗口只能显示状态栏打开 桌面无法显示」「桌面双击 Smoose 弹不出」。桌面别名指向 /Applications/Smoose.app，双击后 App 启动但无窗口。
- **根因链**（四个问题叠加）：
  1. `.accessory` 激活策略（LSUIElement）下 App 无法被 LaunchServices 激活，`open` 已运行实例完全空操作（不发 reopen、不触发任何回调）。
  2. SwiftUI `Settings` 场景的窗口一关即销毁，`showSettingsWindow:` 再也重开不了（URL scheme 也失效）。
  3. `.regular` 策略下 SwiftUI `Settings` 场景会在启动时自动弹出空窗口（900x450、EmptyView）。
  4. 未实现 `applicationShouldTerminateAfterLastWindowClosed`，关窗后 App 退出。
- **修复**：
  1. 激活策略 `.accessory` 改为 `.regular`，并在 didFinishLaunching 手动 activate。
  2. 去掉 SwiftUI App 协议，改用纯 AppKit 入口（Sources/main.swift），彻底消除 Settings 场景自动弹窗。
  3. 设置窗口改为 AppDelegate 手动管理（NSWindow + NSHostingView），windowShouldClose 返回 false 并 orderOut —— 关闭只隐藏不销毁，可反复重开。
  4. applicationShouldTerminateAfterLastWindowClosed 返回 false。
  5. 冷启动总是打开设置窗口。

断言（已验证）：
- L1 冷启动 open ~/Desktop/Smoose 后仅一个窗口 Smoose 560x548，无空 Settings 窗口。
- L2 隐藏窗口后 open ~/Desktop/Smoose，PID 不变（reopen 非重启），窗口重新出现，App 成为前台。
- L3 关窗后 App 存活。
- L4 harness A/B/C/E 全过（2026-10-18 PASS=4 FAIL=0）。

已知取舍：
- App 现在有 Dock 图标（.regular 的必然结果）。若希望恢复无 Dock 图标的纯菜单栏形态，需放弃「桌面双击弹窗」这一需求，二者不可兼得。
- 登录时启动也会弹设置窗口。如需区分，可在 main.swift 检测登录项启动来源。

## 19. 指针起步慢补偿（2026-10-18）

契约：
- **现象**：用户报告「鼠标刚移动时候会很慢 后面正常」——典型的指针加速曲线症状。
- **诊断**：只读探针实测鼠标 `HIDMouseAcceleration = 0.0`，即 Smoose 的写入已生效（严格线性）。但慢启动依旧，证明 macOS 在 HID 参数之上还有一层自己的指针加速曲线，`HIDMouseAcceleration=0` 关不掉它（macOS 27.0.1 实测）。
- **修复**：在 `handlePointerMove` 增加线性化补偿——当 `pointerAccelManaged` 开启时，对幅度 < 8px 的小幅移动按 `1 + (8 - mag) * 0.22` 放大（1px → 2.54×，4px → 1.88×，8px → 1×），大幅移动不干预以免后程过快。与用户速度倍率相乘。
- **效率考虑**：只有小幅移动走「改写+重投递」路径，大幅移动仍直接透传，不为全量鼠标事件增加延迟。

断言（已验证）：
- M1 只读探针确认 `HIDMouseAcceleration = 0.0`（Smoose 写入生效）。
- M2 harness A/B/C/E 全过（2026-10-18 PASS=4 FAIL=0）。
- M3 部署二进制与构建产物 md5 一致，冷启动窗口正常。
- M4 补偿强度是单个常量（0.22），不适配时改这一个数字即可，无需改结构。

未验证项：
- 补偿后的实际手感需用户真机确认（无法程序化模拟指针移动的主观感受）。


## 19 修正. 指针线性化的正确做法（2026-10-18）

调补偿依然不对。用户反馈「要么关闭要么别变大」后找到真根因。

**真根因**：事件在 cghidEventTap 拦截后又从 cghidEventTap 重投递，macOS 会把这个事件再过一遍指针加速曲线。所以无论怎么调补偿系数都不对：放小了起步依然肉（被曲线压回去），放大了低速窜一大截（被曲线二次放大）。

**修复**：改为 event.post(tap: .cgSessionEventTap) —— 从 session 层投递，绕过加速曲线。delta 是多少，光标就动多少，这才是真正的线性。同时删掉所有补偿系数。

**机制验证**：独立程序向 session 层投递 delta=(40,0) 的 mouseMoved，实测光标 X 轴精确移动 40.0px（与 delta 完全一致，加速曲线未参与）。

**代价**：接管加速度时每个 mouseMoved 都要走改写+重投递路径（原来可直接透传）。开销很小，但存在。

**备注**：真正的线性感受还取决于系统跟踪速度。若觉得整体慢，调高该值即可，Smoose 不应自己再叠一层缩放。

## 20. 光标放大开关（2026-10-18）

契约：
- **需求**：加一个「快速移动鼠标时鼠标图标面积变大」的开关。
- **定位**：这是 macOS 自带功能「摇动鼠标指针以定位」（系统设置 → 辅助功能 → 显示），描述为「快速来回移动鼠标指针以放大」。Smoose 只提供入口，不自己实现放大逻辑。
- **偏好键**：`.GlobalPreferences` 的 `CGDisableCursorLocationMagnification`。键名带 Disable，语义反转：
  - 功能开 → 键 = false（0）
  - 功能关 → 键 = true（1）
- **映射确认方式**：GUI 实测——点击系统设置复选框前后各读一次键值，确认 勾选↔0、不勾↔1。
- **同步方向**：启动时以系统状态为准（用户可能在系统设置里改过），Smoose 的开关不覆盖系统；用户拨动 Smoose 开关时才写入系统。

断言（已验证）：
- N1 独立程序复现控制器读写逻辑：apply(true)→键 0/systemEnabled true，apply(false)→键 1/systemEnabled false，往返一致。
- N2 启动后系统键保持原值 1（未被 Smoose 覆盖）。
- N3 harness A/B/C/E 全过（2026-10-18 PASS=4 FAIL=0）。

实现：
- `Sources/CursorZoom.swift`：读写系统偏好键（含键缺失时按系统默认开启的处理）。
- `Model.swift`：新增 `cursorZoomEnabled` 持久化字段。
- `Views.swift` PointerTab 新增「光标放大」Section + Toggle，onChange 时写入系统。
- `App.swift` 启动时 `syncCursorZoomFromSystem()` 以系统状态校准 UI。

## 20 修正. UserDefaults.standard 写 .GlobalPreferences 不落盘（2026-10-18）

**坑**：首版用 `UserDefaults.standard.set` 写 `CGDisableCursorLocationMagnification`，用户反馈「开关关闭没效果」。

**实测证据**（macOS 27.0.1）：
- Swift 进程 `UserDefaults.standard.set(false, ...)` 后进程内读回 0
- 但 `defaults read .GlobalPreferences CGDisableCursorLocationMagnification` 仍为 1
- `plutil -p ~/Library/Preferences/.GlobalPreferences.plist` 直接读文件也是旧值
- 等 3 秒后依然不变 —— 写入从未落盘，系统永远收不到变更

**修复**：改用 `UserDefaults(suiteName: ".GlobalPreferences")`。实测该方式的写入立即落盘，`defaults read` 能读到。

**结论**：在现行 macOS 上，`UserDefaults.standard` 对 `.GlobalPreferences` 域**只读不写**（读能读到旧值，写只进进程缓存）。凡是要改系统级全局偏好的功能，必须用 `UserDefaults(suiteName: ".GlobalPreferences")` 或 `CFPreferencesSetValue` 显式指定域。

## 20 修正 2. CGAssociateMouseAndMouseCursorPosition 会造成 Dock 粘滞（2026-10-19）

**现象**：用户反馈「在程序坞中，鼠标会被程序的图标粘住」。排查发现是上一版为了强制光标放大开关生效，在 `CursorZoomController.apply` 里调用了 `CGAssociateMouseAndMouseCursorPosition(0)`。

**原因**：该调用会把鼠标和光标解绑，系统随后把 Dock 图标当成悬停/拖拽目标，表现为「粘住」。关闭光标放大后用户实测「光标不放大，也会粘住」，证明副作用独立于光标放大本身。

**修复**：从 `CursorZoomController.apply` 移除该调用。开关只写偏好键，接受系统可能要重启 Smoose / 注销后才完全生效。

**禁止**：不要再往这个开关里加 `CGAssociateMouseAndMouseCursorPosition`。

## 20 修正 3. Dock 图标粘住的真正根因（2026-10-19）

**现象链**：用户报告「在程序坞中，鼠标会被程序的图标粘住」，且关闭光标放大后仍复现。

**两个叠加原因**：
1. 上一版在 `CursorZoomController.apply` 里调用了 `CGAssociateMouseAndMouseCursorPosition(0)`，把鼠标与光标解绑，造成 Dock 把图标误判为拖拽目标（已移除，见修正 2）。
2. `ScrollEngine.handlePointerMove` 在 `pointerAccelManaged=true` 时也会吞掉 `mouseMoved` 事件、改写 delta 后从 session 层重新合成投递。合成事件在部分 UI（尤其是 Dock）里表现为异常输入，图标会被「粘住」。

**修复**：
- `handlePointerMove` 只在真的需要改速度时才改写事件；`pointerAccelManaged` 不再作为改写条件。
- 改写后不再吞事件重建，而是原地改 delta 后 `Unmanaged.passUnretained(event)` 放行。
- 加速度接管继续由 `PointerController` 在 IOHID 层完成（写 0），与这里互不干扰。

**验证**：`run_tests.sh` PASS=4 FAIL=0；构建通过；已重新部署并启动。用户需手动确认 Dock 是否还会粘住。

## 20 修正 4. Dock 放大失效（2026-10-19）

**现象**：上一版修复「Dock 粘住」时，把 `handlePointerMove` 改成了只在 `pointerSpeedManaged` 时改写事件，并把 `pointerAccelManaged` 从改写条件里去掉。结果接管加速度时（硬件加速度写 0），Dock 的 hover 放大失效。

**根因**：`handlePointerMove` 在 `pointerAccelManaged=true` 时仍然吞掉 `mouseMoved` 事件、改写 delta 后从 session 层重新合成投递。合成事件在 Dock 里不再触发 hover 放大动画。

**修复**：
- `handlePointerMove` 增加 Dock / Finder 前台白名单：这两个 App 前台时**不改写任何鼠标移动事件**，原样放行，保证 Dock 的 hover 放大和 Finder 拖拽反馈正常。
- 其他 App 前台时，继续只在 `pointerSpeedManaged` 且 factor != 1 时改写，改写后原地放行（不吞事件重建）。

**验证**：
- `run_tests.sh` PASS=4 FAIL=0
- 合成鼠标事件移到 Dock 图标上，Smoose 图标正确放大（截图确认）
- 构建、签名、部署通过

## 21. 自动更新（2026-10-22 · 同日二次修订）

### 契约

- **检查频率**：`autoCheckUpdates=true`（默认）时每 24 小时静默检查一次，启动后 5 秒触发首次检查；关闭后只在用户点「检查更新」时联网。
- **失败重试间隔 1 小时**（`Updater.retryInterval`）：失败时也写 `lastCheck` 时间戳，若仍按 24h 节奏，启动时断一次网会让接下来 24 小时都不再静默检查（2026-10-22 实测缺陷）。`checkIfNeeded()` 读 `smoose.update.lastCheckFailed` 标记决定用哪个间隔。
- **版本源**：默认 `https://api.github.com/repos/cpufreestyle/Smoose/releases/latest`；用户可在「关于 → 自动更新」覆盖为任意自建 JSON / GitHub Releases API 地址（存 `UserDefaults` key `smoose.update.feed`，**不进 StoredState**，避免发布配置和手感配置混在一起）。
- **默认版本源当前状态（2026-10-22，已打通）**：仓库 `https://github.com/cpufreestyle/Smoose` 已创建为 public，已发 v1.1.0 与 v1.2.0 两个 Release，asset 为 `Smoose-<version>.zip`（`content_type: application/zip`）。默认源对用户**真实可用**：实测 `GET /releases/latest` 返回 200，`UpdateManifest` 解出 `version=1.2.0` + `browser_download_url`，`decide` 对旧版报 `available`；安装包 HTTP 200 可下载。**仓库必须 public**——App 的版本源请求不带认证，private 仓库 API 会返 404，自动更新直接失效。
- **开箱可用的替代路径**：用户也可在「关于 → 自动更新」填自建 JSON 版本源（形状见下），不依赖 GitHub。
- **版本源形状**：同时吃两种格式（`Sources/UpdateModel.swift: UpdateManifest`）：
  1. 自建 JSON：`{"version":"1.1.0","url":"https://.../Smoose.zip","notes":"...","minSystem":"14.0"}`
  2. GitHub Releases API：`{"tag_name":"v1.1.0","assets":[{"name":"Smoose.zip","browser_download_url":"..."}],"body":"..."}`
- **只有新版才提示**：`SemVer` 比较，`1.2.10 > 1.2.9`、`1.10.0 > 1.9.9`；`1.0 == 1.0.0 == v1.0`；预发布版 < 正式版；`+build` 元数据不参与比较。
- **系统门槛**：清单带 `minSystem` 且当前 macOS 更低时，明确提示「需要 macOS X 或更高」，不进入下载流程（而不是下载一个装不上的包）。
- **安装包地址**：只有以 `.zip/.dmg/.tar.gz` 结尾、或 `content_type` 是 `application/zip` / `application/x-zip-compressed` / `application/x-apple-diskimage` 这类归档 MIME 的 URL / asset 才会被当成下载地址。GitHub Releases 的 `content_type` 就是无后缀 MIME，只匹配后缀会漏掉它。**GitHub 的 `url` 字段是 API 地址不是下载地址**，必须从 `assets[].browser_download_url` 里取。
- **安装**：发现新版本后先停在「发现新版本 vX + 下载并安装 / 暂不更新」（`Updater.Phase.updateFound`），用户点了「下载并安装」才走下载 → `/usr/bin/unzip` 解压 → 递归找 `Smoose.app` → 替换 `/Applications/Smoose.app` → `NSWorkspace.openApplication(createsNewApplicationInstance:)` 起新进程后退出旧的。旧版先搬到临时目录，替换失败会搬回去。**检查链路绝不能直接跳到「立即重启」**——那会重启到同一个旧版本（2026-10-22 缺陷，`downloadAndInstall()` 曾经没有任何 UI 入口）。
- **失败必须给可操作原因**：地址无效 / 无法连接 / HTTP 4xx / 清单无法解析 / 缺安装包地址 / 系统版本不够，各自独立文案。
- **不重复打扰**：静默检查（定时、启动）失败不弹窗、不写状态，只有用户手动点「检查更新」才显示错误。
- **静默检查也必须置位 phase**：发现新版本时无论 `interactive` 与否都推到 `Phase.updateFound`，菜单栏面板顶部因此有横幅，用户点开图标就能处理。只在 `interactive=true` 时置位的话，不主动打开「关于」页的用户永远看不到新版，自动更新退化成手动更新（2026-10-22 缺陷）。
- **跳过此版本**：`skipVersion(_:)` 把版本号写进 `UserDefaults` key `smoose.update.skipped`（数组）。被跳过的版本静默检查不再提示；手动检查时显示 `Phase.skipped(v)` 明确告知「已跳过」，而不是什么都不说。
- **下载进度是真实增量**：用 `URLSessionDownloadDelegate` 而不是 completion-handler，否则百分比一直停在 0% 然后突然跳完（2026-10-22 缺陷）。
- **安装过程在后台队列**：解压 + 拷贝丢到 `DispatchQueue.global(qos: .userInitiated)`，主线程不卡，「正在安装」界面保持响应。
- **安装前校验 bundle id**：版本源是用户可填的任意地址，替换 `/Applications/Smoose.app` 前必须读新 App 的 `CFBundleIdentifier`，不等于 `app.smoose.macos` 就中止（`UpdateInstallError.wrongBundle`），防止一个不相关的 App 覆盖掉用户的正版。
- **更新链路是远程代码执行入口，必须验身份（2026-10-26 P0，2026-10-27 补 harness）**：App 持有辅助功能权限，所以「更新」等同于把任意代码放进高权限位置。四道关缺一不可：
  1. **强制 HTTPS**：`Updater.validatedURL(_:)` 只放行 `https`；`http` 仅限回环（`localhost` / `127.0.0.1` / `::1`，供自建源自测）。**版本源地址与下载地址都过这一关**。明文 http 的响应可被链路上任何人改写 = 一次劫持即 RCE。IPv6 回环要先把 `URLComponents.host` 的方括号剥掉再比（2026-10-27 实测：不剥则 `[::1]` 永远匹配不上，承诺的放行失效）。
  2. **SHA-256 校验**：`UpdateManifest.sha256`（也认 `sha256_sum` / `digest`），版本源给了就验、没给就跳过（不阻断既有流程）。流式计算，不把整个包读进内存。
  3. **codesign 完整性**：`codesign --verify --deep --strict`。
  4. **发布者身份**：比对 `codesign --display --verbose=4` 输出的 `TeamIdentifier` 与 `Updater.expectedTeamIdentifier`（默认 `6U2DQJ6Z2N`，可用 Info.plist 的 `SmooseUpdateTeamID` 覆盖）。ad-hoc 签名能过完整性校验但拿不到 Team ID，必须拒。拷贝落盘到 `/Applications` 之后**再验一次**，失败回滚原版——不留「旧版没了、新版不可信」的半截状态。
  ⚠️ **Team ID 不是证书名括号里那串**：本机签名身份是 `Apple Development: qm0819@hotmail.com (5F66DDWD6H)`，但 `codesign` 报告的 `TeamIdentifier=6U2DQJ6Z2N`。照抄证书名会让每次更新都被拒（2026-10-26 实测踩到）。
  ⚠️ **bundle id 不是身份校验**：它只是 Info.plist 里的字符串，谁都能写，只能挡住「下错包」，挡不住攻击者。
- **发布端必须同标准自检**：`scripts/release.sh` 打出包后除 bundle id / zip 布局外，还要确认拿得到 `TeamIdentifier`——ad-hoc 直接 `exit 1`，避免产出「用户永远装不上」的包；并额外产出 `dist/Smoose-<ver>.json`（含 sha256），可直接自托管当版本源。
- **构建签名三级回退**（2026-10-27）：`SMOOSE_SIGN_ID` 环境变量 → 自动探测本机钥匙串里的 Apple Development 证书 → ad-hoc 并明确警告。只认环境变量会让默认路径坏掉：不 export 就产出 ad-hoc 包，被上面的发布端自检拒绝（2026-10-27 实测 F stage 直接红）。
- **重启自己不能崩**：`relaunch()` 里退出旧进程必须写 `if let app = NSApp { app.terminate(nil) } else { exit(0) }`。`NSApp` 是隐式解包的全局 optional，在探针 / 单元测试 / 无 NSApplication 的上下文里是 nil，直接 `NSApp.terminate(nil)` 会 `Fatal error: Unexpectedly found nil`（2026-10-22 端到端实测崩在这行）。
- **发布端必须真签名**：测试用的「假新版」不能靠 `plutil` 改 Info.plist 生成——那会让 `_CodeSignature` 与 Info.plist 不符，`codesign --verify` 报 `invalid Info.plist`，装上去 LaunchServices 直接拒绝启动（`Launch failed`）。必须改版本号后重跑 `build.sh` 重新签名。

### 断言（harness §D，已验证）

- D1 版本比较：`1.0.0 == 1.0`、`v2.0 == 2.0.0`、`1.2.10 > 1.2.9`、`1.10.0 > 1.9.9`、`2.0.0 > 2.0.0-beta.1`、`1.0.0-alpha < 1.0.0-beta`、`1.2.3+build9 == 1.2.3`；`abc` / `1.x.3` 解析失败返回 nil。
- D2 决策：新版 → `available`；同版本 / 旧版本 → `upToDate`；`minSystem` 高于当前系统 → `systemTooOld`；相等 → 放行；GitHub `tag_name` + `assets` 形状 → `available`；`{"message":"Not Found"}` 和非 JSON → `malformed`。
- D3 安装包地址抽取：`url` 指向 `api.github.com/...` 时不当作下载地址，改从 `assets` 取 `.zip`。
- D4 安装包地址抽取（`installURL(json:)` 独立断言，与 `Manifest.init(from:)` 同源）：自建 JSON 的 `.zip` URL 直接采用；GitHub `assets[].name` 带 `.zip` 后缀时采用；**GitHub `assets[].content_type` 是 `application/zip` 这种无后缀 MIME 时也要能认出来**（2026-10-22 真实缺陷：此前只匹配后缀，导致所有 GitHub 用户「看得到新版、下载不到安装包」）；`url` 是 API 地址或清单里没有安装包时返回 nil。
- D5（--device）：真机点「检查更新」→ 状态文案；点「下载并安装」→ ProgressView 走完 → 「立即重启」→ 新版本号生效。
- D6 静默检查也要置位 phase（`silentPhase(current:json:skipped:)`，2026-10-22 缺陷回归）：新版 → `updateFound`；同版本 / 旧版本 → `idle`；版本在跳过集合里 → `skipped`；跳过的不是这个版本 → 照常 `updateFound`。
- D6b 跳过集合：`skipped: ["1.2.0"]` 时 v1.2.0 → `skipped`；`skipped: ["1.3.0"]` 时 v1.2.0 → `updateFound`（只跳命中的那个，不连坐）。
- D7 状态机闭环：`Phase` 覆盖 `idle / checking / updateFound / downloading / installing / readyToRelaunch / skipped / failed`，`isBusy` 只对 `checking / downloading / installing` 为真；`downloadAndInstall()` 在 `updateFound` 和 `skipped` 下都不被 `isBusy` 挡住（离线断言）。
- D8 2026-10-22 harness `PASS=5 FAIL=0`（A 插值 / B profile / C ButtonAction / D 自动更新决策 / E 构建签名）。
- D9 Asset 的 snake_case 键映射（2026-10-22 真实缺陷回归）：GitHub 发 `browser_download_url` / `content_type`，而 `Asset` 若没有 `CodingKeys`，合成解码按属性名 camelCase 查找，`name` 因为两种拼写相同仍能解出，于是「发现了新版但 `url=nil`」——用户看得到新版却永远下载不到安装包（真机「关于」页表现为「版本源没有提供安装包地址」）。D9 snake_case URL / D9b 仅 MIME / D9c 仅 `.zip` 后缀 / D9d 非归档 asset 忽略。
- D9e `name` 兜底只在它本身是合法版本号时才生效：`{"name":"Smoose 1.5.0"}` 这种 GitHub release 标题 `SemVer` 解析不出来，必须判 `malformed` 而不是瞎猜一个版本号；`{"name":"1.5.0"}` 才走 `.available("1.5.0")`。（2026-10-22：这条断言原本写反了，与真源码行为相反，且一直被下面的 FIFO 假绿掩盖。）
- **D11 harness 段数演进（快照，非当前值）**：2026-10-27 第七轮为 `PASS=11 FAIL=0`（A / B / C / D / E / G / G2 / G3 / F / F2 / H）；随后 G2b（D16，11→12）、G2c（D17，12→13）相继加入。D17 当时是 `PASS=13 FAIL=0`（十三段 A B C D E G G2 G2b G2c G3 F F2 H）；此后持续增加，**当前值为 2026-11-06 的 `PASS=27 FAIL=0`**（含 I 段 14 项）。上面各节的 `PASS=4` / `PASS=5` / `PASS=11` / `PASS=13` / `PASS=26` 都是当日快照，别当成现值。
- **D16 upToDate 必须有可见反馈（2026-10-29，用户实测反馈「检测更新没有成功」）**：检查成功且已是最新时，
  `Updater.check` 必须把 `phase` 置为 `.upToDate(当前版本号)` 而不是 `.idle`，`UpdateStatusView` 必须显示
  「已是最新版本 v<当前版本>」。此前 `.idle` 映射 `EmptyView`，用户点「检查更新」后除时间戳外零反馈，
  把「没有新版」误读成「检查失败」。反 drift：harness G2b 文本守卫（Phase case、置位语句、Views 分支三处都要在）。
  当前 `PASS=12 FAIL=0`（新增 G2b 后 11→12）。
- **D17 限流与弱网韧性（2026-10-29 优化轮）**：三项契约，harness G2c 文本守卫（8 项）守住。
  1. **ETag 条件请求**：检查更新带 `If-None-Match`（ETag 存 `smoose.update.etag`），且**必须**
     `cachePolicy = .reloadIgnoringLocalCacheData` —— 实测默认 cachePolicy 下 URL 缓存把 304 在内部展开成
     200，分支永远进不去。命中 304 时复用 `smoose.update.lastGoodBody` 缓存体走同一 `applyDecision`。
     动机：GitHub API 未认证限流 60 次/h/IP。304 已实测（独立探针 + 真机两轮静默检查）。
  2. **断点续传**：下载失败时保存 `resumeData`（`smoose.update.resumeData`），下次 `downloadTask(withResumeData:)`
     续传；成功后清除。下载超时 `timeoutIntervalForRequest = 120`（此前 60s 在慢网络下截断出 732KB 残包的教训）。
  3. **`pointerRemX/Y` 数据竞争收尾**：`handlePointerMove` 的 rem 累积全程持锁（早退分支先 unlock），
     §7 挂了很久的「轻微竞争」已修。G2c-8 断言「unlock 之后不得再访问 rem」，变异验证可抓回归。
  4. **`profile(for:)` 帧循环缓存**：滚动/帧循环热路径读 `cachedProfile`（120Hz 下每秒几百次字典查找 → 0），
     缓存只在 `apply()`（配置变更）与 `setActiveApp()`（App 切换）两个低频失效点重建。
     G2c-10 断言重建点恰好两处、G2c-11 断言热路径不得直接查字典。
  当前 `PASS=13 FAIL=0`（新增 G2c 后 12→13）。
- **H 安全加固断言（2026-10-27 新增，直接编译真实 `Sources/`）**：10-26 加的安全加固原先一条断言都没有（`run_tests.sh` 还停在 10-23），H 把它们固化成可执行断言，现为 **25 项**——HTTPS 强制 11 项（H1-H11，含 IPv6 回环、`127.0.0.1.evil.com` / `localhost.evil.com` 前缀子域伪装）、默认 Team ID（H12）、sha256 与系统 `shasum` 逐字节对齐（H13）、manifest 三种 sha256 键名与空串/空白处理（H14-H19）、**H20/H21/H22 按拒因 case 断言**（ad-hoc 重签 → `notSigned`；签名后被篡改 → `signatureInvalid`；官方包 → 必须通过，防一律拒绝）、**H23/H24 前置自检**（Mach-O 首字节必须是 `0xCF`/`0xCA`；Mach-O 自身 `Signature=adhoc`）、**H25 teamMismatch**。
  - ⚠️ **H20 单独拿出来仍是弱断言**：文本 Mach-O 与「Mach-O 缺失」两种假包都会返回 `notSigned`，与真 Mach-O 的 ad-hoc 包**拒因完全相同、无从区分**。H20 的效力依赖 H23/H24 守前置，**三者是一组，拆开删等于把假绿放回来**。反向验证：三种假包场景下 H23 全红、H24 红两种。（2026-10-27 第四轮实测，明细见 HANDOFF §6.1c。）
  - 为此 `UpdateInstallError` 从 `private` 放开为 internal，并拆出 `notSigned` / `teamMismatch(actual:expected:)`，与 `signatureInvalid` 三者可辨。
  - **H25 `teamMismatch` 的载体（2026-10-28）**：造不出「有 Team ID 但不是我们的」的包（本机只有一个 Team 的私钥，
    `/Applications` 里也没有第三方签名 App）。解法是利用 `expectedTeamIdentifier` 支持 Info.plist 覆盖 ——
    harness 把同一个测试二进制再包进一个 `.app`，塞 `SmooseUpdateTeamID=FAKETEAM01`，
    于是那份**真实的官方包**（Team=6U2DQJ6Z2N）就会走到 `teamMismatch` 分支。
    第二趟用 `SMOOSE_H_PASS=2` 触发，且必须在开头 `exit` —— 否则它会把依赖默认期望值的 H1–H24 也跑一遍而全红。
    H25PRE 前置自检确认「期望值确实被改掉了」，注入失败即报红（否则这趟会静默退化成什么都不验）。
    已做变异验证：把 `guard team == expected` 放宽后，H25 如预期 FAIL。
- D12 `relaunch()` 退出路径（2026-10-22 第五轮，端到端实测崩溃）：`NSApp` 是 `NSApplication?` 的隐式解包全局，在没有 `NSApplication` 的上下文里是 nil，`NSApp.terminate(nil)` 直接 `Fatal error: Unexpectedly found nil`。契约：必须 `if let app = NSApp { app.terminate(nil) } else { exit(0) }`。真源码由 G3 反 drift 守住（已做变异验证：把 `Self.terminateSelf()` 改回 `NSApp.terminate(nil)`，G3 如预期 FAIL G32/G36）。
- D14 默认版本源真实可用（2026-10-22 第六轮）：仓库已建为 public 并发布 Release，`GET https://api.github.com/repos/cpufreestyle/Smoose/releases/latest` 返回 200，真源码 `UpdateCheck.decide` 解出 `available(1.2.0)` + 下载地址，安装包 HTTP 200 可下载；整条「默认源 → 发现新版 → 下载 → 安装 → 重启」在真机跑通。
- **D15 v1.2.1 发版链路逐段验证（2026-10-27 第八轮）**：`releases/latest` 200 → 真源码 `UpdateCheck.decide(current:"1.2.0")` 解出 `available(1.2.1)`、`decide(current:"1.2.1")` 为 `upToDate` → asset 下载 897507 字节、sha256 `2eb0885d…` 与 `release.sh` 产出端一致 → 解压后顶层即 `Smoose.app`、`codesign --verify --deep --strict` 通过、`TeamIdentifier=6U2DQJ6Z2N` 与 `expectedTeamIdentifier` 对齐、bundle id `app.smoose.macos` 匹配。GitHub 源不给 sha256，客户端跳过该校验（不阻断）。
  - ⚠️ **下载要留足超时**：首次 `curl --max-time 60` 只拿到 732KB（截断），重试 `--max-time 90` 才拿到完整 897507 字节。asset 本身没问题，是网络超时。
- **D18 v1.2.2 发版链路逐段验证（2026-10-31）**：把第六轮优化（ETag / 断点续传 / 事件时间戳 / rem 锁竞争收尾 / `profile(for:)` 帧循环缓存 / Release notes 带 sha256）与 D16 upToDate 反馈一起发给用户。`Resources/Info.plist` 版本抬到 `1.2.2`（`CFBundleVersion` 3→4）→ `./scripts/release.sh --github --repo cpufreestyle/Smoose` 重新签名打包（**必须重跑 release.sh 重建签名，不能用 plutil 改已签名包的版本号，`_CodeSignature` 会不符被拒**）→ Release `v1.2.2` 已发、asset 已上传。逐段复核：`releases/latest` 返回 `tag_name=v1.2.2` + asset `Smoose-1.2.2.zip`（900598 字节）→ 真源码 `UpdateCheck.decide(current:"1.2.1")` 解出 `available(1.2.2)` 且 url 指向该 asset、`decide(current:"1.2.2")` 与 `decide(current:"1.3.0")` 均为 `upToDate`（osStr=27.2.0）→ 下载 asset sha256 `81565ba6…` 与 `release.sh` 产出端逐字节一致 → 解压后顶层即 `Smoose.app`、`codesign --verify --deep --strict` 通过、`TeamIdentifier=6U2DQJ6Z2N` 与 `expectedTeamIdentifier` 对齐、bundle id `app.smoose.macos` 匹配 → 部署到 `/Applications` 后运行版本 1.2.2、二进制 sha256 `e3b0126a…`、辅助功能授权 `auth_value=2` 保留、启动无崩溃。Release notes 由 release.sh 自动带上 `安装包 sha256`，手动下载可自行核对。
- **D19 窗口自适应布局契约（2026-10-31，1.3.0）**：设置窗口必须可拖拽调整大小（1.2.3 修：根视图固定 frame → `minWidth/minHeight`），
  且**放大后内容必须跟随拉伸**。两个断层都会让用户觉得「界面坏了」：
  ① `SettingsWindow` 根视图 `.frame(width:560,height:520)` —— 固定尺寸变成 `NSHostingView` 的锁死约束，窗口边缘拖不动；
  ② tab 内容里散布的 `.frame(width:380)` 等固定宽度 —— 窗口能拖大但内容钉在 380px，右侧大片空白。
  契约：**窗口根用 `minWidth/minHeight` 下限约束；内容块用 `maxWidth:` 上限弹性宽度（关于页 420、版本源输入框 340、菜单栏面板 minWidth 330），
-  不得再用固定 `width:` 钉死可拉伸区域**。反 drift 由 code review 把关（文本守卫对 SwiftUI 修饰符误报率高，未入 harness）。
- **D20 自动更新端到端闭环（2026-10-31，补齐 §7 长期未决项）**：此前只做过逐段验证，
  「下载 → 替换 /Applications/Smoose.app → relaunch」这条最危险的路径从未真跑。本次实测：
  `/Applications/Smoose.app` 先降到 1.2.1 隔离副本（`Smoose-1.2.1-predeploy.app`，签名有效、Team ID 一致），
  再以无界面驱动直接调用真实 `Updater.check(interactive:)` + `downloadAndInstall()` 走默认 GitHub 版本源：
  `updateFound(1.3.0)` → `downloading 0→100%` → `installing` → `readyToRelaunch(1.3.0)`。
  落盘复核：`CFBundleShortVersionString=1.3.0`、`codesign --verify --deep --strict` 通过、
  `TeamIdentifier=6U2DQJ6Z2N`、Mach-O sha256 `d1056d36…43d5` 与 v1.3.0 Release notes 声明一致。
  **契约**：`replaceApp` 注入 `target` 参数以便离线断言；失败时必须把旧版搬回原位（不留「App 被删了却装不上」）。
  **断言**：H26 正常替换换成新版、H27 新包签名无效必须回滚成旧版、H28 新包缺失也必须回滚。
  H26 的新包必须用**真证书签名**的包（用 `/Applications/Smoose.app` 充当），否则会先被 `verifySignature`
  拒掉而测不到替换路径 —— 这是本轮踩到的第一个假绿诱因。
  H29–H30 断言 `signingAuthority` 对官方包有效提取证书 subject.CN、对 ad-hoc 包返回 nil，
  并在身份发生变化时触发界面重新授权提示（P2 已修）。
- D13 端到端闭环（2026-10-22 第五轮，真机实测）：本地 HTTP 版本源 + 真实签名的 1.2.0 安装包，跑通「检查 → 增量进度下载（0→100%，13 帧）→ 解压 → bundle id 校验 → 替换 /Applications/Smoose.app → relaunch → 新进程以 1.2.0 运行」。版本比较回归：当前 1.2.0/1.2.1/1.3.0 对 feed 1.2.0 均 `upToDate`，1.1.0 → `available`。
- D10 版本源 HTTP 错误话术（2026-10-22 新增）：默认版本源指向一个还没创建的 GitHub 仓库，404 是必然结果，只显示「HTTP 404」用户完全不知道该干什么。断言默认 404 文案含「还没有发布记录」并指向「关于」页、自建源 404 不含默认文案、403 / 401 / 500 各自可操作。真实源码由 G2 反 drift 守住。
- F 发布产出端（2026-10-22 补）：A-E 只覆盖消费端（Updater 的版本比较 / 下载 / 安装），产出端此前完全靠人工点一遍。F 跑 `./scripts/release.sh` 后**独立复核**三条 Updater 硬要求 —— zip 顶层必须是 `Smoose.app`、`CFBundleIdentifier` 必须是 `app.smoose.macos`、解出来的 App 签名必须有效。刻意不信 release.sh 自己的自检：自检被删掉或改松时，F 仍然会发现。已做变异验证：把 `Resources/Info.plist` 的 bundle id 改成 `app.smoose.WRONG`，F 如预期 FAIL（`bundle id 是 app.smoose.WRONG 而不是 app.smoose.macos`），改回后恢复 PASS。
- G 真实 `Sources/UpdateModel.swift` 反 drift（2026-10-22 新增）：D stage 用的是 `run_tests.sh` 里逐字抄的逻辑副本，副本会和真源码漂移 —— 上一轮就出现「副本有 `CodingKeys`、真源码没有」，于是 harness 全绿而真机是坏的。G 直接编译真源码，用真实形状 JSON 断言（G1-G10）。已做变异验证：删掉真源码的 `Asset.CodingKeys` → G 如预期 FAIL（G1/G2/G3），而 D 仍绿（证明副本确实在掩盖问题），改回后恢复全绿。
- G2 `Updater.httpMessage` 反 drift（2026-10-22 新增）：`Updater.swift` 依赖 AppKit + `Preferences` + `UpdateManifest`，编不出可执行断言，所以 D10 只能是逻辑副本。G2 用文本守卫确认真源码里真的存在 `httpMessage` 且按错误码分支，防止副本更新了、真源码没更新。
- **假绿守卫（2026-10-22 必修）**：harness 的 D stage 早前用 `[ ! -s <(grep '^FAIL' out) ]` 判断断言结果，而进程替换出来的是 FIFO，zsh 的 `-s` 在写端 flush 之前就完成判断，永远返回「空」——于是断言全 FAIL 也照样 PASS。已改成把 grep 结果收进变量再判断，并让 D 二进制自己 `exit(1)`。同时 `require()` 的默认 label 用 file/line 魔法标识符，而默认参数在声明处求值，永远解析成 `require` 函数自己那一行，报错时看不出是哪条挂了；已给全部断言补上可读 label。

### 刻意不做 Sparkle 的理由

项目是 `swiftc` 单命令编译 + Apple Development 证书签名（非 notarized），没有 appcast feed、没有 EdDSA 发布密钥，也没有 git remote / GitHub 仓库。引入 Sparkle 只会得到一个「永远验证不过」的更新器，还要背一个第三方依赖。自建方案零依赖、100 行可审计逻辑，且版本源格式可以随时换。

### 实现

- `Sources/UpdateModel.swift`：`SemVer`（Comparable）、`UpdateManifest`（双形状 Decodable）、`UpdateCheck.decide(current:osVersion:data:)` 纯函数。
- `Sources/Updater.swift`：`Updater.shared`（`@Published phase`），`checkIfNeeded()` / `check(interactive:)` / `downloadAndInstall()` / `relaunch()`。
- `Model.swift`：`StoredState` / `Preferences` 新增 `autoCheckUpdates`（默认 true，`decodeIfPresent ?? true` 兼容旧配置）。
- `Views.swift`：`AboutTab` 版本号改为读 `Updater.currentVersion`（此前硬编码 `v1.0.0`，升级后「关于」页显示的是假版本）；新增「跳过此版本」按钮；`UpdateStatusView` 补 `skipped` case；`MenuBarPanel` 顶部加新版本横幅（静默检查的出口）。
- `App.swift`：`AppDelegate.startUpdateChecker()` 挂 24h Timer + 启动 5 秒延迟首查；`applicationWillTerminate` 里 invalidate。
- `Sources/Updater.swift`：`static func httpMessage(code:url:)` 把 HTTP 错误码翻成可操作中文话术，按「是否默认源」分流；`private static func terminateSelf()` 安全退出自己（`NSApp` 可选链 + `exit(0)` 兜底）。

## 22. 加速键配置与每应用建议档修复（2026-11-01）

用户实测反馈两条「配置了却静默失效」，根因都不在引擎而在配置层的整体替换语义：

- **D21 套预设清掉加速键**：`Views.swift` 的预设按钮写 `prefs.global = ScrollProfile.presets[name]`，
  把整个 profile 换掉。用户在「按住加速」里配好的 ⌘ + 4× 随 `boostModifiers` 一起被清回 0，
  加速功能静默失效，界面没有任何提示——用户以为是自己没按对键。
  修法：`ScrollProfile.preset(named:preservingBoostFrom:)` 只复制 boostModifiers / boostFactor，
  其余走预设值。`ScrollBoost.scale()` 的判定逻辑本身没错（S1-S8 已覆盖），错的是配置被清空。
- **D22 新建每应用规则一律「沿用全局」**：用户 2026-10-31 反馈「微信里面滚轮速度过快」，
  而 Spec 早就有「聊天软件」预设（speed 0.8），只是新建规则时从不自动套用。
  修法：`ScrollProfile.chatBundleIDs` 白名单 + `suggested(forBundleID:)`，
  命中（微信 / QQ / Slack / Discord / Teams）直接套「聊天软件」预设，未命中返回 nil 回落全局。
- **D23 滑条上限与引擎上限不同源**：`ScrollBoost.maxScale = 10.0` 而 UI 滑条写死 `1.2...6`。
  两个后果：拖到底也只到 6×；手改 JSON 到 8× 时界面显示 6.0 实际跑 8.0（读写不一致）。
  修法：滑条上限改为 `ScrollBoost.maxScale`，两边同源。

**断言**：S18-S24 编译真 `Sources/Model.swift`（给 `Preferences` 依赖的 `ScrollEngine` /
`PointerController` 两个单例补空实现 stub，不碰持久化），S25-S27 文本守卫 Views ↔ maxScale。
已做变异验证：把 `preset(named:)` 的 boost 保留两行删掉、白名单去掉微信、
滑条改回 `1.2...6`，分别如预期报 FAIL（S18a/S18b/S19b/S21、S25a/S25b），恢复后全绿。

## 23. 轮询改事件驱动（2026-11-01）

两处定时器原本是「每 N 秒全量重跑一遍」，但设备列表在会话内几乎不变，
绝大多数调用都是白跑一次 IOKit 枚举 + 主线程 apply。G502 X 常插在机器上时尤其明显。

- **D24 罗技 HID++ 插拔检测**：`LogitechHIDPP` 原来是 5 秒 `scan()` 全量轮询，
  持续 IOKit 开销之外还有个体验问题——插上鼠标最多要等 5 秒界面才反映，看着像「没检测到」。
  改为 `IOHIDManagerRegisterDeviceMatchingCallback` / `RegisterDeviceRemovalCallback` 事件驱动，
  用 `Unmanaged.passRetained(self).toOpaque()` 把 self 传进回调。
  不挂 run loop：回调本就跑在自己的队列上，`scan()` 内部已 `DispatchQueue.main.async`。
- **D25 指针配置生效延迟**：`PointerController` 原来是 6 秒 `refresh(force: false)`。
  这个轮询唯一真正有用的场景是「用户刚改完配置」，却要等最多 6 秒才套用。
  改为：`Preferences.persist()` 里比对指针配置签名（`pointerAccelManaged|accelerationValue|includeBuiltIn`），
  真的变了才发 `.smoosePointerConfigChanged`，PointerController 收到立刻 refresh。
  签名判空是必须的：不判空的话每次 persist（哪怕改的是滚动参数）都重发通知，等于又变回轮询。
  **2026-11-06 契约反转（D30）**：当时把兜底拉长到 60 秒，是因为每轮都全量枚举 IOKit；
  但那让「系统把 HID 加速度重置回默认」完全无法自愈（详见 HANDOFF §4.5）。现在枚举交给
  `IOHIDManager` 插拔回调，轮询只调 `apply(force:false)` 读属性，因此周期收紧到 **8 秒**。
- **D26 加速键与透传键配同一个键时无提示**：引擎里 bypass 先判、boost 后判，
  同键时透传赢，加速永远不触发——这是确定行为不是 bug，但界面两处各配各的，
  用户配完不知道自己白配了。新增 `ScrollBoost.conflicts(bypass:boost:)` 纯函数，
  「按住加速」段里检测到重叠时把说明文字换成橙色警告 Label。空掩码不算冲突（两边都没配是正常状态）。

**断言**：S28 编译真 `Sources/ScrollAxis.swift` 验冲突判定（含「都没配」「只配一边」「不同键」都不提示）；
S29 文本守卫 Views 真的接了 `ScrollBoost.conflicts`；
S30 文本守卫罗技侧无 `scheduledTimer(5.0)` / 无 `pollTimer` / 两个回调都注册 / `passRetained` 与
`takeUnretainedValue` 配平；S31 文本守卫通知真的发（不是只定义）、签名判空在、
**轮询周期 ≤ 10 秒**（S31g，原为 ≥30 秒，2026-11-06 反转）、轮询里是 `apply(force:false)`
而不是全量枚举（S31h）、两个 IOHIDManager 回调都注册（S31i/j）、读数进签名（S31k）。
变异验证：`conflicts` 恒返 false → S28e/S28f 红；删 removal 回调 → S30b 红；
删 persist 里的发通知块 → S31b/S31e 红；兜底改回 6.0 → S31g 红（旧语义）。

**I 段（2026-11-06，14 项，编译真 `PointerController.swift`）**：核心是 I2 —— 设备当前读数
从 `0` 变成 `163840`、而配置与 registryID 都不变时，签名**必须改变**。I1/I10/I12/I13 反向保证
签名幂等、设备顺序无关、亚 1 计数抖动不误判、期望签名与全符合读数相等（否则每 8 秒白写）。
变异验证：把读数从 `PointerAccelSignature.make` 里移除（等价旧实现）→ **I2/I3/I4/I11b/I14 五条报红**。
真机端到端：人为把接口改回 2.5 后 6 秒自动纠回 0；退出 App 的负例 12 秒保持 2.5，
排除「系统自己改回 0」这个替代解释。I 段验的是决策输入（签名），不是端到端 IOKit 写入。

## 24. 更新流程的菜单栏出口（2026-11-01，真机端到端验证）

用户从菜单栏点「下载并安装」，装完却没有任何反馈：`readyToRelaunch` 只在「关于」页有
「立即重启」按钮，菜单栏面板完全不显示下载 / 安装 / 待重启三个状态。更糟的是
`dismiss()` 会把 `readyToRelaunch` 打回 `.idle`——新版本已经替换到 `/Applications`，
收起横幅等于把唯一的重启入口弄丢，用户只能手动重启 App（甚至不知道有新版在等他）。

- **D27 菜单栏补齐更新全流程**：`MenuBarPanel` 新增 `downloading`（进度条 + 百分比）、
  `installing`（"正在安装，请勿退出 Smoose…"）、`readyToRelaunch`（"已就绪，重启后生效" +
  签名证书变更警告 + 「立即重启」/「去设置页」）三个分支。与「关于」页出口并存，不互相替代。
- **D28 `dismiss()` 不得收起已安装的更新**：`readyToRelaunch` 时 dismiss 是 no-op。
  这个状态要么重启、要么一直挂在菜单栏当提醒；因此菜单栏那个分支**不提供**「稍后再说」按钮
  （提供了也关不掉，反而误导）。
- **D29 `dismiss()` 的 busy 守卫保留**：下载 / 安装中仍要挡住误触。

**断言**：S32 编译真 `Sources/Updater.swift`，剥注释后在 `dismiss()` 函数体内比较
（全文搜 `phase = .idle` 会先命中 `cancel()` 那一处，第一版断言就这么误报过）；
S33 文本守卫 MenuBarPanel 覆盖三个状态且**剥注释后**不含「稍后再说」
（解释「为什么不提供」的注释里本身就含这四个字，不剥永远红）；
S34 文本守卫「关于」页原有出口没被挤掉。
变异验证：删守卫 → S32a/c 红；守卫挪到 `phase = .idle` 之后 → S32c 红；
把「稍后再说」按钮加回去 → S33h 红。

**真机端到端（2026-11-01，不是离线断言）**：把 `/Applications/Smoose.app` 降到 1.4.0，
用编译进去的真实 `Updater` 驱动完整链路，phase 序列实测：
`checking → updateFound(1.4.1) → downloading(0%…98%) → installing → readyToRelaunch(1.4.1)`；
同一进程内 `dismiss()` 前后 phase 均为 `readyToRelaunch(1.4.1)`（no-op 实测成立）。
链路跑完后 `/Applications/Smoose.app` 已被自动更新自己替换成 1.4.1（`CFBundleVersion` 8、
`codesign --verify --deep --strict` 通过、`TeamIdentifier=6U2DQJ6Z2N`、Mach-O sha256
`3458df6d…bd7a01f` 与发版产物一致），辅助功能授权 `auth_value=2` 保留。

## 25. 鼠标游戏性能检测（2026-11-02）

「游戏」tab：不新开 tap、不加轮询，全部采集挂在已有的两个回调上（ScrollEngine 的 CGEvent tap
拦 mouseMoved / otherMouseDown/Up，CVDisplayLink 本来就在跑），所以对 Smoose 自身零额外系统开销。
指标分四组：设备参数（IORegistry 实读）、实时指标（2 秒滚动窗口）、就绪度评级、建议。
评级与建议是纯函数 `GameGrade`，UI 与 harness 共用同一份阈值，不会出现「界面显示良好、
harness 按另一套数字判」的漂移。

**测不到的不做**：实际传感器 DPI 存在鼠标内部配置文件里，IORegistry / `hidutil` 读不到；
本页只显示能实读的回报率（ReportInterval）与 `HIDPointerResolution` 常量，不拿假 DPI 糊弄。

> ⚠️ **2026-11-06 修正**：原文写「HID++ 2.0 的 DPI 回读实测全是 0，所以 macOS 读不到」，
> 该结论**已被推翻**。当时用的是错误报文（把 `0x22` 当 feature index、function 写成 `0x03`）。
> 改为先 `getFeature(0x2201)` 拿 index、再读 `0x18`/`0x28` 后，本机实读到
> 100–25600 DPI / 步长 50 / 当前 5400 / 默认 1600。传感器 DPI 现在显示在「指针」页
> 的罗技专属区（§29）；本页说明同步改为「不在 IORegistry 里，改由 HID++ 实读」。

### 25.1 启动即崩：`1..<0` 运行时陷阱

1.4.2 首次带这个功能上线，`open -a` 后进程立即退出、无任何输出，用户看到的就是
「点桌面图标完全没反应」。崩溃报告 `EXC_BREAKPOINT / SIGTRAP`，backtrace 指向
`GamePerfProbe.recompute()`：

```swift
for i in 1..<ptrTs.count          // ← ptrTs.count == 0 时构成 1..<0
```

Swift 的 `..<` 带前置断言 `lowerBound <= upperBound`，count 为 0 时直接陷阱。
**触发条件就是默认状态**：启动后第一次 1 Hz tick 时用户还没动鼠标，指针环是空的。
`latencyRing` / `frameRing` 那两处同样的循环同理（reset 后也会中）。

修法：抽成 `GamePerfProbe.intervals(of:)`，对空数组 / 单元素数组短路，返回值已升序
（`PerfStats.percentile` 要求输入有序）。**凡是「相邻元素差」的循环，空数组必须单独短路**，
不能指望 `1..<count` 自己兜住。

### 25.2 `CGEvent.timestamp` 时基不统一（交接文档那条是错的）

修完崩溃后预览，发现三个指标同时不对：指针延迟恒显示 0、事件率被算成 19 Hz
（实际 744 Hz）、2 秒窗口过滤整体失效（多久以前的事件都算「在窗口内」）。
用临时诊断把环里的原始值打出来才定位：

```
now = 10502111232800          ← mach_absolute_time()，tick
ptrOldest = 437583588201750   ← CGEvent.timestamp
比值 = 41.6662 ≈ timebase 125/3
```

**`CGEvent.timestamp` 的时基不统一，HID 事件和注入事件不是一套**：

| 来源 | 时基 | 实测 |
|---|---|---|
| 真实鼠标等 HID 设备事件 | mach tick | 回调内与 `mach_absolute_time()` 比值 1.0000，差 0.13~5.09 ms |
| 经 `CGEvent.post(tap: .cghidEventTap)` 注入的事件 | **开机以来纳秒数** | 同刻 tick ≈ 1.05e13、纳秒 ≈ 4.38e14；按 `uptime` 5 天 1.6 小时反查完全吻合 |

不归一化的后果：纳秒值永远大于 `now` → `MachClock.diff` 恒返回 0 → 窗口过滤全部放行、
事件率被算小约 41.67 倍、指针延迟恒为 0。**三个症状是同一个根因**，
单独修任何一个都只是把假数据换个样子。

修法：`MachClock.normalize(_:now:)`，进来的一切时间戳都过它。判据用 `ts > now &* 8`
（纳秒比 tick 大一个数量级以上；timebase 最小 1/1 时两者同值，判据不可能误触）。

> 旧交接文档写的「`CGEvent.timestamp` 与 `mach_absolute_time()` 同时基，可直接相减算延迟」
> **只对 HID 事件成立**。那条是用真实鼠标量出来的，换成注入事件就错。别据此跳过归一化。

### 25.3 只认 IORegistry 的 ReportInterval

`IOHIDServiceClientCopyProperty` 对 `ReportInterval` / `HIDReportInterval` /
`HIDPointerResolution` 全部返回 nil，必须按 registryID 走
`IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(rid))`
（和 `PointerController.currentResolution` 同一条路）。
实测：G502 X 接收器 1000 µs = 1000 Hz，内置触控板 8000 µs = 125 Hz。
`HIDPointerResolution` 两个设备都是 26214400（400 DPI 常量），不是真实传感器 DPI。

### 25.4 断言与变异验证

H31–H41 编译真 `Sources/GamePerf.swift` + `Sources/Model.swift` 断言：
分位数（空/单元素/端点/插值/越界夹紧）、事件环（容量下限/计数/环绕顺序/未环绕顺序/reset）、
回报率换算（1000 µs→1000 Hz、8000 µs→125 Hz、0→「读不到」）、评级阈值五项边界、
定级 0/1/2/3+ 项失败、建议全部分支、就绪度 rawValue+symbol 非空、
`intervals(of:)` 空数组短路、**空数据 `recompute()` 必须跑完**、时基归一化、
`SettingsTab.fromURL`。S35 文本守卫游戏页 tag / URL 直达 / 采样中 / 重置。

变异验证 12 条，全部报红：删空数组守卫 → H 段二进制 SIGTRAP(rc=133)；
percentile 空数组返回 -1 → H31a；`start = next` → H32l2；Hz 换算错 → H33a/b/c；
阈值 500→100 → H34c；定级 1 项失败→竞技级 → H35d；采样建议返回空 → H36a/H39d；
symbol 置空 → H37b；`fromURL` 返回 nil → H40b/d/e；tag 4→5 → S35c；
去掉 URL 接线 → S35e；`normalize` 改恒等 → H41d/e/g/i。

两条变异**没有**报红，都是变异本身写错了（语义等价），但其中一条暴露了真实盲区：
`(next - n + capacity) % capacity` 改成 `next` 在全环绕用例下结果相同，
因为那时 `next == n`。补了 H32l「未环绕（total < capacity）快照必须按写入顺序」后才抓住。
**变异没报红时，先怀疑变异是等价的，别直接断言「断言有牙」。**

### 25.5 harness 假绿：编译产物崩溃也算通过

变异验证时发现：删掉空数组守卫后 harness 依然全绿。原因是 H/D 段只
`grep '^FAIL'`，而 Swift 运行时陷阱打的是 `Fatal error: ...`（不以 FAIL 开头），
二进制中途死掉时 `HFAILS` 为空 → 照常 `ok`。已修：两趟 H 和 D 都必须
凡是「跑编译产物 + 解析输出」的断言都要防这一手，不能只 grep 失败行。

## 26. 参照 Mos / LinearMouse 优化：合成事件相位 + 点击刹车（2026-11-03）

本轮对照两份开源实现找差距：`caldis/Mos`（Swift 重写后的 `Mos/ScrollCore/`：
`ScrollCore` / `ScrollPoster` / `ScrollPhase` / `ScrollFilter` / `ScrollEvent`）与
`linearmouse/linearmouse`（`EventTransformer/SmoothedScrollingEngine`，速度式模型）。
Smoose 的位置式指数插值（`ScrollAxis`）+ 亚像素累积本身不输它们，真正拉开差距的是
**合成事件长什么样**和**手势怎么收尾**。

### 26.1 根因：消费端在二次加工我们的曲线

Smoose 早期 `post()` 写出的事件是 `isContinuous=0`、`scrollPhase=0`、`momentumPhase=0` 的
像素增量。在 Chrome / Safari / 原生 `NSScrollView` 看来这就是「物理鼠标滚轮 + 像素增量」，
于是它们套用自己的滚轮逻辑（行量化、自己的动量与手势状态机），Smoose 调好的曲线被第二遍加工 ——
这就是用户觉得「同样的曲线，Mos 里更跟手」的根因。

Mos 的做法（`ScrollPoster.post`）：合成事件一律 `isContinuous=1`，并按当前手势写
`scrollWheelEventScrollPhase` / `scrollWheelEventMomentumPhase`，消费端就走
「触控板像素滚动」路径，只认我们给出的像素量。LinearMouse 也走同一条路。

### 26.2 相位值表（移植 Mos `PhaseValueMapping`）

| 手势段 | scroll（field 99） | momentum（field 123） | 发出时机 |
| --- | --- | --- | --- |
| trackingBegan | 1 | 0 | 手势首帧增量 |
| trackingChanged | 2 | 0 | 手指段持续增量 |
| trackingEnded | 4 | 0 | 手指段到位后的零增量收尾 |
| momentumBegan | 0 | 1 | 输入停下后尾巴首帧 |
| momentumChanged | 0 | 2 | 尾巴持续 |
| momentumEnded | 0 | 3 | 尾巴走完 / 被打断时的零增量收尾 |

`ScrollPhaseFields.write(simulateTrackpad:phase:)` 是唯一写字段的地方，返回
`SyntheticScrollFields(cont, scroll, momentum)`。**关闭开关时三者必须全 0** ——
这是「关掉 = 与老版本逐字节一致」的契约（S36g/S36g2 断言）。

> **真机实测（2026-11-03 字段探针）**：`CGEvent(scrollWheelEvent2Source:units: .pixel, …)`
> 造出来的新事件 **`isContinuous` 默认就是 1**，`scrollPhase` / `momentumPhase` 默认是 0。
> 也就是说 1.4.2 里 `setIntegerValueField(F.cont, value: 0)` 那一行是**有意义**的 ——
> 不写它，合成事件本来就带着 `isContinuous=1`。本轮把这一行换成按开关写 1/0，
> 并实测四个字段（88 / 99 / 123 / 42）与 `pointDeltaAxis1` 在新事件上都能写进去、读得回。

### 26.3 状态机与两个阈值（对齐 Mos）

`ScrollPhaseTracker`（`Sources/ScrollPhases.swift`，纯结构体）：

```
idle ─输入→ tracking ─输入间隔>0.18s→ momentum ─轴到位→ idle
                 ↑___________________________________|
                       尾巴未走完又滚：先补一帧 MomentumEnd
```

- `continuationThreshold = 0.18`（Mos `manualContinuationThreshold`）：输入间隔 ≤ 它算
  「手指还在滚」；超过则本帧起算惯性段。
- `separationThreshold = 0.45`（Mos `manualSeparationThreshold`）：距上次输入 ≥ 它算一次
  新的独立手势，重新发 Began。
- `begun` 只在**真的投递了帧**时置位。亚像素累积的帧没有增量，若提前置位，
  手势的第一帧就会从 Changed 开始，消费端的手势状态机少一次 Began。

### 26.4 帧序：interrupt → body → end

`ScrollEngine.frame()` 每帧向 tracker 要一个 `Plan`，按固定顺序投递：
先 `interrupt`（重新接管惯性时补的零增量 MomentumEnd），再 `body`（本帧增量，带相位），
最后 `end`（轴到位后的零增量收尾）。收尾帧不是可选项：不收尾时部分 App（Chrome）会拖着
自己的 momentum 不放，表现为「明明停了你还能看到页面在飘」。

**时基坑**：tracker 的两个入口必须同时基。`noteInput` 在 tap 回调、`advance` 在
CVDisplayLink 回调，两者都用 `CACurrentMediaTime()`。CVDisplayLink 的 `videoTime`
是另一套时基，混用会让 `continuationThreshold` 永久失效（要么永远 momentum，要么永远 tracking）。

### 26.5 点击刹车

移植 Mos `mouseLeftEventCallBack → ScrollPoster.stop`：左键按下立刻收掉尾巴，
`ScrollAxis.brake()` 把 `target` 拍回 `current`（剩余距离作废，对应 Mos 的 `buffer = current`），
再补一帧零增量 `trackingEnded`。
用 `NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown)` 而不是再开一个
listen-only CGEventTap：全局监听只读不拦，碰不到主 tap 的事件流，也不需要新线程。
代价是点 Smoose 自己窗口时收不到 —— 那种场景没有滚动尾巴要收，无影响。

### 26.6 Launchpad / Dock 透传

移植 Mos `ScrollUtils.getLaunchpadActivity`：10.15–26 上 Launchpad 寄宿在 Dock 进程里，
前台 bundle id 就是 `com.apple.dock`。Mos 原注释：平滑后的滚动事件在 Launchpad 里无法被识别，
必须原样放行，否则「打开 Launchpad 用滚轮翻页没反应」。Smoose 原来只在**指针**路径放行
Dock / Finder，滚轮路径没有。本轮在 `handleWheel` 补上 `activeAppID == "com.apple.dock"` 透传。

### 26.7 开关契约

`ScrollProfile.simulateTrackpad`（默认 **true**，per-app 可覆盖，旧配置缺键兜底 true）：
- 界面：「滚动」页新增「输出方式」段；每应用规则的「细节参数」里同样有。
- 套用预设时保留该开关（和 boost 同一个理由：它是输出方式、不是曲线参数）。
- 关掉后 `post()` 写 `cont=0 / phase=0 / momentum=0`，与 1.4.2 逐字节一致。
- `apply()` 会 `phaseTracker.reset()`：中途切换开关不会从半截手势状态开始。

### 26.8 断言与变异验证

S36–S38 编译真 `Sources/ScrollPhases.swift` + `Sources/ScrollAxis.swift`：
相位常量六项、字段写入（关闭/无相位/开启/惯性收尾）、状态机（首帧 Began / Changed /
转动量 / 收尾 / 亚像素不吃 Began / 打断补 MomentumEnd / 隔太久重新 Began / 手指段收尾 /
reset）、刹车（空轴无害 / 丢弃剩余距离 / 停在本帧位置 / 之后不再投递）。
S39 十三条文本守卫（先剥注释）：`post()` 写三个字段、帧循环推进 tracker、输入通知 tracker、
`brake()` 接两轴、Dock 透传、App 装左键监听、全局与每应用开关接线、旧配置兜底。

变异验证 8 条全部报红：`continuationThreshold 0.18→9.99`（S37g/h/i/o）、
`trackingEnded scroll 4→0`（S36c）、brake 去掉 `target=current`（S38d/e/f）、
`write` 忽略开关（S36g/g2）、去掉 `pendingInterrupt`（S37o）、`begun` 不依赖 posting
（S37j/m/n）、收尾帧相位用错（S37i）、`settled` 恒 false（S37i/k/t）。

### 26.9 三条没做的（记下来免得下轮重复调研）

- **LinearMouse 的速率投影**（`WheelInputVelocityEstimator`，快甩时每格滚轮走更远）：
  会改变距离语义，与「微信等 App 已经调低倍率」的现有策略冲突，本轮不做。
- **LinearMouse 的速度式模型 + 惯性**（velocity / momentumDecay / reengagementBlend）：
  Smoose 的位置式插值已有等价尾巴，换模型等于把 1.4.0 以来调的所有曲线参数全部作废，不做。
- **Mos 的 `CGEventPostToPid` 直投目标进程**：Mos 用它消除崩溃与「动量不跟随光标」，
  但 Smoose 的 `.cghidEventTap` 投递 + 回声守卫已经稳定跑了 20 多轮，不赌。

## 27. 设置窗口放大后内容等比联动（2026-11-06）

**现象**：用户反馈「页面放大以后，它的内容没放大」——设置窗口拉大后，内容仍按原始点数居中，四周留白。

**契约**

- `SettingsLayout.baseWidth = 560`、`baseHeight = 620`、`maxScale = 2.0`。
- `uiScale(w, h) = min(2, max(1, min(w/560, h/620)))`：取宽高两个方向**较小**的比例，保证放大后不裁切；小于基准钳到 1；0 / 负尺寸返回 1。
- `logicalSize(w, h) = (w/s, h/s)`：先按逻辑尺寸布局、再 `scaleEffect(s)`，视觉尺寸恰好等于窗口尺寸，既铺满又不溢出。
- `debugWindowSize(from:)`：解析 `smoose://settings?w=…&h=…`，只接受 300…4000 的整数/小数点数；缺参、非数字、越界一律返回 nil。
- `ScaledTabContent` 只包**每个标签页的内容**，`TabView` 必须是根视图。把整个 TabView 包进 `GeometryReader + scaleEffect` 会让 macOS 的系统标签栏被裁掉（真机验证）。
- 顶部 `tabBarInset = 44` 放在 `scaleEffect` 之后，是固定实际点数、不参与缩放；计算 s 前先从可用高度扣掉它。
- `baseHeight` 必须是 620 而不是窗口最初的 520：按 520 排版「关于」页会把说明压成单行并裁掉页脚（完整内容约 617pt）。
- `NSWindow` 初始 contentRect 与 `minSize` 都取自 `SettingsLayout`，不得再写死数字。

**断言**

- `J`（23 项，编译真 `Views.swift`）：基准不放大、2× 放大、大窗口约 1.62×、只变一个方向取 min、2× 封顶、小于基准钳 1、0/负防御、`logicalSize × s == 窗口尺寸`（7 组尺寸）、逻辑宽度不窄于基准、逻辑高度回到基准、诊断入口 7 项。
- `J_W`（文本接线守卫，先剥注释）：六个页全部出现 `ScaledTabContent {`、`.tag(0)…tag(5)` 齐全、`TabView(selection: $nav.selectedTab)` 仍是根视图。
- `J_MUT`（变异验证）：把 `uiScale` 的 return 换成 `return 1 // MUTANT`，J2/J3/J4/J14/J15 必须逐条报红；变异注入本身失败也要报红，不能静默跳过。
- `S35c` 守卫同步改为校验「缩放容器 + 游戏页标签 + tag(4)」绑在同一行，不是放宽成只查关键词。

**真机验证**：1080×900 窗口截图确认标签栏六个标签完整、图标不压标签文字、顶部说明恢复两行、页脚「开源致敬」可见、内容明显放大且文字清晰、无裁切。harness `PASS=30 FAIL=0`。

**取舍 / 未做**

- 只拉宽不拉高时 s=1，内容横向铺开但字号不变：按宽度放大必然裁掉纵向内容，宁可留白。
- 「关于」页 420pt 内容块仍居中固定宽，放大后左右仍有留白（比例从 ~61% 降到 ~25%）；未改成流式全宽，避免长说明一行到底、反而更难读。
- 未做用户可选的缩放档位（100% / 125% / 150%）：自动跟随窗口已覆盖反馈场景，需要时再加。

## 28. 指针线性模式契约（2026-11-06，二次纠正根因）

**背景**：用户第三次反馈「静止后起步发黏没修好」。静置 70 秒每 2 秒采样，两个鼠标接口的
`HIDMouseAcceleration` 恒为 **0**；把全部 HID 服务也写成 0 后用户**仍然发黏**。
因此 §4.5 记录的「系统把值重置回 163840、8 秒轮询补回」不是根因（作为防御兜底保留）。
真因是 **0 只代表「最小加速度」，不是关闭加速**：系统仍走低速增益 <1 的加速曲线，
用户说的「慢慢恢复正常」是同一次移动内速度上升，不是等待轮询。

**核对依据**：LinearMouse `PointerDevice.pointerAcceleration` 注释
`-1 means acceleration and sensitivity are disabled`；`setPointerAcceleration(-1)` 写
`IOFixed(-65536)`；Sonoma+ 另有 `HIDUseLinearScalingMouseAcceleration`，
`Device.supportsLinearPointerScaling` 在设备读不到该属性时回退到只写 -1。

**契约**

- `PointerAccelPolicy.plan(0)` → `(ioFixed: -65536, linear: 1)`；`plan(2.5)` → `(163840, 0)`；
  `isLinear(value <= 0.0001)`。
- `apply()` 必须**双写** `HIDUseLinearScalingMouseAcceleration` 与 `accelKey`，写后读回两者；
  `PointerAccelSnapshot.linear` 参与 `PointerAccelSignature.make`（设备重枚举丢标志要能发现）。
- 设备不支持线性键（写入前后均为 nil）→ `linearOutcome` 判定为回退，`ok=true`、
  `settled=nil`；**不得**报红，也不得把失败态固化成短路。支持但写入失败 → `ok=false` 并存实际回读值重试。
- 「恢复系统默认」的基线来自 `IOHIDSystem.HIDParameters["HIDMouseAcceleration"]`
  （`IORegistryEntryFromPath("IOService:/IOResources/IOHIDSystem")`，本机 163840 = UI 2.5），
  禁止用「App 启动时的设备读数」（那可能已是自己写过的 0 / -1）。`restoreDefaults()` 同时还原线性标志。

**断言**

- K 段 20 项：取值语义、签名含线性读数且顺序无关、回退/重试分支。
- `K_W` 9 条接线守卫：`plan` 调用、双写、读回、`outcome.ok`、签名、restore、`systemDefaultAcceleration` 路径。
- `K_MUT`：plan 换回「恒写 0」→ K1/K2/K6 报红；`K_MUT2`：把硬件不支持误判为失败 → K16/K19 报红；
  两趟都要求「变异注入失败本身报红」的前置自检。

**真机验证**：两个 USB Receiver 回读 `-65536`、线性键 `(null)`（回退路径）；状态区灰色无
「写入未生效」；静置 32 秒参数保持；`codesign --verify --deep --strict` 通过；
全 harness `PASS=34 FAIL=0`。

**未覆盖**：手感是否真的不再发黏是主观指标，只能人工验收；`HIDPointerResolution` 仍不可写，
线性后若整体速度不合适用「自定义移动速度倍率」补偿。

---

## 29. HID++ 0x2201 真实 DPI 能力（2026-11-06）

用户指出鼠标 DPI 上限 25600，而罗技区 Picker 只有 400…3200。修复范围远大于「把数组加长」：
旧链路的档位、当前值、「支持 HID++ 2.0」状态、「已应用硬件 DPI」成功提示**全是假的**。

**协议契约**（对齐 libratbag `hidpp20.c` 的 `CMD_ADJUSTABLE_DPI_*`）：

| 项 | 值 |
| --- | --- |
| report / deviceIndex | `0x11` 长报文 / `0x01` 配对鼠标 |
| featureIndex | **必须由 root feature `getFeature(0x2201)` 查询**，本机 `pid=0xc547` = 7；`0xc548` = 0 表示不支持 |
| address | `(function << 4) \| swId(0x8)` → `0x08` count / `0x18` DPI list / `0x28` 当前 DPI / `0x38` 写入 |
| DPI 编码 | 16-bit big-endian 原始值，不缩放 |
| DPI list | `p[0]`=sensor，之后每 2 字节一项；`0x0000` 结束；`>0xE000` 的项是步长（`value-0xE000`） |
| 写入回显 | `p[1..2]` 回显 DPI；`0` 表示协议 v0 不回显，仍需读回校验 |

本机真机回报：`00 00 64 e0 32 64 00` → 档位 **[100, 25600]**、步长 **50**；
`00 15 18 06 40` → 当前 **5400**、默认 **1600**。

**契约（不可回退）**：

1. 档位只能来自设备回报；解析失败 / 未探测到时**不显示**任何档位，**不**用硬编码列表兜底。
2. `setDPI` 必须：(a) 已通过真实探测拿到 featureIndex；(b) 检查 `IOHIDDeviceSetReport` rc；
   (c) 校验设备回显；(d) 发 `0x28` 读回且 `readBack == target`。四项全过才报成功，
   否则显示具体拒因且不更新本地 `currentDPI`。
3. 写入必须是**显式动作**（「应用」按钮）；禁止用选中项变化监听自动下发，
   否则打开页面就会因同步当前值触发一次 SET。
4. 探测/写入放后台串行队列，不阻塞主线程；响应慢要重试，过期结果用 generation 作废。

**测试**：harness **L 段 30 项**（真机字节解析 / 报文 / 写入判定五类拒因 / 解析防御）、
**L_W 13 条接线守卫**、**L_MUT / L_MUT2** 两趟变异验证（失败报绿、写死 0x22 必须报红）。
全 harness `PASS=38 FAIL=0`。

**真机**：App 内显示「HID++ 0x2201 已探测: 100–25600 DPI (步进 50)，当前 5400 DPI」，
Picker 5,400 DPI；独立幂等写入 5400→5400 回报回显 5400、读回 5400 → VERIFIED（未改动设置）。
`codesign --verify --deep --strict` 通过，Mach-O `63d18d35…`。

**未覆盖**：只验证了幂等写入，未实测「改成另一个 DPI 值」（不擅自改动用户硬件设置）；
设备休眠时探测可能超时，UI 提示点「刷新」重试。**未发版**。

---

## 30. 内建触控板加速度隔离契约（2026-11-06）

§29 收尾时真机截图发现「状态」区整段红字，第三行为
`Apple Internal Keyboard / Trackpad … 回读 -0.000 … ⚠️ 写入未生效`。
用户勾选的旧开关把一台**不接受写入**的设备拉进 `eligible`，`allOK=false` 把整段标红。
这是假失败，不是写入失败；开关本身是没有载体的假选项。

**契约（不可回退）**：

1. 设备范围与开关解耦：`PointerAccelPolicy.scope(builtIn:) -> PointerAccelScope`
   恒把 builtIn 判为 `.systemManagedBuiltIn`；`eligible()` 只返回外接鼠标 rid。
   `pointerIncludeBuiltIn` 保留为 `StoredState` 解码兼容字段，不再影响任何行为；
   UI 不得再出现对应 Toggle（旧存档为 true 也必须忽略）。
2. 跳过必须可见：`PointerAccelStatus.skippedLine(name:)` 返回带设备名与原因的状态行，
   不含 `⚠️`、不含「写入未生效」；`apply()` 必须把每台 skipped 设备追加到 `lines`。
   静默跳过是另一种假绿。
3. 跳过不参与成功判定：`allOK` 只吃 `writeResults`（真正执行过写入的设备结果），
   空数组判 false（只有触控板时不能报「已接管」）。`readings` / 签名只由 `eligible`
   生成，触控板读数不得触发轮询重写。
4. `restoreDefaults()` 仍全量还原，负责清理旧版本对触控板的历史写入。

**测试**：harness M 段 16 项 + M_W 9 条接线守卫 + 三趟变异
M_MUT / M_MUT2 / M_MUT3 —— 把触控板重新纳入写入、把 `allOK` 改成恒真、抹掉跳过原因，
都必须被具体断言抓红。全 harness `PASS=43 FAIL=0`。

**真机**：状态区三行灰白（无红字）：两行 USB Receiver 回读 -1.000、系统默认 2.500，
一行 `内建触控板由系统管理（不写入加速度）`。Mach-O `6b0fe9c8…`，验签通过、
TeamIdentifier 不变。**未发版、未提交**。

---

**2026-11-03 清理轮**：`/Applications` 的 7 个隔离备份移至 `~/.smoose-rollbacks/`（点号目录不进 Spotlight，`MANIFEST.txt` 记录版本 / sha256 / 理由），`~/Downloads` 的 2 个重复副本 + `Smoose-1.3.0.zip` 移至 `~/.Trash/smoose-cleanup-2026-11-03/`；全程 `mv` 可还原，harness 复跑 `PASS=26 FAIL=0`。

---

## 31. 硬件 DPI 快捷键切换后的自动同步契约（2026-11-06）

用户按鼠标 DPI 键切档后，界面必须跟上；但**同步 ≠ 接管**，Smoose 只读不写。

**依据**：Solaar `notifications.py` 中 `0x2201` 无 DPI 变更通知（ONBOARD_PROFILES 只给
resolution_index、不带数值），所以必须主动 `GET_SENSOR_DPI`。独立进程实测
`IOHIDDeviceOpen(None)` 预热后 15/15 读到当前 DPI —— 早期「非抢占收不到响应」是
接收器休眠误判；因此同步连接**必须非独占**，不得 `SeizeDevice`。

**契约（不可回退）**：

1. `HIDPPWatchSession` 只读：禁止 `0x38` / `HIDPPWrite` / `setDPI`；任何情况下不回写硬件。
2. 门禁 `windowVisible && dpiPageVisible && !isWriting && probeInfo != nil`，**不含 `appActive`**。
   硬件切档常发生在 Smoose 非前台时，加前台门禁等于关掉同步（真机连拍第 41 帧起复现）。
3. `HIDPPDPISync.outcome` 必须区分 `hardwareChanged` / `noChange` / `readFailed` /
   `outOfRange` / `ignoredWhileWriting`；读失败不得伪装成 noChange，写入期间观测值不得
   被当成硬件切换。
4. 状态文案含「未回写硬件」，不得复用「已应用硬件 DPI」；`warmupRequests >= 2`，
   连续失败退避间隔必须大于正常轮询。
5. 非常规档位（3300）仍要出现在 Picker，但整体受设备 100–25600 能力约束。

**测试**：N 段 23 项 + N_W 26 条守卫（含「同步只读」「无 appActive」）+ 三趟变异
N_MUT / N_MUT2 / N_MUT3。真机：5400 → **14700** 端到端同步，重启后一致，
独立探针复读硬件真值确认未被回写。详见 `HANDOFF.md` §4.11。

---

## 32. 系统设置跳转契约（2026-11-07）

**两个独立故障**：① System Settings 进程长时间运行后不响应 AppleEvent，`open` 报
`-1712` 并弹系统级英文「not responding」（macOS 自身状态，重启进程即恢复）；
② 旧 anchor `Privacy_Accessibility` 在 macOS 27.3 落到 **Device Control and Data Access**，
而 `com.apple.Accessibility-Settings.extension` 是辅助功能功能设置页 —— 都不是授权列表。

**契约（不可回退）**：

1. `AccessibilitySettingsLauncher.urlString` 使用
   `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?privacy-accessibility`；
   禁止回退 `com.apple.preference.security?Privacy_Accessibility`。
   在不支持精确子页跳转的系统上安全退化为「隐私与安全性」首页，UI 必须给出手动路径
   `系统设置 → 隐私与安全性 → 辅助功能`。
2. 必须用 `NSWorkspace.open(_:configuration:completionHandler:)`；只有 `error == nil`
   才算 `.opened`，空白原因也判 `.failed` 并补明确原因。
3. `failureMessage` 三要素：具体原因 + 「重试」+ 手动路径；视图显示红字与重试按钮。
   禁止回到裸 `NSWorkspace.shared.open(url)`（失败被吞 + 英文系统弹窗）。
4. App 不强杀系统进程；`smoose://onboarding` 强制显示引导页用于复测，不改 TCC 授权。

**测试**：O 段 14 项 + O_W 13 条接线守卫（含前置非空、build.sh 接线、旧实现消失）+
三趟变异 O_MUT / O_MUT2 / O_MUT3。真机点击「去授权」→ 系统设置 `Privacy & Security`、
无报错弹窗、引导页无红字。全 harness `PASS=53 FAIL=0`。详见 `HANDOFF.md` §4.12。
**未发版、未提交**。

---

## 33. 光标放大开关与两步 Display deep link 契约（2026-11-07）

**问题**：「快速移动鼠标时放大光标图标」开关显示开启但功能没生效。真机确认
`CGDisableCursorLocationMagnification` 键是对的（系统设置点开关时全局域只有它变化），
但这个偏好由 WindowServer 在**登录会话启动时**加载；第三方写 plist 不会热更新，
`defaults write` 后系统设置 GUI 不刷新、切页重进也不刷新。
旧 `apply()` 无返回值、写完即报绿 = 假绿。

**契约（不可回退）**：

1. `CursorZoomController.apply() -> CursorZoomApplyResult`。写后必须用
   `CFPreferencesCopyValue` 独立读回；**禁止**用 `UserDefaults(suiteName:)` 的
   进程内缓存自检（写完立刻读必然是新值，还是假绿）。
2. `CursorZoomPolicy.verdict` 分 case：`writeFailed` / `readBackMismatch(expected:actual:)` /
   `suiteUnavailable` / `writtenPendingRelogin`。读不到、不一致、写失败都不得算成功；
   mismatch 必须带具体期望值与实际值。
3. `.writtenPendingRelogin` **只表示偏好写好了**。状态文案必须同时含「已写入」、
   「重新登录」、可操作路径；禁止「已生效 / 立即生效」字样。
4. `CursorZoomApplyResult.ok` 只有 `.writtenPendingRelogin` 为真；失败时 Toggle 回弹。
   视图必须用自定义 `Binding`（set 里写入、成功才更新 `prefs`），不得回到
   `.onChange(of:)` 直接改状态。
5. 页面常驻「当前显示的是系统偏好值」说明，避免蓝色开关被误读成即时生效。
6. `DisplaySettingsLauncher.urlSequence()` 必须是两步
   `[baseURLString, baseURLString + "?display"]`。冷启动单发带 anchor 的 URL
   只到 `Accessibility` 首页（实测 `?Seeing_Display` / `?display` /
   `?Accessibility_Display` / `?pane=display` / `?page=display` 全部如此）；
   两步法 0.4 / 1.0 / 2.0s 三种间隔都稳定到 `Display`。
   第二步失败必须返回带具体原因的 `.failed` 并给重试，不得报 `.opened`。
7. `manualPath` 保持 `系统设置 → 辅助功能 → 显示 → 摇动鼠标指针以定位`。

**测试**：P 段 31 项 + P_W 21 条接线守卫（含前置非空、独立读回、失败回弹、
两步真的接线、旧实现消失）+ 四趟变异 P_MUT / P_MUT2 / P_MUT3 / P_MUT4，
均要求具体 case 报红。全 harness `PASS=59 FAIL=0`。

**真机**：点开关 plist `0 → 1 → 0`（两次读回均通过，最终恢复用户原值）、
状态行显示待重新登录文案、无红字；冷启动点按钮 → 系统设置 `Display`、
`Shake mouse pointer to locate` 可见、无报错弹窗。
**未覆盖**：未真机构造读回失败负例；未实测重新登录后摇动放大效果（macOS 侧行为）。
详见 `HANDOFF.md` §4.13。**未发版、未提交**。

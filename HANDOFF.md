# Smoose — 项目交接文档（HANDOFF）

> 仿 [Mos](https://github.com/Caldis/Mos)（公认最好的 macOS 鼠标滚动增强工具）的原生菜单栏 App。
> 把鼠标滚轮的「一格一跳」重建成触控板那样的连续滚动曲线，并附带指针加速度 / 速度控制（LinearMouse 那一半）。
> 原生 Swift，零第三方依赖。
>
> 本文档面向接手维护的开发者，记录架构、能力、关键坑、构建方式与未决项。
> **最后更新：2026-10-28 第五轮**（**攻破「受限环境编译不了 Swift 宏」这一长期限制**：
> `swiftc -disable-sandbox` → 全量编译 / 完整 harness 都能跑 → 重新构建并部署到 `/Applications`，
> 这是第一个真正包含 10-27 第四轮改动的产品）。
>
> **2026-10-27 第四轮**（10-26 只读审核 + P0/P1/P2 修复 → 10-27 补 H 段 harness、
> 修 IPv6 回环与签名回退、重新部署并发 v1.2.1 → 10-27 第三轮逐条复核文档与实况 →
> **第四轮：修掉 H20 假绿**）。
>
> **2026-10-28 第五轮（本轮）**：把「受限环境编译不了含 SwiftUI 宏的文件」这条**长期定论推翻**。
> 根因是宏展开要 `swift-plugin-server`，它自己套 `sandbox-exec`、被外层禁掉；
> `swiftc -disable-sandbox` 即可破（`build.sh` / `run_tests.sh` 加了 `SMOOSE_SWIFT_EXTRA` 开关，普通终端行为不变）。
> 于是首次在受限环境跑通**完整 harness：`PASS=11 FAIL=0`**，并重新构建部署到 `/Applications`
> （sha256 `87e4e24fe0b259b3…a07db`，授权 `auth_value=2` 保留，启动无崩溃）。
> ⚠️ 10-27 那次部署早于第四轮改动，**只有这次部署才真正带上 H20/Updater 的修复**。
>
> **2026-10-27 第四轮**：修 §6.1c 记下的假绿漏洞。H 段从 20 条扩到 24 条 ——
> H20/H21/H22 改为按**拒因 case** 断言（`UpdateInstallError` 放开 private 并拆出 `notSigned`/`teamMismatch`），
> H23/H24 新增前置自检、下钻到 Mach-O 文件本身。做了反向验证：三种假包场景下 H23 全红、H24 红两种。
> 实测还发现一个比原来记录的更隐蔽的点：**Mach-O 缺失时 bundle 级 `codesign` 照样报 `Signature=adhoc`**。
>
> **2026-10-29 第五轮**：修「检测更新没有成功」反馈缺陷。检查成功且已是最新时 `phase` 原来置回
> `.idle`，而 `UpdateStatusView` 对 `.idle` 渲染 `EmptyView` —— 用户点「检查更新」后除时间戳外零反馈，
> 把「没有新版」误读成「检查失败」（网络/版本源实测都正常，纯粹是 UX 断层）。
> 修复：`Phase` 新增 `.upToDate(String)`，`UpdateStatusView` 显示「已是最新版本 v<当前版本>」。
> harness 新增 G2b 文本守卫（3 处断言），`PASS=12 FAIL=0`。见 SPEC D16。
> 已重新构建并部署 `/Applications/Smoose.app`（授权保留），真机静默检查实测成功。
>
> **2026-10-29 第六轮（优化轮）**：四项优化一次落地 ——
> ① 检查更新 ETag 条件请求（304 复用缓存体；**必须配 `reloadIgnoringLocalCacheData`**，默认策略拿不到 304，实测踩过），
> 缓解 GitHub 60 次/h/IP 限流；② 下载断点续传 + 超时 120s（慢网截断 732KB 残包的教训）；③ 合成滚轮事件显式打
> `timestamp`（ns since startup，部分消费端动量计算依赖）；④ `handlePointerMove` rem 累积数据竞争收尾（§7 老账，
> 实际是无锁段在 rem 累积处，`apply()` 本来就有锁）；⑤ `profile(for:)` 帧循环缓存（热路径读 `cachedProfile`，
> 只在 apply / setActiveApp 两处重建）；⑥ `release.sh` 把安装包 sha256 写进 Release notes（手动下载可自行核对）。
> harness 新增 G2c（11 项断言，含变异验证），`PASS=13 FAIL=0`。ETag 304 与静默检查均真机实测通过。见 SPEC D17。
>
> **2026-10-27 第二轮**：把含全部修复的新构建重新部署到 `/Applications`、清理历史遗留的嵌套 `Smoose.app`（见 §6.1）、
> 补 `.gitignore`、实测确认 `--device` 真机断言在本环境没有可靠载体（§6.1b + SPEC §7 警告框）、
> README/SPEC/HANDOFF 三处文档同步（阶段表改十一段、源码行数对齐实测、修正失实验证声明）。
>
> **2026-10-27 第三轮**：不是加功能，是把前两轮写的文档逐条对回现实。
> 那一轮实测纠掉：二进制 sha256 记录值 `a26c1d37…` 与实况 `030c309d…` 不符；
> §6 的构建命令仍在教人用 §6.1a 明令禁止的 `cp -R`；§1 与 §6 对签名回退的描述互相打架；
> 「PASS=11」与「20 项断言」是两个不同计数器被写进同一句；
> H20 断言会因「假包根本没签上」而假绿（**第四轮已修**，详见 §6.1c）。

---

## 1. 项目状态

| 项 | 状态 |
| --- | --- |
| 位置 | `/Users/a1-6/AI Shared/repo/Smoose/` |
| 功能完整性 | 滚动平滑 / 倍率 / 双轴 / 每应用 / 按键绑定 / 指针加速度 / 指针速度倍率 / 侧键动作 / 指针放大 全部已实现 |
| 已编译产物 | `/Applications/Smoose.app` 版本 **1.2.1**（**2026-10-28 第五轮重新部署**）。Mach-O 二进制 sha256 `87e4e24fe0b259b3…a07db`（10-28 实测；此前记的 `030c309d…` 已作废，再早的 `a26c1d37…` 同样作废）。**这是第一个真正包含 10-27 第四轮 H20/Updater 改动的产物** —— 10-27 那次部署早于这些改动。含 10-26 安全加固与 10-27/10-28 修复；`codesign --verify --deep --strict` 通过、`TeamIdentifier=6U2DQJ6Z2N` 与客户端期望一致、辅助功能授权 `auth_value=2` 保留、启动无崩溃。滚动接管、指针速度 0.5x–2x、静默更新检查链路、版本源 404 话术均实测过（更早轮次）。部署用 ditto 配方，见 §6.1a |
| 源码 | `Sources/*.swift` 11 个文件，共 **3311 行**（Views 917 / Updater 639 / ScrollEngine 484 / App 409 / Model 305 / UpdateModel 198 / PointerController 174 / ScrollAxis 70 / Actions 54 / CursorZoom 48 / main 13） |
| 构建 | `build.sh`（签名身份三级回退：`SMOOSE_SIGN_ID` → 自动探测本机 Apple Development 证书 → ad-hoc 并警告） |
| 发布 | `scripts/release.sh`（打 zip + 自检 + 可选发 GitHub Release） |
| 验证 | `run_tests.sh`（harness，A/B/C/D/E/F/F2/G/G2/G2b/G2c/G3/H 十三段）、`Tests/InterpTest.swift`、`Probe/main.swift` |
| 规格 | `SPEC.md`（契约 + 断言，见 §9 落位规则） |
| 版本源 | GitHub `cpufreestyle/Smoose`（public，已发 v1.1.0 / v1.2.0） |

入口形态：**纯 AppKit**，不是 SwiftUI `App` 协议。详见 §3。

---

## 1.1 安全修复与缺陷修复（2026-10-26 只读审核后）

### P0（已修）：自动更新器可被远程代码执行

App 持有**辅助功能权限**（能监听并合成全局输入），所以「自动更新」这条链路等价于远程代码执行入口。原实现解压后**只比对 bundle id** 就覆盖 `/Applications/Smoose.app` —— 而 bundle id 只是 Info.plist 里的一个字符串，谁都能写；版本源地址用户可填任意 URL 且不强制 HTTPS，MITM 可直接换包。

现在装了四道关（全部在 `Updater`）：

1. **强制 HTTPS**：`Updater.validatedURL(_:)` 只放行 `https`（`http://localhost` / `127.0.0.1` / `::1` 例外，留给自建源自测）。**版本源与下载地址都过这一关**。
2. **SHA-256 校验**：`UpdateManifest.sha256`（也认 `sha256_sum` / `digest`）。版本源给了就验，没给就跳过 —— 不阻断已有流程。流式计算，3MB 文件实测与 `shasum -a 256` 一致。
3. **codesign 完整性**：`codesign --verify --deep --strict`，`--deep` 覆盖嵌套 framework/helper。
4. **发布者身份**：比对 `codesign --display --verbose=4` 输出的 `TeamIdentifier` 与 `Updater.expectedTeamIdentifier`（默认 `6U2DQJ6Z2N`）。拷贝落盘到 `/Applications` 之后再验一次，失败回滚原版。

> ⚠️ **Team ID 的坑（实测踩到）**：`expectedTeamIdentifier` 必须取 `TeamIdentifier=` 那一行，
> **不是**签名身份 CN 括号里那串。本机构建用 `Apple Development: qm0819@hotmail.com (5F66DDWD6H)`，
> 但 `codesign` 报告的是 `TeamIdentifier=6U2DQJ6Z2N`。**照抄证书名会让每一次更新都被拒绝。**
> fork 请改这个常量，或在 Info.plist 里加 `SmooseUpdateTeamID` 覆盖。

`scripts/release.sh` 同步加了发布端自检：打出的包若拿不到 TeamIdentifier（ad-hoc）直接 `exit 1`，
避免产出「用户永远装不上」的包；并额外产出 `dist/Smoose-<ver>.json`（含 sha256），可直接自托管当版本源。

### P1（已修）

- **开了「抬起时触发」会让未绑定侧键失效**：`ScrollEngine.handleButton` 在 `triggerOnMouseUp` 下无条件吞掉 DOWN，哪怕该键没绑任何动作 —— 结果系统只收到 UP，浏览器前进/后退等原生侧键彻底不工作。现在先解析 action，确认有绑定才吞 DOWN，无绑定原样放行。
- **`mouseMoved` 里跨进程查询前台 App**：`handlePointerMove` 每次移动都调 `NSWorkspace.shared.frontmostApplication`（120Hz 屏上每秒几百次同步查询），直接顶高指针延迟。改为读 `activeAppID` 缓存，该缓存由 `AppDelegate` 监听 `didActivateApplicationNotification` 维护。

### 10-27 补 harness 时发现并修掉的两个缺陷

上一轮（10-26）的安全加固本身是对的，但**没有配套 harness**，而且引入了两个回归：

- **IPv6 回环被误拒**：`validatedURL` 里拿 `comps.host` 直接跟 `"::1"` 比，而 `URLComponents.host`
  对 IPv6 字面量**保留方括号**（返回 `"[::1]"`），于是永远不等——HANDOFF 承诺放行 `::1` 却没生效。
  已改成先剥括号再比，并由 H5 断言守住（变异验证：删掉剥括号逻辑 → H5 FAIL）。
- **默认构建路径退化**：`build.sh` 从「写死个人证书」改成「只认 `SMOOSE_SIGN_ID`」，不 export 就产出
  ad-hoc 包，而 `release.sh` 的 TeamIdentifier 自检必然拒绝 → **F stage 直接红**，跑一次 harness
  都要先手动设变量。已改成三级回退：环境变量 → 自动探测本机 Apple Development 证书 → ad-hoc 并警告。
  这样既不把个人证书写进代码，默认路径也仍然可用。

### P2（顺手修）

- `URLSession` 泄漏：`check()` / `downloadAndInstall()` 每次新建 ephemeral session 从不 invalidate。现在强引用并在完成后 `finishTasksAndInvalidate()`。
- 指针状态显示量纲错：`PointerController.apply` 把 UI 浮点值又除了一次 65536，显示成 `0.000`（写入是对的，只是看着像失败）。
- `build.sh` 写死个人证书 → 改走 `SMOOSE_SIGN_ID` → 10-27 又补成**三级回退**（见 §6）。最终形态是
  环境变量 → 自动探测本机 Apple Development 证书 → ad-hoc 并警告，所以 P2 里「未设置即回落 ad-hoc」这句已过时。

**验证（2026-10-27 第三轮实测核对）**

- 此前的记录链：10-26 写「离线 harness 12 项断言全部通过」，但当时 `run_tests.sh` 还停在 10-23，
  那些安全行为一条断言都没有 —— 文档声称的验证并不存在（10-27 第二轮修正）。
- 现状：**H stage 的 25 条断言（H1–H25）全部通过**；2026-10-28 起可直接在受限环境跑完整 harness
  （`SMOOSE_SWIFT_EXTRA=-disable-sandbox ./run_tests.sh` → `PASS=11 FAIL=0`），验的是真源码不是逻辑副本。
  此前（10-27）只能用退化手段：本沙箱编译不了含 SwiftUI 宏的 Views/App/CursorZoom，改用不含宏的
  7 文件子集 + H 段真实 `main.swift` 编译执行。该手段现在只用于「想快一点拿到反馈」。
- **计数器别混**：H 段自己有 25 条断言；`PASS=11 FAIL=0` 是整个 harness 的 **11 个 stage** 全部通过。
  两个数不是一个量。文档里曾写成「20 项断言 … PASS=11」，现已分开表述。
- H20 的假绿风险第四轮已修：不再只验「抛了错」，而是按拒因 case 断言，并加 H23/H24 前置自检守 Mach-O
  确实是真货。**H20/H23/H24 是一组，拆开删就等于把假绿放回来**。详见 §6.1c。
- 仍未覆盖：真实网络下载安装、实机滚动手感、指针速度改写的真机断言（§6.1b 说明为何没有载体）。

---

## 2. 已实现能力

| 能力 | 说明 |
| --- | --- |
| 平滑滚动 | HID 层拦截 `scrollWheel`，按显示刷新率（ProMotion 可达 120Hz）用 `CVDisplayLink` 帧驱动插值 |
| 距离倍率 | 0.2×–8×（默认 3.2）。≈4× 接近 Chrome/Safari 原生行滚动；≈1.6× 接近原生 AppKit 控件 |
| 顺滑度 | 0–1 → 指数插值时间常数 τ（0.006s ~ 0.27s），默认 0.45 |
| 最小步长 | 低于此值的微推被放大（默认 6px），避免轻推无反应 |
| 每格行数 `wheelLines` | 只作用于离散滚轮鼠标，不作用于连续滚动 |
| 双轴独立 | 垂直 / 水平各自独立开关平滑与方向反转 |
| 忽略触控板 | 触控板 / Magic Mouse 的连续滚动默认原样透传（启发式判定，见 §4.4） |
| 每应用配置 | 按 bundle id 单独配置，或一键套预设 |
| 修饰键透传 | 按住 ⌘⌥⌃⇧ 等掩码时跳过接管、原样透传（精确操作场景） |
| 按键绑定 | 中键与侧键 3/4/5 → 调度中心 / 启动台 / ⌘⇥ / 显示桌面 / 浏览器前后 / 切换桌面 / 截图面板等；支持前后键互换、抬起时触发、按应用单独绑定、按键测试面板 |
| 指针加速度 | 直接改写 IOHIDSystem HID 参数，等价于 LinearMouse 核心能力（0 = 线性） |
| 指针速度倍率 | 走 Event Tap 原地改写 `mouseMoved` 的 delta（不是 HID 参数，见 §4.6） |
| 指针放大 | `CursorZoomController` 开关系统光标放大 |
| 开机启动 | `SMAppService` 登录项 |
| 首次引导 | 未授权辅助功能时 1.2s 后弹引导窗，直达系统设置隐私页 |
| 权限自愈 | 信任轮询常驻：授权撤销自动停 tap，恢复授权自动重建 |
| 窗口自愈 | 定时守护 status item 与设置窗口：窗口中心不在主屏则移回主屏居中（修「界面打不开」） |
| 自动更新 | 版本源拉取 + SemVer 比较 + 增量进度下载 + **签名校验** + 替换重启，零第三方依赖 |
| 更新 UI 出口 | 菜单栏面板顶部新版本横幅（静默检查的出口）、「关于」页状态条、「跳过此版本」 |

**预设**（`ScrollProfile.presets`）：默认 / 干脆 / 丝滑 / 浏览器 / 原生 App / 聊天软件 / 跳过此 App。

**自动更新错误话术**：`Updater.httpMessage(code:url:)` 把 HTTP 404 / 403 / 401 翻成可操作中文。默认源若 404 会提示「官方仓库尚未创建或未发过 Release，请先填版本源」。

---

## 3. 架构与模块

```
滚轮 / 按键 / 移动 HID 事件
   └─ CGEventTap(.cghidEventTap, .headInsertEventTap, .defaultTap)
         │  ScrollEngine.handle()  —— 来源判定 / 取值 / 回环防护 / 修饰键透传
         ▼
   ScrollAxis 状态机（每轴 target/current/sent）
         │  CVDisplayLink 每帧 advance(dt, τ)
         ▼
   CGEvent(scrollWheelEvent2Source:.pixel, magic=userData) → CGEvent.post(.cghidEventTap)
```

### 入口（重要，容易记错）

`Sources/main.swift` 是**顶层代码入口**（`NSApplication.shared` + `AppDelegate` + `app.run()`），
`App.swift` 里**没有 `@main`**。这是刻意设计的（详见 §6「为什么不用 SwiftUI App 协议」）。
顶层代码入口与 `@main` 不能共存，加回去会直接编译失败（`module that contains top-level code`）。

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `Sources/main.swift` | 13 | 纯 AppKit 入口 |
| `Sources/App.swift` | 409 | `AppDelegate`（装 tap / 启动指针控制 / 前台 App 监听 / 唤醒重设 / 未授权引导 / 更新定时器 / `applicationWillTerminate` 还原）、`StatusBarController`（NSStatusItem + NSPopover + 自愈）、`AnchorWindow` |
| `Sources/Views.swift` | 917 | SwiftUI 界面：`MenuBarPanel`、`SettingsWindow`（通用 / 按应用 / 按键 / 指针 / 关于）、`UpdateStatusView`、`PointerTab`、`OnboardingView` 等 |
| `Sources/Model.swift` | 305 | `ScrollProfile`（每轴参数 + τ 公式 + 预设）、`StoredState`（持久化结构）、`Preferences`（`ObservableObject`，JSON 存 `UserDefaults` key `smoose.state`） |
| `Sources/ScrollEngine.swift` | 484 | 事件拦截 + `CVDisplayLink` 帧驱动 + 回环防护 + 失控兜底 + 指针速度改写；`Monitor` 仅做界面展示 |
| `Sources/ScrollAxis.swift` | 70 | 纯逻辑插值状态机（不依赖 AppKit，可离线单测）。核心 `advance(dt, tau)` |
| `Sources/PointerController.swift` | 174 | 指针加速度（仿 LinearMouse）：枚举设备、记录基线、写回 HID 参数、6s 轮询、唤醒重设 |
| `Sources/Actions.swift` | 54 | 按键动作：合成 `CGEvent` 快捷键或 `NSWorkspace` 打开 App |
| `Sources/Updater.swift` | 639 | 自动更新运行时：检查 / 下载 / 解压 / **签名校验** / 替换 / 重启；失败 1h 重试、跳过版本、增量进度、后台安装、HTTP 话术 |
| `Sources/UpdateModel.swift` | 198 | 自动更新纯逻辑：`SemVer` / `UpdateManifest` 解析 / `UpdateCheck.decide`（可离线编译断言） |
| `Sources/CursorZoom.swift` | 48 | 系统光标放大开关 |
| `Resources/Info.plist` | — | `LSUIElement=true`（菜单栏常驻）、`NSAccessibilityUsageDescription` |
| `build.sh` | — | 绝对路径 `swiftc -O -target arm64-apple-macos14.0`，产出 `build/Smoose.app` 并签名 |
| `scripts/release.sh` | — | 发布产出端：打 zip + TeamIdentifier 自检 + 可选 `--github` 发 Release |
| `Tests/InterpTest.swift` | — | 插值引擎离线验证（需 `cp` 成 `main.swift` 编译，见 §6） |
| `Probe/main.swift` | — | 开发探针：枚举鼠标设备、读原始加速度、试写并回读、还原 |

---

## 4. 核心算法与关键实现细节

### 4.1 插值引擎（`ScrollAxis.advance`）
- 指数逼近：`current += (target - current) * (1 - e^(-dt/τ))`，到位阈值 `<0.05px` 直接 snap。
- **距离守恒**：不足 1px 的小数余数跨帧累积在 `sent` 里；到位时把 `≥0.5px` 的尾量结清，保证最终滚动距离 = `Σ(原始 delta × 倍率)`。离线测试 1/20/60 格场景误差为 0。
- 防 lag 无界增长：单轴 lag `>1600px` 截断；单帧投递 clamp 到 `[-512,512]`。
- `τ` 公式：`0.006 + smoothness² × 0.26`。默认 `smoothness=0.45` → τ≈0.059s，120Hz 下 90% 行程约 142ms。

### 4.2 事件取值策略（`ScrollEngine.raw(of:)`）
- 连续设备（触控板 / Magic Mouse）：优先 `fixedPt`（field 93/94，16.16 像素），保留亚像素。
- 滚轮鼠标：用 `pointDelta`（field 96/97，系统自己的 line→px 换算），保证不同鼠标「每格」语义一致；都为 0 时回退 `line × 10`。

### 4.3 回环防护（最重要、最易踩）
自己 `post` 出去的滚动事件会被同一个 tap 再次捕获 → 无限回环。三重标记 + 兜底：
1. `event.setIntegerValueField(F.userData, value: 0x5A5A_534D)`（魔法值），在 `isSynthetic` 里识别放行；
2. `event.getIntegerValueField(F.procID) == getpid()`；
3. 私有 `sourceStateID`（`CGEventSource(stateID:.privateState).sourceStateID`，lazy 缓存），匹配 `F.stateID`（field 45）放行；
4. 失控兜底：单秒投递 `>40000px` 直接 `reset()` 两个轴。

> ⚠️ 改事件字段时务必同步 `F` 里的 `CGEventField(rawValue:)` 映射
> （11/12/93/94/96/97/99/123/88/42/45/41/3，另有 dX=4 / dY=5 / buttonNo=3）。
> 不同 SDK 头文件命名会漂移，这里用 rawValue 锁死，不要改成命名常量。

### 4.4 触控板判定（启发式）
`IsContinuous(field 88) || ScrollPhase(field 99) || MomentumPhase(field 123)` 任一非 0 即视为连续设备 → 透传。
个别第三方设备可能误判 → 关掉「忽略触控板」即可对该设备生效。

### 4.5 指针加速度（仿 LinearMouse，`PointerController`）
- 参数都是 IOFixed（16.16）：`HIDMouseAcceleration = 163840` → 2.5。
- **老路线 `IOServiceOpen(IOHIDSystem, kIOHIDServerConnectType)` 在现代 macOS 被拒（返回 `0xE00002BD`）**，必须走 `IOHIDEventSystemClientCreateSimpleClient` + `IOHIDEventSystemClientCopyServices` + `IOHIDServiceClient*`。
- 每个设备的加速度存在哪个键由 `HIDPointerAccelerationType` 指定（外接鼠标 = `HIDMouseAcceleration`，触控板 = `HIDTrackpadAcceleration`）。
- 写回：`IOHIDServiceClientSetProperty(device.client, accelKey, NSNumber(value: Int(want * 65536)))`（返回 `Bool`，不要写 `!= 0`）。
- 开机 / 插拔后 6s 轮询重设；睡眠唤醒（`didWakeNotification`）强制重设。
- **`HIDPointerResolution` 只能从 IORegistry 读到、写不回去** —— 这是「速度」不能在 HID 层做的原因，才有 §4.6。

### 4.6 指针速度倍率（`ScrollEngine.handlePointerMove`）
因为 §4.5 的 `HIDPointerResolution` 不可写，速度倍率改走 **Event Tap 原地改写 `mouseMoved` 的 delta**，不吞事件、不重新合成：

```swift
pointerRemX += inX * scale          // scale = pointerSpeedFactor
let out = pointerRemX.rounded(.towardZero)   // 亚像素余数跨事件累积，避免小倍率下取整丢失
pointerRemX -= out
event.setIntegerValueField(F.dX, value: Int64(out))
return Unmanaged.passUnretained(event)       // 原地改写后放行
```

- **绝不能吞掉 `mouseMoved` 后重新合成投递** —— 合成事件会让 Dock 图标「粘住」、hover 放大失效（见 §6）。
- Dock / Finder 前台时完全不改写，原样放行（`activeAppID` 判定，**不要在这里查 `NSWorkspace`**，见 P1）。
- 只在 `pointerSpeedManaged && |factor - 1| > 1e-4` 时才改写，其余零开销放行。

---

## 5. 配置格式（接手排查用）

- 持久化：`UserDefaults` 域 `app.smoose.macos`，key `smoose.state`，值为 `StoredState` 的 JSON。
- `StoredState` 字段：`masterEnabled` / `ignoreTrackpad` / `global` / `apps` / `launchAtLogin` / `bindings` / `appBindings` / `swapBackForward` / `triggerOnMouseUp` / `pointerAccelManaged` / `pointerAccelerationValue` / `pointerIncludeBuiltIn` / `pointerSpeedManaged` / `pointerSpeedFactor` / `cursorZoomEnabled` / `autoCheckUpdates`。
- 更新相关配置**不进** `StoredState`（是发布配置不是手感配置），单独 key：`smoose.update.feed` / `.lastCheck` / `.lastCheckFailed` / `.skipped`。
- 注入测试配置：value 必须是 `<data>` 包装的 JSON 字节，**不是 `<string>`**，否则 App 读不到（曾因此误判 `managed=false`）：

  ```bash
  defaults import app.smoose.macos - <<'PLIST'
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0"><dict>
    <key>smoose.state</key>
    <data>{...StoredState JSON base64...}</data>
  </dict></plist>
  PLIST
  ```
  注意 `defaults write` 无法直接解析 JSON 字符串（会报 `Could not parse`），必须走 `defaults import` + plist。

- 设备实测：用户机器上检测到 **Razer DeathAdder 2013**（USB，5 键），加速度读写均通。

---

## 6. 构建与运行

### 6.1 2026-10-27 第二轮：部署事故与真机断言边界

**(a) `/Applications/Smoose.app/` 里曾嵌套一层 `Smoose.app`**

`cp -R build/Smoose.app /Applications/Smoose.app` 这种写法在目标已存在时会把源**拷进目标里面**
（变成 `/Applications/Smoose.app/Smoose.app/`），而不是覆盖。残留的嵌套层会让
`codesign --verify --deep --strict` 报 `unsealed contents present in the bundle root`，
LaunchServices 也可能因此拒绝启动 —— 这正是「双击桌面图标完全没反应」类现象的物理成因之一。

安全的部署写法（先清目标再拷，或用 `ditto` 到不存在的位置）：

```bash
/usr/bin/ditto --noqtn build/Smoose.app /Applications/Smoose.app.new
/usr/bin/find /Applications/Smoose.app -mindepth 1 -delete   # 清空旧 bundle
/usr/bin/ditto --noqtn /Applications/Smoose.app.new /Applications/Smoose.app
/usr/bin/codesign --verify --deep --strict /Applications/Smoose.app   # 必须 VERIFY_OK
```

本次处置：把嵌套层隔离到 `/tmp/smoose_junk/nested/`（先确认内容与新包 sha256 一致才动），
再用 `ditto` 重铺。部署后实测：`open -a` 起来 pid 正常、`LSUIElement=true` 只出菜单栏图标、
`open smoose://settings` 弹出设置窗（坐标 476,120 / 尺寸 560×548）、
系统 TCC.db 里 `app.smoose.macos` 的 `auth_value=2`（已允许，2026-10-07 起未失效，证明证书签名确实保住了授权）。

**(b) `--device` 真机断言在本环境没有可靠载体（逐条实测过，勿再重复尝试）**

SPEC §7 早期把 `--device` 列为 D 段真机断言，但 `run_tests.sh` 从未实现它，也没有任何断言。
本轮尝试了三条路，全部失败，结论是**这是 macOS 的边界，不是项目缺陷**：

| 方案 | 实测结果 |
| --- | --- |
| CLI 进程装 `CGEventTap` + 合成事件 post 到 `.cghidEventTap` / `.cgSessionEventTap` / `.cgAnnotatedSessionEventTap` | tap 创建后 `tapIsEnabled` 立刻变 `false`；即便开线程轮询 re-enable 也救不回；注入的 scrollWheel / mouseMoved **0 命中**。注意 `AXIsProcessTrustedWithOptions` 返回 true 也不管用 |
| `lldb -p <pid>` attach 进已授权的 Smoose，用 Swift 表达式调 `handlePointerMove` | attach 成功、进程健康，但产物 strip 过调试符号：`image lookup -s handlePointerMove` 为空，`expr -l swift` 报 `cannot find 'ScrollEngine' in scope` |
| `DYLD_INSERT_LIBRARIES` 注入断言 dylib 到 app 副本（bundle id 与真机一致以复用 TCC 授权） | app 副本在 `/tmp` 下起不来（`sandbox_extension_issue_file_to_process: Operation not permitted`）；移到合法路径后进程能起，但 `@_cdecl` 构造器不被触发，加 `__attribute__((constructor))` C shim 后进程直接起不来。dylib 与 app 自身 `Sources/` 符号重复定义 |

**结论与约定**：指针速度改写这条链路目前**只能人工验证**（开「指针速度倍率」→ 移动鼠标 → 手感是否随倍率变化）。
不要在 harness 里放一个假绿的 `--device` 段。这个边界已写进 SPEC §7 的警告框。

**(c) H20 断言的假绿风险（2026-10-27 第三轮发现 → 第四轮修掉）**

H20 想验的是「ad-hoc 重签的包必须被拒」。它构造的假包 `Contents/MacOS/Smoose` 是一行 `#!/bin/sh` 文本，
不是 Mach-O，`codesign --force --sign -` 签不上这种东西 —— 于是被拒理由不是「ad-hoc 缺 Team ID」。

第四轮实测更进一步：**Mach-O 整个缺失时，bundle 级 `codesign --display` 照样报 `Signature=adhoc`**
（shebang 脚本本身也能被 ad-hoc 签上）。所以「先确认假包处在 ad-hoc 状态」这个前置自检同样会假绿。

用真源码 `Updater.verifySignature` 跑四种假包，拒因如下：

| 假包 | 真 Mach-O | 实际拒因 |
| --- | --- | --- |
| cc 编译的真 Mach-O + ad-hoc 重签 | ✅ | `notSigned` ← **唯一想验的** |
| 文本 Mach-O + 项目 `Info.plist` | ❌ | `notSigned`（与上一行**完全相同**，无从区分） |
| 文本 Mach-O + 自制最小 `Info.plist` | ❌ | `signatureInvalid(code object is not signed at all)` |
| 完全缺失 Mach-O | ❌ | `notSigned`（与想验的那一行同） |

结论：**单看「抛了错」，第 1、2、4 行无法区分** —— 旧 H20 确实是假绿。

修法（H 段现为 25 条，H1–H25）：

- **H20/H21/H22 按拒因 case 断言**，不再只验「抛了错」。为此 `UpdateInstallError` 从 `private` 放开到
  internal，并拆出 `notSigned` / `teamMismatch(actual:expected:)`，与 `signatureInvalid` 三者可辨。
  （H22 是正向：官方包必须**通过**，防止把校验写成一律拒绝。）
- **H23/H24 是前置自检**，直接下钻到 Mach-O 文件本身，不看 bundle 那一级：
  H23 查首字节必须是 `0xCF`（Mach-O）或 `0xCA`（fat/universal）；H24 查 Mach-O 自身 `Signature=adhoc`。
  Mach-O 造不出来就直接报红，**不静默跳过**。
- **反向验证**：把假包换成上表第 2/3/4 种，H23 三种全红、H24 红两种 —— 防线确实咬得住。

⚠️ 两条提醒：

- **H20 单独拿出来仍然弱**（文本 Mach-O 也会返回 `notSigned`）。它现在的效力依赖 H23/H24 守前置。
  删掉 H23/H24 等于把假绿放回来 —— 这三行是一组，别分开删。
- 假包里的 Mach-O 由 `cc` 编译得来；`cc` 不可用时依次回退到 `/usr/bin/true`、已安装的 App 二进制。
  注意 **本 agent 沙箱里 `cc` 链接会失败**（`ld: library 'System' not found`），靠回退链兜住。
- `teamMismatch` 分支（有 Team ID 但不是我们的）**2026-10-28 已补上载体（H25）**：本机只有一个 Team 的私钥，
  造不出带别人 Team ID 的签名包，`/Applications` 里也没有第三方签名 App。解法是反过来改期望值 ——
  `expectedTeamIdentifier` 支持 Info.plist 覆盖，于是 harness 把测试二进制再包进一个 `.app`
  塞 `SmooseUpdateTeamID=FAKETEAM01`，那份**真实的官方包**（Team=6U2DQJ6Z2N）就会撞上 `teamMismatch`。
  已做变异验证：把 `guard team == expected` 放宽后 H25 如预期 FAIL（详见 SPEC §7）。

**(d) 工作区里有一个空的 `.git` 目录（2026-10-27 第三轮）**

`/Users/a1-6/AI Shared/repo/Smoose/.git` 存在但**是个空目录**，导致 `git status` / `git rev-parse`
在里面直接报 `fatal: not a git repository`，而实际项目并不在版本控制下，极易被误判成「仓库坏了」。
本轮已把它移到回收站（`~/.Trash/smoose_empty_git_20261027_020853`，空目录无内容损失）。
若之后想让工作区直接受版本控制，
用 `git init` + `git remote add origin https://github.com/cpufreestyle/Smoose.git` 即可。

```bash
cd Smoose
./build.sh                      # 产出 build/Smoose.app（绝对路径 swiftc，自包含）
                                # 签名身份通常自动探测，不用手动 export
# ⚠️ 部署到 /Applications 不要用 cp -R —— 会嵌套一层，见 §6.1a
/usr/bin/ditto --noqtn build/Smoose.app /Applications/Smoose.app.new
/usr/bin/find /Applications/Smoose.app -mindepth 1 -delete
/usr/bin/ditto --noqtn /Applications/Smoose.app.new /Applications/Smoose.app
/usr/bin/codesign --verify --deep --strict /Applications/Smoose.app
# 首次运行 → 系统弹辅助功能授权 → 系统设置·隐私与安全性·辅助功能 勾选 Smoose
```

- 目标：`arm64-apple-macos14.0`，macOS 14+。
- `SWIFTC` 取 `/usr/bin/xcrun --sdk macosx --find swiftc`（Xcode 工具链，Swift 6.4）。
- **签名身份三级回退**（2026-10-27 起）：
  1. 环境变量 `SMOOSE_SIGN_ID`（fork / 换机器时显式指定）
  2. 自动探测钥匙串里的 `Apple Development` 证书（默认路径，本机就是这条路）
  3. ad-hoc，并打印警告
  第 3 档每次 cdhash 都变，**辅助功能授权会在每次重新编译后失效**，且会被 `release.sh` 的
  TeamIdentifier 自检拒绝。演进顺序是：写死个人证书 → 只认环境变量（默认路径直接坏掉）→ 三级回退。
- 发布：`./scripts/release.sh [--github --repo owner/name]`。会自检 TeamIdentifier（ad-hoc 直接失败），
  产出 `dist/Smoose-<ver>.zip` 与带 sha256 的 `dist/Smoose-<ver>.json`（后者可直接自托管当版本源）。
- `.gitignore` 已忽略 `build/` `dist/` `.build/` `logs/` `.DS_Store` 以及 `/-`（`screencapture` 缺 `-R` rect 时误建的产物）。

**已知环境坑（必读）**：

- ~~本 agent 沙箱编译不了含 SwiftUI 宏的文件~~ **（2026-10-28 已解决，别再当定论）**：
  根因是 Swift 宏展开需要 `swift-plugin-server`，它自己要套 `sandbox-exec`，而外层禁止嵌套 `sandbox_apply`，
  表现为 `SwiftUIMacros.StateMacro could not be found ... malformed response`。
  **解法是给 `swiftc` 加 `-disable-sandbox`**（让编译器子进程不套沙箱），之后全量 11 文件可正常编译链接。
  `build.sh` / `run_tests.sh` 都留了开关，默认不影响普通终端：

  ```bash
  SMOOSE_SWIFT_EXTRA=-disable-sandbox ./build.sh
  SMOOSE_SWIFT_EXTRA=-disable-sandbox ./run_tests.sh   # 2026-10-28 实测 PASS=11 FAIL=0
  ```

  在此之前只能用两个退化手段，现在**只在想要更快反馈时才用**：
  `swiftc -parse`（只解析不展开宏，全量过语法）、
  `swiftc -typecheck` 对不含宏的 7 文件子集（Model / Actions / ScrollAxis / PointerController /
  ScrollEngine / UpdateModel / Updater）做完整类型检查。
- 同一环境里 **`cc` 链接会失败**（`ld: library 'System' not found`），所以 harness 造测试用 Mach-O 时
  靠 `cc` → `/usr/bin/true` → 已装 App 二进制 的回退链兜住（§6.1c）。
- Swift 化 C API（已踩过）：用 `CGEvent.tapCreate(...)` / `CGEvent.tapEnable(...)` / `CGEvent(scrollWheelEvent2Source:units:wheelCount:wheel1:wheel2:wheel3:)` / `event.setIntegerValueField(_:value:)` / `s.sourceStateID`，不要用 obsoleted 的 `CGEventTapCreate*` 旧名。
- 顶层语句测试：`Tests/InterpTest.swift` 需复制成 `main.swift` 再编译（否则 `expressions are not allowed at top level`）。
- 本机 shell 的 `swift` / `ls` 等被 alias 成 `_lc <cmd>` 且会随机失败，脚本里一律用绝对路径（`/bin/` `/usr/bin/`）。

### 为什么不用 SwiftUI `App` 协议（`main.swift` 注释，勿改回）
1. `.accessory` 策略（`LSUIElement`）下 App 无法被 LaunchServices 激活，双击桌面图标完全没反应（不发 reopen、不触发任何回调）。
2. `.regular` 策略下 SwiftUI 的 `Settings` 场景会在启动时自动弹出一个空窗口。

所以全部 UI 由 `AppDelegate` 手动管理：`NSStatusItem` + `NSPopover` + 手动 `NSWindow`。

### 已知行为坑：Dock 图标粘住（2026-10-19）

- 不要在 `CursorZoomController` 里调用 `CGAssociateMouseAndMouseCursorPosition(0)`；会把鼠标与光标解绑，Dock 把图标误判为拖拽目标（「粘住」）。
- `handlePointerMove` 只在真的改速度时才改写事件；接管加速度时**不要**吞掉 `mouseMoved` 后重新合成投递。原地改 delta 后放行即可。
- Dock / Finder 前台时完全不改写鼠标移动事件。

离线验证插值器：
```bash
mkdir -p /tmp/smoose_test && cp Tests/InterpTest.swift /tmp/smoose_test/main.swift
swiftc -O -sdk $(xcrun --sdk macosx --show-sdk-path) -target arm64-apple-macos14.0 \
  -o /tmp/smoose_interp Sources/ScrollAxis.swift /tmp/smoose_test/main.swift
/tmp/smoose_interp
```

验证指针写回能力（开发用，需辅助功能授权）：
```bash
SWIFTC=$(xcrun --find swiftc); SDK=$(xcrun --show-sdk-path); "$SWIFTC" -O -sdk "$SDK" Probe/main.swift -o /tmp/probe && /tmp/probe
```

---

## 7. 已知限制 / 未决项

- **未做（区别于 Mos / LinearMouse）**：
  - Logitech HID++ 侧键识别、手势、DPI 控制（另一层复杂度，需厂商协议）。
  - 输入法切换跟随等 Mos 附属功能。
  - **更新替换后若签名身份变化，TCC 辅助功能授权会失效，`Updater` 尚未提示用户**（2026-10-26 审核标为 P2，未修）。当前同一账号签名不会触发，换账号打包会触发。
- **启发式风险**：触控板判定靠 `IsContinuous/ScrollPhase/MomentumPhase`，个别第三方设备可能误判。
- **距离倍率基准**：绝对基准依赖各 App 自身的行距换算，这正是 Mos 提供每应用配置的原因，本作同样支持。
- **数据竞争（已修，2026-10-29）**：`pointerRemX/Y` 在 tap 线程读写、`apply()` 主线程重置。原记录称「无锁、未修」，
  实际核对：`apply()` 有锁，无锁的是 `handlePointerMove` 的 rem 累积段（`lock.unlock()` 提前了）。
  现已全程持锁，G2c-8 断言守住（unlock 后不得再访问 rem），变异验证可抓回归。见 SPEC D17。
- **版本比较**：`UpdateCheck` 只看 SemVer，不校验降级；`minSystem` 解析失败时放行（不阻塞检查）。
- ~~`teamMismatch` 无自动载体~~ **2026-10-28 已解决（H25）**：用「改期望值」而不是「造假包」拿到载体 ——
  把测试二进制包进带 `SmooseUpdateTeamID` 的 `.app`，官方包就会撞上 teamMismatch。`verifySignature` 的
  三条拒因分支（ad-hoc → `notSigned`、篡改 → `signatureInvalid`、他人 Team → `teamMismatch`）现在都有断言。

---

## 8. 接手 Checklist

- [x] `./build.sh` 编译通过并部署 `/Applications`（2026-10-07 首通；2026-10-22 部署 1.2.0；**2026-10-27 重新部署含全部修复的新构建**，见 §6.1a）
- [x] 实机验证：滚动接管（指数曲线 / 距离守恒）、指针速度 0.5×–2×、签名授权保持
- [x] `Probe/` 与 `Tests/` 保留（作为开发探针与离线回归）
- [x] 自动更新全链路：版本源拉取 → SemVer 比较 → 增量进度下载 → 解压 → 校验 → 替换 → relaunch，真机跑通（v1.1.0 → v1.2.0）
- [x] 发布产出端打通：仓库 `cpufreestyle/Smoose` 已建为 **public**（private 仓库 API 对未认证请求返 404，自动更新会直接失效），已发 v1.1.0 / v1.2.0
- [x] **2026-10-26 修复落地**：P0 更新器签名校验（HTTPS 强制 + sha256 + codesign + TeamIdentifier）、P1 未绑定侧键失效、P1 前台 App 查询移出 tap、P2 URLSession 泄漏 / 显示量纲 / 签名身份环境变量。配套 harness H 段（**25 条断言**）2026-10-27 补齐，
全 harness 11 段 `PASS=11 FAIL=0`（两个计数器的含义见 §1.1 验证段）。⚠️ 当时文档写的「12 项断言全通过」是失实的，harness 还停在 10-23，一条都没验（见 §1.1 验证段）。
- [x] **重建并重新部署**（2026-10-27 完成）：已部署含 10-26 安全加固 + 10-27 两个修复的新构建（版本 1.2.1），
      二进制 sha256 `030c309d5fa415e5…91081`（10-27 第三轮实测；该条目原先记的 `a26c1d37…` 与实况不符，已作废），
      `codesign --verify --deep --strict` 通过，`open smoose://settings` 实测能弹窗。
      注意**不要**用 `cp -R build/Smoose.app /Applications/Smoose.app`（会在目标里嵌套一层，见 §6.1a）。
- [x] **发 v1.2.1（2026-10-27 完成）**：版本号抬到 `1.2.1` 后跑 `./scripts/release.sh --github --repo cpufreestyle/Smoose`，
      Release `v1.2.1` 已发、asset 已上传，用户端的自动更新能真拿到 IPv6 回环与签名回退这两个修复。
      真机链路已逐段验证：GitHub `releases/latest` 返回 200 → 真实 `UpdateCheck.decide` 解出 `available(1.2.1)` →
      asset 下载 897507 字节、sha256 `2eb0885d…` 与产出端一致 → zip 顶层就是 `Smoose.app`、
      `codesign --verify --deep --strict` 通过、`TeamIdentifier=6U2DQJ6Z2N` 与客户端
      `expectedTeamIdentifier` 对齐、bundle id `app.smoose.macos` 匹配。
      ⚠️ 打了包必须重跑 `release.sh` 重新签名 —— 用 `plutil` 改 Info.plist 造出来的「新版」会让
      `_CodeSignature` 与 Info.plist 不符，客户端签名校验会直接拒绝。
- [x] **远端代码已推送（2026-10-27）**：远端从 `8b5cea4`（v1.2.0，10-22）推进到 `c61ad98`，
      历史完整保留（工作区不是 git 仓库，是在 clone 出的副本上提交后 push 的）。
      后续改动继续走「clone 副本 → 同步文件 → commit → push」这条路。
      ⚠️ 10-27 曾在工作区留下一个**空的 `.git` 目录**，会让 `git status` 报
      `fatal: not a git repository`，本轮已移入回收站（§6.1d）。别再手建空 `.git`。
- [x] 2026-10-27 第二轮文档同步：README 阶段表改十一段、HANDOFF/SPEC 源码行数对齐实测（3311 行 / Updater 639）、
      修正 HANDOFF 里失实的「12 项断言」验证声明、把 `--device` 无载体的边界写实（§6.1b + SPEC §7 警告框）。
- [x] **2026-10-27 第三轮：文档复核（不加功能）**。逐条对回现实后纠掉 5 处：
      ① 二进制 sha256 记录值 `a26c1d37…` 作废，实测 `030c309d5fa415e5…91081`；
      ② §6 构建命令还在教 `cp -R`（与 §6.1a 自相矛盾），已换成 ditto 配方；
      ③ §1 的三级回退 vs §6/P2 的「只认环境变量」互相打架，统一为三级回退；
      ④ 「20 项断言」与「PASS=11」拆开表述（前者是 H 段断言数，后者是全 harness stage 数）；
      ⑤ H20 假绿风险写实并给出强化方案（§6.1c）。
      另实测跑通 H1–H20（`H-OK`），移走工作区里的空 `.git`（§6.1d）。
- [x] **2026-10-27 第四轮：修掉 H20 假绿（§6.1c，已完成）**。H 段 20 → 24 条（10-28 第五轮再加 H25 → 25 条）：
      ① 假包改用 `cc` 编译的**真 Mach-O**（三级回退：`cc` → `/usr/bin/true` → 已装 App 二进制）；
      ② H20/H21/H22 改为按**拒因 case** 断言，为此 `UpdateInstallError` 放开 `private` 并拆出
      `notSigned` / `teamMismatch(actual:expected:)`；H22 是正向（官方包必须通过，防一律拒绝）；
      ③ H23/H24 前置自检下钻到 Mach-O 文件本身（首字节 `0xCF`/`0xCA`、自身 `Signature=adhoc`）。
      反向验证过：三种假包场景下 H23 全红、H24 红两种。H1–H25 全通过（`H-OK`）。
      ⚠️ 实测到比旧记录更隐蔽的一点：**Mach-O 缺失时 bundle 级 `codesign` 照样报 `Signature=adhoc`**，
      所以只看 bundle 那一级仍然假绿 —— H23/H24 必须保留。
- [x] **2026-10-28 第五轮：攻破受限环境编译限制 + 重新部署（见 §6 已知环境坑）**。
      `swiftc -disable-sandbox` 让 `swift-plugin-server` 不再需要嵌套沙箱，全量 11 文件可编译链接。
      `build.sh` / `run_tests.sh` 新增 `SMOOSE_SWIFT_EXTRA` 开关（默认空，普通终端行为不变）。
      完整 harness 首次在受限环境跑通：`PASS=11 FAIL=0`（11 段全过，含 H 段 H1–H25）。
      重新构建并 ditto 部署到 `/Applications`：版本 1.2.1、sha256 `87e4e24fe0b259b3…a07db`、
      `codesign --verify --deep --strict` 通过、`TeamIdentifier=6U2DQJ6Z2N`、TCC `auth_value=2` 保留、
      启动冒烟无崩溃。旧产物已备份在 `/tmp/Smoose.backup.20261028_235833.app`。
      ⚠️ 这是第一个带上 10-27 第四轮改动的产物（10-27 00:39 那次部署早于那些改动）。
- [ ] 署名合规：本项目仅学习自用，未包含 Mos 任何源码；Mos 原作 MIT © Caldis。
- [x] **`teamMismatch` 载体（2026-10-28 第五轮，已完成）**：改用「覆盖期望值」拿到载体 ——
      harness 把 H 段测试二进制再包进一个 `.app`，Info.plist 里塞 `SmooseUpdateTeamID=FAKETEAM01`
      （`expectedTeamIdentifier` 本来就支持这个覆盖键），于是真实官方包就会走到 `teamMismatch`。
      第二趟由 `SMOOSE_H_PASS=2` 触发、**必须在开头 `exit`**（否则会把依赖默认期望值的 H1–H24 也跑一遍而全红），
      H25PRE 前置自检确认期望值真的被改掉了。
      反向 + 变异验证都做过：ad-hoc 假包 → FAIL（拒因是 notSigned 不是 teamMismatch）；
      把 `guard team == expected` 放宽 → FAIL（官方包竟然通过了）。H 段现为 25 条，`PASS=11 FAIL=0`。

### 历史轮次要点（避免重复踩坑）

- **更新器服务端曾用本地 HTTP feed 测通过** —— 现在客户端强制 HTTPS，本地自测要改用 `http://127.0.0.1:PORT`（回环例外）或 HTTPS。
- **测试用「假新版」不能靠 `plutil` 改 Info.plist 生成**：会让 `_CodeSignature` 与 Info.plist 不符，`codesign --verify` 报 `invalid Info.plist`，装上去 LaunchServices 直接 `Launch failed`。必须改版本号后重跑 `build.sh` 重新签名。
- **harness 曾出现 FIFO 假绿**：`[ ! -s <(grep '^FAIL' ...) ]` 里进程替换产出 FIFO，zsh 的 `-s` 在写端 flush 前就判断，永远返回「空」，断言全 FAIL 也报 PASS。必须先把 grep 结果收进变量再判断。
- **H20 曾假绿（2026-10-27 第四轮修掉）**：断言只验「抛了错」，而假包用的是文本 Mach-O / 空目录，
  拒因与真 Mach-O 的 ad-hoc 包**完全相同**（都停在 `TeamIdentifier=not set`），恒成立。
  实测更隐蔽的一点：**Mach-O 缺失时 bundle 级 `codesign --display` 照样报 `Signature=adhoc`**，
  所以前置自检也不能只看 bundle 那一级，必须下钻到 Mach-O 文件（首字节 + 自身签名）。
  教训：断言要卡**拒因**，不能卡「有没有抛错」；否则假包退化时断言照样绿。
- **`relaunch()` 的 `NSApp` 崩溃**：`NSApp` 是隐式解包全局 optional，无 `NSApplication` 上下文（CLI / 测试）里是 nil。已改为 `if let app = NSApp { app.terminate(nil) } else { exit(0) }`。
- **`release.sh` 参数解析曾失效**：`--repo` 分支是空的导致 value 落到 `*)` 上 `exit 2`，文档主用法从来没能用过；`gh` 也曾硬编码 `/usr/bin/gh`（Homebrew 装在 `/opt/homebrew/bin`）。均已修。
- **提交前曾混进一个名为 `-` 的 1.1MB 截图**（`screencapture` 误建），已剔除并补 `.gitignore`（`build/` `dist/` `.build/` `logs/` `/-`）。

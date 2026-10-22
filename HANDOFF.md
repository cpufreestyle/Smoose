# Smoose — 项目交接文档（HANDOFF）

> 仿 [Mos](https://github.com/Caldis/Mos)（公认最好的 macOS 鼠标滚动增强工具）的原生菜单栏 App。
> 把鼠标滚轮的「一格一跳」重建成触控板那样的连续滚动曲线，并附带指针加速度控制（LinearMouse 那一半）。
> 原生 Swift，零第三方依赖。
>
> 本文档面向接手维护的开发者，记录架构、能力、关键坑、构建方式与未决项。

---

## 1. 项目状态（2026-10-22 更新）

| 项 | 状态 |
| --- | --- |
| 功能完整性 | 滚动平滑 / 倍率 / 双轴 / 每应用 / 按键绑定 / 指针加速度 / 自定义指针速度 / 侧键复制粘贴 全部已实现 |
| 已编译产物 | /Applications/Smoose.app（2026-10-22 部署；滚动接管、指针速度 0.5x-2x、授权保持、静默更新检查链路、版本源 404 可操作话术均实测通过） |
| 源码 | Sources/*.swift 11 个文件（约 3900 行） |
| 构建 | build.sh（证书签名 + 图标打包） |
| 验证 | run_tests.sh（harness，A/B/C/D/E/F/F2/G/G2/G3 十段）、Tests/InterpTest.swift、Probe/main.swift |
| 规格 | SPEC.md（契约 + 断言，见 §9 落位规则） |

备注：早期记录过「agent 沙箱拒绝嵌套 sandbox-exec 导致 swiftc 编译失败」，那是当时环境的限制；2026-10-07 的 Codex exec 环境实测可直接 ./build.sh 编译通过，此警告不再适用。

## 2. 已实现能力

| 能力 | 说明 |
| --- | --- |
| 平滑滚动 | HID 层拦截 `scrollWheel`，按显示刷新率（ProMotion 可达 120Hz）用 `CVDisplayLink` 帧驱动插值 |
| 距离倍率 | 0.2×–8×。≈4× 接近 Chrome/Safari 原生行滚动；≈1.5× 接近原生 AppKit 控件 |
| 顺滑度 | 0–1 → 指数插值时间常数 τ（0.006s ~ 0.27s） |
| 最小步长 | 低于此值的微推被放大，避免轻推无反应 |
| 双轴独立 | 垂直 / 水平各自独立开关平滑与方向反转 |
| 忽略触控板 | 触控板 / Magic Mouse 的连续滚动默认原样透传（启发式判定，见 §4） |
| 每应用配置 | 按 bundle id 单独配置，或一键套预设（默认 / 干脆 / 丝滑 / 浏览器 / 原生 App / 跳过此 App） |
| 修饰键透传 | 按住 ⌘⌥⌃⇧ 等掩码时跳过接管、原样透传（精确操作场景） |
| 按键绑定 | 中键与侧键 3/4/5 → 调度中心 / 启动台 / ⌘⇥ / 显示桌面 / 浏览器前后 / 切换桌面 / 截图面板；抬起触发配对抑制；按键测试面板（2026-10-16 从 myMouseMagic 反编译复刻，SPEC §14） |
| 指针加速度 | 直接改写 IOHIDSystem HID 参数，等价于 LinearMouse 核心能力（加速度数值 0=线性） |
| 开机启动 | `SMAppService` 登录项 |
| 首次引导 | 未授权辅助功能时 1.2s 后弹引导窗，直达系统设置隐私页 |
| 权限自愈 | 信任轮询常驻：授权撤销自动停 tap，恢复授权自动重建（myMouseMagic PermissionsService 模式） |
| 设置窗口定位自愈 | 5秒 healTimer 同时守护 status item 与设置窗口：窗口中心不在主屏则移回主屏居中（修复「界面打不开」，SPEC §15） |

---

- 自动更新（2026-10-22）：版本源拉取 + SemVer 比较 + 下载安装替换，零第三方依赖（SPEC §21）。
- 自动更新 UI 出口：菜单栏面板顶部新版本横幅（静默检查的出口）、「关于」页状态条、「跳过此版本」。
- 自动更新错误话术（2026-10-22 第四轮）：`Updater.httpMessage(code:url:)` 把 HTTP 404 / 403 / 401 翻成可操作中文。默认源指向尚未创建的 GitHub 仓库，404 是必然结果，只显示裸状态码等于让用户对着死胡同（SPEC §21）。
- 自动更新端到端闭环（2026-10-22 第五轮，真机实测）：检查 → 增量进度下载 → 解压 → bundle id 校验 → 替换 `/Applications/Smoose.app` → relaunch → 新版本运行，全链路通过。同轮修掉 `relaunch()` 里 `NSApp.terminate(nil)` 在无 NSApplication 上下文的崩溃（SPEC §21 D12）。
- 发布产出端：`./scripts/release.sh` 打 `dist/Smoose-<version>.zip`（顶层 `Smoose.app` + bundle id 校验 + 签名自检），`--github` 建 Release 并上传 asset。harness F 阶段独立复核这三条。

## 3. 架构与模块

```
滚轮 / 按键 HID 事件
   └─ CGEventTap(.cghidEventTap, .headInsertEventTap, .defaultTap)
         │  ScrollEngine.handle()  —— 判定来源 / 取值 / 回环防护 / 修饰键透传
         ▼
   ScrollAxis 状态机（每轴 target/current/sent）
         │  CVDisplayLink 每帧 advance(dt,τ)
         ▼
   CGEvent(scrollWheelEvent2Source:.pixel, magic=userData) → CGEvent.post(.cghidEventTap)
```

| 文件 | 职责 |
| --- | --- |
| `Sources/App.swift` | `@main` 入口：`MenuBarExtra` + `Settings` 场景；`AppDelegate` 负责安装 tap、启动指针控制、监听前台 App 切换、睡眠唤醒重设 HID、未授权引导、更新检查定时器 |
| `Sources/CursorZoom.swift` | 指针放大开关（2026-10-22 新增，见 §5  Dock 坑） |
| `Sources/Model.swift` | 配置模型：`ScrollProfile`（每轴参数+τ 公式+预设）、`StoredState`（持久化结构）、`Preferences`（`ObservableObject`，JSON 存 `UserDefaults` key=`smoose.state`，bundleID=`app.smoose.macos`） |
| `Sources/UpdateModel.swift` | 自动更新纯逻辑（SemVer / 清单解析，可离线编译） |
| `Sources/Updater.swift` | 自动更新运行时（检查 / 下载 / 解压 / 替换 / 重启；失败 1h 重试、跳过版本、增量进度、后台安装、bundle id 校验）；`httpMessage(code:url:)` 把 HTTP 错误码翻成可操作中文话术 |
| `scripts/release.sh` | 发布产出端：打 zip + 自检 + 可选 `--github` 发 Release 上传 asset |
| `Sources/ScrollAxis.swift` | 纯逻辑插值状态机（不依赖 AppKit，可离线 `swiftc` 单测）。核心 `advance(dt,tau)` |
| `Sources/ScrollEngine.swift` | 事件拦截 + `CVDisplayLink` 帧驱动 + 回环防护 + 失控兜底；`Monitor` 仅做界面展示 |
| `Sources/PointerController.swift` | 指针加速度控制（仿 LinearMouse）：枚举鼠标设备、记录基线、写回 HID 参数、6s 轮询、唤醒重设 |
| `Sources/Actions.swift` | 按键动作：用 `CGEvent` 合成快捷键或 `NSWorkspace` 打开 App |
| `Sources/Views.swift` | SwiftUI：`MenuBarPanel`、设置窗口（滚动 / 指针 / 按应用 / 按键 / 关于）、`OnboardingView`、`UpdateStatusView` |
| `Resources/Info.plist` | `LSUIElement=true`（菜单栏常驻）、`NSAccessibilityUsageDescription` |
| `build.sh` | 绝对路径 `swiftc -O -target arm64-apple-macos14.0`，产出 `build/Smoose.app` 并自签 |
| `Tests/InterpTest.swift` | 插值引擎离线验证（需 `cp` 成 `main.swift` 编译，见 §6） |
| `main.swift`（Sources/） | 纯 AppKit 入口：SwiftUI `App` 协议在 LSUIElement 下不激活，改用 `NSApplicationDelegate` 手动装 status item / popover / NSWindow |
| `Probe/main.swift` | 开发探针：枚举鼠标设备、读原始加速度、试写 0/163840/65536 并回读、还原 |

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
3. 私有 `sourceStateID`（`CGEventSource(stateID:.privateState).sourceStateID`， lazy 缓存），匹配 `F.stateID`（field 45）放行；
4. 失控兜底：单秒投递 `>40000px` 直接 `reset()` 两个轴。

> ⚠️ 改事件字段时务必同步 `F` 里的 `CGEventField(rawValue:)` 映射（11/12/93/94/96/97/99/123/88/42/45/41/3），
> 不同 SDK 头文件命名可能漂移，这里用 rawValue 锁死，不要改成 `CGEventField(rawValue:)` 之外的写法。

### 4.4 触控板判定（启发式）
`IsContinuous(field 88) || ScrollPhase(field 99) || MomentumPhase(field 123)` 任一非 0 即视为连续设备 → 透传。
个别第三方设备可能误判 → 关掉「忽略触控板」即可对该设备生效。

### 4.5 指针加速度（仿 LinearMouse，`PointerController`）
- 参数都是 IOFixed（16.16）：`HIDMouseAcceleration = 163840` → 2.5。
- **老路线 `IOServiceOpen(IOHIDSystem, kIOHIDServerConnectType)` 在现代 macOS 被拒（返回 `0xE00002BD`）**，必须走
  `IOHIDEventSystemClientCreateSimpleClient` + `IOHIDEventSystemClientCopyServices` + `IOHIDServiceClient*`。
- 每个设备的加速度存在哪个键由 `HIDPointerAccelerationType` 指定（外接鼠标=`HIDMouseAcceleration`，触控板=`HIDTrackpadAcceleration`）。
- 写回：`IOHIDServiceClientSetProperty(device.client, accelKey, NSNumber(value:Int(want)))`（注意返回 `Bool`，不要写 `!= 0`）。
- 开机/插拔后 6s 轮询重设；睡眠唤醒（`didWakeNotification`）强制重设。
- **`HIDPointerResolution`（指针速度）只能从 IORegistry 读到、写不回去** → 「指针速度倍率」在现代 macOS 上做不到，UI 已如实标注，只做加速度数值调节。

---

## 5. 配置格式（接手排查用）

- 持久化：`UserDefaults` 域 `app.smoose.macos`，key `smoose.state`，值为 `StoredState` 的 JSON。
- 注入测试配置（注意 value 必须是 `<data>` 包装的 JSON 字节，不是 `<string>`，否则 App 读不到）：
  ```bash
  # 用 plistlib 生成正确 <data> 再 defaults import，见仓库外 /tmp/inject_state.py（仅示例）
  defaults import app.smoose.macos - <<'PLIST'
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0"><dict>
    <key>smoose.state</key>
    <data>{...StoredState JSON...}</data>
  </dict></plist>
  PLIST
  ```
- 设备实测：用户机器检测到 **Razer DeathAdder 2013**（USB，5 键），加速度读写均通。

---

## 6. 构建与运行

```bash
cd Smoose
./build.sh                 # 产出 build/Smoose.app（绝对路径 swiftc，自包含）
cp -R build/Smoose.app /Applications/
# 首次运行 → 系统弹辅助功能授权 → 系统设置·隐私与安全性·辅助功能 勾选 Smoose
```

- 目标：`arm64-apple-macos14.0`，macOS 14+。
- `SWIFTC` 取 `/usr/bin/xcrun --sdk macosx --find swiftc`（Xcode 工具链，Swift 6.4）。
- 自签：`codesign --force --sign - --timestamp=none`（本机开发签名，换机器需重签或 Xcode 开跑）。

**已知行为坑（必读）**：
- 本 agent 沙箱禁止嵌套 `sandbox-exec`，Swift 宏（`@State` 等）展开所需 `swift-plugin-server` 无法启动，
  报 `SwiftUIMacros.StateMacro could not be found ... malformed response`。**这是运行环境限制，不是代码问题**。
  用普通终端 / Xcode 即可正常编译。
- Swift 化 C API（已踩过）：用 `CGEvent.tapCreate(...)` / `CGEvent.tapEnable(...)` / `CGEvent(scrollWheelEvent2Source:units:wheelCount:wheel1:wheel2:wheel3:)` /
  `event.setIntegerValueField(_:value:)` / `s.sourceStateID`，不要用 obsoleted 的 `CGEventTapCreate*` 旧名。
- 顶层语句测试：`Tests/InterpTest.swift` 需复制成 `main.swift` 再编译（否则 `expressions are not allowed at top level`）。

### 已知行为坑：Dock 图标粘住（2026-10-19）

- 不要在 `CursorZoomController` 里调用 `CGAssociateMouseAndMouseCursorPosition(0)`；
  会把鼠标与光标解绑，Dock 会把图标误判为拖拽目标（「粘住」）。
- `ScrollEngine.handlePointerMove` 只在真的改速度时才改写事件；接管加速度
  （`pointerAccelManaged=true`）时**不要**吞掉 `mouseMoved` 后重新合成投递，
  合成事件在 Dock 里同样会触发粘住和 hover 放大失效。原地改 delta 后放行即可。
- Dock / Finder 前台时完全不改写鼠标移动事件，原样放行。

离线验证插值器：
```bash
cp Tests/InterpTest.swift /tmp/smoose_test/main.swift
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
  - ~~指针「速度倍率」~~：已于 2026-10-07 通过 Event Tap 重写 mouseMoved delta 实现（见 SPEC §6）。
  - 输入法切换跟随等 Mos 附属功能。
- **启发式风险**：触控板判定靠 `IsContinuous/ScrollPhase/MomentumPhase`，个别第三方设备可能误判。
- **距离倍率基准**：绝对基准依赖各 App 自身的行距换算，这是 Mos 提供每应用配置的原因，本作同样支持。
- **签名**：当前为 ad-hoc 自签，分发到其他机器需重签或走 Xcode。

---

## 8. 接手 Checklist

- [x] `./build.sh` 编译通过并部署 /Applications（2026-10-07）
- [x] 实机验证：滚动接管（指数曲线/距离守恒）、指针速度 0.5/2.0x、签名授权保持。待用户日常使用中确认每应用和侧键手感。
- [x] `Probe/` 与 `Tests/` 保留（SPEC 布局表已收录，作为开发探针与离线回归）。
- [x] 签名：build.sh 用本机 Apple Development 证书（DR 绑定证书），换机器需要重新信任一次（换证书）或走 Xcode。
- [x] 自动更新第一轮（2026-10-22）：零依赖自建，harness §D 覆盖版本比较 / 清单解析 / 安装包地址抽取（含 GitHub `content_type` 无后缀 MIME 回归）/ 状态机闭环，PASS=5 FAIL=0。默认版本源指向 `cpufreestyle/Smoose` GitHub Releases（该仓库尚未创建，用户可先在「关于」页覆盖版本源）。已修两个真实缺陷：① 只匹配 `.zip` 后缀导致 GitHub 用户下载不到安装包；② 检查链路直接跳「立即重启」，`downloadAndInstall()` 无 UI 入口（现已改为停在「发现新版本 → 下载并安装 / 暂不更新」）。
- [x] 自动更新第二轮（2026-10-22 同日，实测驱动）：本地 HTTP feed + 真机重启链路验证通过（server 有 `GET /feed.json 200` 记录，进程未崩溃）。同轮修掉五个真实缺陷：① 静默检查只在 `interactive=true` 时置 `updateFound`，自动更新退化成手动更新；② 失败仍写 `lastCheck` 但间隔是 24h，断网一次就整天不再静默检查（改为失败 1h 重试）；③ 下载用 completion-handler 拿不到增量进度，百分比停在 0% 再跳完（改 `URLSessionDownloadDelegate`）；④ 解压替换在主线程，「正在安装」界面冻住（改后台队列）；⑤ 无 bundle id 校验，任意版本源可能覆盖成不相关 App；另补「跳过此版本」与菜单栏横幅。harness 补 D6 / D6b / D7 / D8 断言，SPEC §21 已同步。
- [x] **默认版本源已打通（2026-10-22 第六轮）**：仓库 `https://github.com/cpufreestyle/Smoose` 已创建为 **public**（private 仓库的 API 对不带认证的请求返 404，自动更新会直接失效），源码已推送，已发 v1.1.0 / v1.2.0 两个 Release，asset 为 `Smoose-<version>.zip`。实测 `GET /releases/latest` 200、真源码解出 `available(1.2.0)` + 下载地址、安装包 HTTP 200 可下载，整条链路真机跑通。
  - 后果：默认源对用户必然 404，所以 HTTP 错误必须给可操作话术而不是裸状态码。已实现 `Updater.httpMessage(code:url:)`：默认源 404 → 「还没有发布记录 + 去关于页填源」，自建源 404 → 「地址不存在」，403 → 限流提示，401 → 需要鉴权，其余显示状态码。端到端实测（真打 GitHub）确认 phase 变成带指引文案的 `.failed(...)`。
  - 用户想立刻用上自动更新：在「关于 → 自动更新」填自建 JSON 版本源即可，不必等仓库建好。
- [x] **建 GitHub 仓库并发 release（2026-10-22 第六轮已完成）**：`gh repo create cpufreestyle/Smoose --public` → 推源码 → `./scripts/release.sh --github --repo cpufreestyle/Smoose`。已发 v1.1.0 / v1.2.0。
- [x] 自动更新第六轮（2026-10-22，发布链路打通 + 修 release.sh 两个 bug）：前五轮把消费端做完了，但**没有版本源，自动更新永远推不到东西**——本轮把产出端也打通，并修掉两个只在真发 release 时才暴露的 bug。
  1. **建仓库 + 发 Release**：`gh repo create cpufreestyle/Smoose --public`（必须 public：App 的版本源请求不带认证，private 仓库 API 返 404），推源码，发 v1.1.0 / v1.2.0，asset 为 `Smoose-<version>.zip`。
  2. **修 `release.sh` 参数解析 bug**：`--repo owner/name` 里 `--repo` 分支是空的，value 原样留在 `"$@"` 里落到 `*)` 上 `exit 2`——**文档写的主用法从来没真正能用过**（实测 `./scripts/release.sh --github --repo cpufreestyle/Smoose` 直接报未知参数）。改成一次遍历解析，`--repo value` 和 `--repo=value` 都支持，value 缺失给明确错误。事后补救用的第二个循环也删了（它只认一种写法）。
  3. **修 `gh` 路径硬编码**：脚本写死 `/usr/bin/gh`，而 Homebrew 的 gh 在 `/opt/homebrew/bin`，一跑就 `no such file or directory: /usr/bin/gh`。改成 `command -v gh` 再退 `/opt/homebrew/bin` / `/usr/local/bin` / `/opt/local/bin`。
  4. **端到端实测（真实 GitHub 源，无任何 override）**：部署 1.1.0 → `updateFound("1.2.0")` → 增量进度下载 → 安装 → `readyToRelaunch` → `/Applications/Smoose.app` 变成 1.2.0。已是最新时正确报 `upToDate`。
  5. **harness 补 F2 stage**，`PASS=10 FAIL=0`。变异验证：把 `REPO_FLAG="$2"; shift 2` 改成只 `shift 2` → F2j FAIL（只查报错文案会被这种变体蒙混，必须直接断言赋值语句）；把 `"$GH"` 改回 `/usr/bin/gh` → F2g FAIL。
  6. 清理：推仓库前发现工作区里混进一个名为 `-` 的 1.1MB 截图（某次 `screencapture` 误建），已从提交里剔除并补 `.gitignore`（`build/` `dist/` `.build/` `logs/` `/-`）。
- [x] 自动更新第五轮（2026-10-22，端到端实测 + 修 relaunch 崩溃）：本轮把整条链路在真机上跑通，并修掉一个只在端到端才暴露的崩溃。
  1. **修 `relaunch()` 崩溃**：`NSApp.terminate(nil)` 里的 `NSApp` 是隐式解包全局 optional，在没有 `NSApplication` 的上下文里是 nil，直接调就 `Fatal error: Unexpectedly found nil`（端到端实测崩在这行）。改成 `if let app = NSApp { app.terminate(nil) } else { exit(0) }`。
  2. **端到端闭环实测通过**：本地 HTTP 版本源 + 真实签名的 1.2.0 安装包，跑通「检查 → 增量进度下载（0→100%）→ 解压 → bundle id 校验 → 替换 `/Applications/Smoose.app` → relaunch → 新进程以 1.2.0 运行」。`readyToRelaunch` 状态正确出现，`/Applications` 版本确实从 1.1.0 变成 1.2.0。
  3. **版本比较回归**：当前 1.2.0 / 1.2.1 / 1.3.0 对 feed 1.2.0 全部 `upToDate`，1.1.0 → `available`。
  4. **踩坑记录**：测试用的「假新版」不能靠 `plutil` 改 Info.plist 生成——那会让 `_CodeSignature` 与 Info.plist 不符，`codesign --verify` 报 `invalid Info.plist`，装上去 LaunchServices 直接 `Launch failed`。必须改版本号后重跑 `build.sh` 重新签名。
  5. **harness 补 G3 stage + D12/D13 断言**，`PASS=9 FAIL=0`。变异验证：把 `Self.terminateSelf()` 改回 `NSApp.terminate(nil)`，G3 如预期 FAIL（G32/G36），改回恢复 PASS。
  6. 测试残留已清：卸载 `com.smoose.e2efeed` LaunchAgent、清 `smoose.update.feed` / `lastCheck` / `lastCheckFailed`，默认版本源恢复生效。
- [x] 自动更新第四轮（2026-10-22，harness 假绿修复 + 404 话术）：本轮**没有加新功能，而是修「测试全绿但真机是坏的」这个更危险的问题**。
  1. **修掉 D stage 的 FIFO 假绿（本轮最重要）**：D stage 判断断言结果用的是 `[ ! -s <(grep '^FAIL' "$WORK/d.out") ]`。进程替换 `<( )` 产出的是 FIFO，而 zsh 的 `-s` 在写端 flush 之前就完成判断，**永远返回「空」**——于是 D 的断言哪怕全 FAIL 也照样报 PASS。已实测复现：把 D 的一条断言改成错的，屏幕打出三条 `FAIL D10x` 却仍输出 `PASS=8 FAIL=0`。改成把 grep 结果收进变量再判断，并让 D 二进制自己 `exit(1)`（与 G 一致，不依赖解析输出文本）。
  2. **修掉一条写反的断言**：假绿修好后立刻暴露 `require(decide(... {"name":"Smoose 1.5.0"} ...) == .available("1.5.0"))` 是错的——`SemVer(string:"Smoose 1.5.0")` 解析不出来，真源码（已实测）正确判 `malformed`。这条断言与真源码行为相反，却因为假绿一直「通过」。已改为 `.malformed`，并补一条 `{"name":"1.5.0"}` → `.available("1.5.0")` 覆盖 `name` 兜底的正路。
  3. **修掉 `require()` 的假 label**：默认参数 `#file + ":" + #line` 在**声明处**求值，所以任何不显式带 label 的断言失败时都打印 `d.swift:6`（`require` 函数自己那一行），完全看不出是哪条挂了。已给 D 全部 33 条断言补上可读 label（版本号 / JSON 摘要）。
  4. **补 D10 版本源 HTTP 错误话术**（本轮唯一的功能修复）：默认版本源指向不存在的 GitHub 仓库，404 是必然结果，而此前只显示「版本源返回 HTTP 404」，用户完全不知道该干什么。新增 `Updater.httpMessage(code:url:)`，按「是否默认源」分流给可操作中文话术（404 / 403 / 401 / 其余）。
  5. **补 G2 反 drift**：`Updater.swift` 依赖 AppKit + `Preferences` + `UpdateManifest`，编不出可执行断言，D10 只能是逻辑副本。G2 用文本守卫确认真源码里真的存在 `httpMessage` 且按错误码分支。
  6. **变异验证**（四组全过）：① 删真源码 `Asset.CodingKeys` → G FAIL（G1/G2/G3）而 D 仍绿，证明副本确实会掩盖漂移；② 改真源码 `httpMessage` 函数名 → E+F+G2 一起 FAIL；③ D 副本 404 文案退回裸状态码 → D FAIL（D10）；④ `SemVer` 比较方向改反 → D FAIL（D-1.2.10）。全部改回后 `PASS=8 FAIL=0`。
  7. **端到端实测**：真打 GitHub 默认源，phase 变成 `failed("默认版本源还没有发布记录：官方仓库尚未创建或未发过 Release。请先在「关于 → 自动更新」里填一个可用的版本源地址，或等首个 Release 发布。")`。已重新构建部署 `/Applications/Smoose.app`（1.1.0，签名有效）。
  8. **文档同步**：SPEC §7 阶段表加 G2 行、用法改为 `A B C D E F G G2`；§21 断言清单补 D9 / D9e / D10 / G / G2 与「假绿守卫」条目、D8 的 `PASS=5` 更新为最新；HANDOFF 更正上一轮写错的 404 结论。
- [x] 自动更新第三轮（2026-10-22，产出端补齐 + 残留清理）：① harness 补 F 阶段，独立复核发布包三条硬要求（顶层 `Smoose.app` / bundle id / 签名），并做变异验证（bundle id 改成 `app.smoose.WRONG` 后 F 如预期 FAIL，改回恢复 PASS），`PASS=6 FAIL=0`；② 清掉测试残留：卸载 `~/Library/LaunchAgents/com.smoose.testfeed.plist`、删除 `/tmp/smoose_feed`、清 `smoose.update.feed` / `lastCheck` / `skipped` 等 UserDefaults key，现在默认版本源已生效；③ SPEC §21 断言清单补 F 与 D8 编号、HANDOFF 文件表补 `scripts/release.sh`。
- [ ] 署名合规：本项目仅学习自用，未包含 Mos 任何源码；Mos 原作 MIT © Caldis。

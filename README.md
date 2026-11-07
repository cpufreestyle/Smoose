# Smoose

一个仿 [Mos](https://github.com/Caldis/Mos)（公认最好的 macOS 鼠标滚动增强工具）的原生菜单栏 App：
把鼠标滚轮的"一格一跳"重建成触控板那样的连续滚动曲线。原生 Swift，无第三方依赖。

## 下载安装

到 [Releases](https://github.com/cpufreestyle/Smoose/releases/latest) 下载 `Smoose-<版本>.zip`，
解压后把 `Smoose.app` 拖进「应用程序」文件夹即可。已装旧版的用户直接在
App 内「关于 → 检查更新」自动升级；覆盖安装保留辅助功能授权，无需重新授权。
每个 Release 页面都附有变更说明与安装包 sha256，可自行核对。

## 功能

| 功能 | 说明 |
| --- | --- |
| 平滑滚动 | HID 层拦截 `scrollWheel`，按显示刷新率（ProMotion 可达 120Hz）插值重建滚动曲线 |
| 距离倍率 | 0.2×–8×。≈4× 接近 Chrome/Safari 原生行滚动距离，≈1.5× 接近原生 AppKit 控件 |
| 顺滑度 | 0–1，映射为指数插值时间常数 τ（0.006s ~ 0.27s） |
| 最小步长 | 低于此值的微推会被放大，避免轻推无反应 |
| 双轴独立 | 垂直 / 水平各自独立开关平滑与方向反转 |
| 忽略触控板 | 触控板与 Magic Mouse 的连续滚动默认原样透传 |
| 每格行数 | 只作用于离散滚轮鼠标，不影响触控板连续滚动 |
| 每应用配置 | 按 bundle id 单独配置，或从「预设」一键套用（默认 / 干脆 / 丝滑 / 浏览器 / 原生 App / 聊天软件 / 跳过此 App）。套预设只改曲线参数，不会清掉你自己配的加速键；微信 / QQ / Slack / Discord / Teams 新建规则时自动套「聊天软件」档 |
| 修饰键透传 | 按住 ⌘⌥⌃⇧ 等修饰键时跳过接管、原样透传（精确操作场景） |
| 滚轮加速 | 按住 ⌘⌥⌃⇧ 等指定修饰键时临时放大滚动倍率（1.2×–10×），松开立刻恢复，平滑尾巴自然收拢；对标 Mos Scroll Boost。与「按住透传」配同一个键时会橙色警告（同键时透传优先，加速不生效） |
| 曲线预览 | 设置页与菜单栏实时绘制 0–500ms 归一化位移曲线及 95% 到位耗时，调参手感直观可见 |
| 按键绑定 | 中键与侧键 3/4/5 绑定到调度中心、启动台、⌘⇥、显示桌面、浏览器前后、切换桌面、截图面板等；支持前后键互换、抬起时触发、按应用单独绑定 |
| 原生轻扫手势 | 侧键「前进 / 后退」优先投递原生触控板轻扫手势（Safari/Chrome/Finder 平滑跟手翻页），替代 Cmd+[ / Cmd+]，不再与文本输入框光标冲突 |
| 指针加速度 | 直接改写 IOHIDSystem 的 HID 参数（等价于 LinearMouse 核心能力），线性模式写 -1 + 启用线性缩放；仅写 0 不会关闭加速曲线。只作用于外接鼠标，内建触控板由系统管理 |
| 指针速度倍率 | Event Tap 原地改写 `mouseMoved` 的 delta（`HIDPointerResolution` 在现代 macOS 不可写，所以不走 HID） |
| 光标放大 | 写入系统「摇动鼠标指针以定位」偏好并把生效条件说清楚：macOS 只在登录时加载该偏好，需重新登录或到系统设置里手动切换一次才生效；写后独立读回校验，失败回弹不假绿 |
| 罗技硬件直控 | 纯 Swift 原生 HID++ 2.0 `0x2201`：先向设备查询 feature，再按**设备回报的真实范围**生成 DPI 档位（本机 100–25600、步进 50），写入后读回确认，失败明确报错；无需常驻 Logi Options+ |
| 窗口自适应 | 设置窗口可拖拽调整大小，页面内容（字号 / 间距 / 控件）随之等比放大，2× 封顶；菜单栏弹窗宽随内容 |
| 开机启动 | SMAppService 登录项 |
| 权限自愈 | 授权被撤销自动停 tap，恢复后自动重建；菜单栏绿点 = 已授权，红点 = 未授权 |
| 自动更新 | 版本源拉取 → SemVer 比较 → 增量进度下载 → **签名校验** → 替换重启，零第三方依赖。菜单栏面板实时显示下载进度 / 安装中 / 已就绪待重启，装完不丢重启入口 |

## 首次使用

1. 打开 App → 系统弹出**辅助功能**授权 → 到「系统设置 → 隐私与安全性 → 辅助功能」勾选 Smoose
2. 授权后菜单栏图标变为绿点，实时生效，无需重启
3. 先用鼠标滚一页，对照下面的参数微调到手感合适

菜单栏绿点 = 已授权；红点 = 未授权。

## 参数怎么调

- **整体太慢 / 太快** → 调「距离倍率」。浏览器里觉得比原生慢就往上加到 4× 左右。
- **感觉黏、跟不上手** → 调低「顺滑度」（0.1 左右 ≈ 干脆、几乎瞬时）。
- **感觉太飘、停不下来** → 调低「顺滑度」或提高「最小步长」。
- **某个 App 就是不对**（比如终端、Excel）→ 到「每应用」给它单独配一组参数，或选「跳过此 App」。

## 技术实现

```
滚轮 HID 事件 ──▶ CGEventTap(cghidEventTap, headInsert, defaultTap)
                     │  判断来源：IsContinuous / ScrollPhase / MomentumPhase → 触控板则透传
                     │  取值：触控板用 fixedPt(16.16 像素)，鼠标用 pointDelta（系统自己的 line→px 换算）
                     ▼
              ScrollAxis 状态机  target / current / sent
                     │  CVDisplayLink（跟随屏幕刷新）每帧：
                     │  current += (target − current) × (1 − e^(−dt/τ))
                     │  投递 trunc(current − sent)，不足 1px 的小数累积到下一帧
                     ▼
              CGEvent(scrollWheelEvent2Source: units:.pixel) → CGEventPost(cghidEventTap)
```

三个关键工程细节：

1. **回环防护**：自己投递的事件用 `eventSourceUserData` 魔法值 + 私有 sourceStateID + pid 三重标记，
   在 tap 中识别并放行；另加「单秒投递 > 40000px 即清空队列」的失控兜底。
2. **距离守恒**：亚像素余数跨帧累积，到位时把 ≥0.5px 的尾量结清，保证最终滚动距离 = ∑(原始 delta × 倍率)，
   离线测试 1/20/60 格场景误差为 0。
3. **跟手性**：默认 τ≈0.059s，在 120Hz 下 90% 行程约 142ms（触控板量级）；60Hz 屏幕约 133ms，曲线自动适配 dt。

## 构建

```bash
cd Smoose
export SMOOSE_SIGN_ID="Apple Development: 你的名字 (TEAMID)"   # 可选，见下方说明
./build.sh            # 产出 build/Smoose.app

# ⚠️ 不要用 cp -R：目标已存在时会把新包拷进旧包里面，变成
#    /Applications/Smoose.app/Smoose.app，签名校验会报 unsealed contents
/usr/bin/ditto --noqtn build/Smoose.app /Applications/Smoose.app.new
/usr/bin/find /Applications/Smoose.app -mindepth 1 -delete
/usr/bin/ditto --noqtn /Applications/Smoose.app.new /Applications/Smoose.app
/usr/bin/codesign --verify --deep --strict /Applications/Smoose.app
```

**签名身份三级回退**：① 环境变量 `SMOOSE_SIGN_ID`（换机器 / 换账号时用）→ ② 自动探测钥匙串里的
Apple Development 证书（默认路径）→ ③ ad-hoc 并打印警告。
落到第 ③ 档时每次 cdhash 都变，**辅助功能授权会在每次重新编译后失效**，且会被发布自检拒绝。

**在 CI / 受限沙箱里构建**：Swift 宏展开需要 `swift-plugin-server`，而它自己要套 `sandbox-exec`，
在已经禁止嵌套沙箱的环境里会报 `SwiftUIMacros.StateMacro ... malformed response`。
这种环境用 `SMOOSE_SWIFT_EXTRA=-disable-sandbox ./build.sh`（`run_tests.sh` 同理）。普通终端不用设。

源码 15 个文件：`main.swift`（纯 AppKit 入口）、`App.swift`（AppDelegate / 状态栏 / 窗口自愈）、
`Views.swift`（界面）、`Model.swift`（配置模型）、`ScrollAxis.swift`（插值引擎，纯逻辑）、
`ScrollEngine.swift`（事件拦截 + 帧驱动 + 指针速度）、`PointerController.swift`（HID 指针加速度）、
`Actions.swift`（按键动作）、`CursorZoom.swift`（光标放大）、`Updater.swift` + `UpdateModel.swift`（自动更新）、
`LogitechHIDPP.swift`（罗技 HID++ 直控）、`TouchEvents.c/h`（原生轻扫手势投递）+ `IOHIDEvent*.h`（私有头）。

### 一键验证（harness）

```bash
./run_tests.sh                                        # 离线，PASS=59 FAIL=0
SMOOSE_SWIFT_EXTRA=-disable-sandbox ./run_tests.sh    # 受限环境（CI / agent 沙箱）
```

| 段 | 验什么 |
| --- | --- |
| A | 插值与距离守恒 |
| B | 每应用命中 |
| C | 按键动作枚举 |
| D | 自动更新决策 |
| E | 构建签名 |
| G / G2 / G2b / G2c / G3 | 反 drift：`UpdateModel` 真源码 / `httpMessage` / upToDate 可见反馈 / 限流与弱网韧性（ETag / 续传 / 锁）/ `relaunch` 退出路径 |
| F / F2 | 发布产出端 zip 自检 / `release.sh` 参数与 `gh` 路径解析 |
| H | 更新链路安全加固：HTTPS 强制 / sha256 / TeamIdentifier 比对 / 按拒因断言 + Mach-O 级前置自检（编译真源码） |
| S / S18–S39 | 滚轮加速与曲线 / 预设与滑条同源 / 罗技事件驱动 / 游戏页 / 合成事件相位 / 点击刹车 / 接线守卫 |
| **I** | **加速度接管签名对 HID 参数漂移敏感（14 项，编译真 `PointerController.swift`）**：系统把 `HIDMouseAcceleration` 改掉后必须能发现并重写（防御兜底，非「起步发黏」根因） |
| **J / J_W / J_MUT** | 窗口放大等比联动 / 六页接线守卫 / 恒 1× 变异验证 |
| **K / K_W / K_MUT / K_MUT2** | **关闭加速语义（20 项）**：线性 = -1 + 线性缩放标志、签名含标志、硬件不支持时回退、全局默认基线；两趟变异验证 |
| **L / L_W / L_MUT / L_MUT2** | **HID++ 0x2201 真实 DPI（30 项）**：设备字节解析（100–25600 / 步长 50 / 当前 5400）、`0x38` 报文、写后读回校验与五类拒因；两趟变异验证 |
| **M / M_W / M_MUT / M_MUT2 / M_MUT3** | **内建触控板隔离（16 项）**：恒不参与加速度写入、跳过项必须可见且不参与 `allOK`、只有触控板不能报绿；三趟变异验证 |
| **N / N_W / N_MUT / N_MUT2 / N_MUT3** | **硬件 DPI 快捷键自动同步（23 项）**：非独占只读长连接、失败不吞 / 写入竞态、状态文案明确「未回写硬件」、无 App 前台门禁；三趟变异验证 |
| **O / O_W / O_MUT / O_MUT2 / O_MUT3** | **系统设置跳转（14 项）**：新 PrivacySecurity 扩展 ID、completionHandler 接住失败、失败反馈含原因 / 重试 / 手动路径；三趟变异验证 |
| **P / P_W / P_MUT / P_MUT2 / P_MUT3 / P_MUT4** | **光标放大（31 项）**：反相映射、写后独立读回、失败回弹、「待重新登录」文案、冷启动两步直达 Display 页；四趟变异验证 |

（上表是主要阶段；完整执行顺序以 `run_tests.sh` 输出的 `== X:` 为准，当前 `PASS=59 FAIL=0`。）

改引擎 / 持久化 / 自动更新 / **指针加速度**代码后必须跑一遍，全部 PASS 才算完成。
契约与断言清单见 [SPEC.md](SPEC.md)；关键坑与真机验证记录见 [HANDOFF.md](HANDOFF.md)。

> **没有 `--device` 选项**。指针速度改写这条链路在当前环境下没有可靠的真机断言载体
> （CLI 装 tap 拿不到辅助功能信任、产物 strip 过符号、dylib 注入起不来），
> SPEC §7 里早期列过它但从未实现 —— 只能人工验证：开「指针速度倍率」→ 移动鼠标 → 手感是否随倍率变化。

⚠️ 两条写 harness 时踩过的坑：

- **断言 stage 必须用 `-Onone`**：stdlib `assert()` 在 `-O` 下被整条优化掉（实测 `assert(1==2)` 在 `-O` 下 exit 0），所以一律用自建 `require()` 计数 + 非零退出。
- **别用 `[ ! -s <(grep ...) ]` 判断断言结果**：进程替换出来的是 FIFO，zsh 的 `-s` 在写端 flush 前就判断，永远返回「空」，断言全 FAIL 也照样 PASS。必须先把 grep 结果收进变量。

离线验证插值器：

```bash
cp Tests/InterpTest.swift /tmp/smoose_test/main.swift
swiftc -O -sdk $(xcrun --sdk macosx --show-sdk-path) -target arm64-apple-macos14.0 \
  -o /tmp/smoose_interp Sources/ScrollAxis.swift /tmp/smoose_test/main.swift
/tmp/smoose_interp
```

## 自动更新

零第三方依赖（不引 Sparkle：项目没有 appcast、没有 EdDSA 签名链，引了只会得到一个永远验证不过的更新器）。

版本源默认走 GitHub Releases，发布只需：

```bash
./scripts/release.sh --github --repo cpufreestyle/Smoose
```

脚本会构建 → 打包 `dist/Smoose-<version>.zip` → 自检（顶层 `Smoose.app` / bundle id / 签名 / **TeamIdentifier**）→ 发 Release 并上传 asset。
仓库必须是 **public**：App 拉版本源不带认证，private 仓库的 API 会返 404。
同时产出 `dist/Smoose-<version>.json`（带 sha256），可直接自托管当版本源。

用户也可在「关于 → 自动更新」里填自建 JSON 版本源（`sha256` 可选，给了客户端就会校验）：

```json
{"version":"1.3.0","url":"https://example.com/Smoose.zip","sha256":"<小写的 64 位十六进制>","notes":"...","minSystem":"14.0"}
```

### 更新链路的安全约束

App 持有辅助功能权限（能监听并合成全局输入），所以「自动更新」等价于远程代码执行入口。客户端强制四道关：

1. 版本源与下载地址都必须是 **https**（`http://localhost` / `127.0.0.1` / `::1` 例外，留给自测）
2. 版本源给了 `sha256` 就先校验，不匹配直接中止
3. 解压后 `codesign --verify --deep --strict`
4. 比对 `TeamIdentifier` 与 `Updater.expectedTeamIdentifier`（当前 `6U2DQJ6Z2N`）；拷贝到 `/Applications` 后再验一次，失败回滚原版

> 注意：`TeamIdentifier` **不等于**签名身份 CN 括号里那串。本机用
> `Apple Development: qm0819@hotmail.com (5F66DDWD6H)` 签名，`codesign` 报的却是 `6U2DQJ6Z2N`。
> fork 请改 `Updater.expectedTeamIdentifier`，或在 Info.plist 里加 `SmooseUpdateTeamID` 覆盖。

## 与 Mos 的差异 / 已知限制

- 核心体验：滚动平滑重建、滚轮加速（Scroll Boost，1.4.0）、曲线预览（1.4.0）、每应用独立调校、修饰键临时透传均已对齐 Mos。
- 硬件与侧键：Logitech HID++ 硬件 DPI 直控已实现（1.3.0）；侧键走 macOS 标准 HID 路径（button 3/4/5）支持 13 种原生动作与每应用覆盖，罗技主流型号（如 G502 X、MX 系列等）插上即用，无需依赖厂商私有后台。
- 附属功能差异：输入法切换跟随（Mos 附属特性）不在本核心鼠标增强范围内，保持不实现。
- 触控板判定走 `IsContinuous`/`ScrollPhase`/`MomentumPhase` 启发式，个别第三方设备可能误判 → 关掉「忽略触控板」即可对该设备生效
- 「距离倍率」的绝对基准依赖各 App 自己对滚轮的行距换算，这也是 Mos 提供每应用配置的原因；本作同样支持
- 署名：仅做学习与自用，Mos 原作 MIT 协议 © Caldis。本项目未包含 Mos 任何源码。

## 设置窗口缩放 / 本地调试

拖动设置窗口边缘放大时，整页内容会等比放大（最多 2×），标签栏保持系统原生尺寸；
只拉宽不拉高时字号不变、内容横向铺开，避免把纵向内容裁掉。

无 UI scripting 权限的环境里，可用 URL scheme 脚本化设定窗口尺寸来验证缩放：

```bash
open "smoose://settings?tab=about&w=1080&h=900"
```

`w` / `h` 为点数，只接受 300…4000，非法值忽略；可与 `?tab=about` 等直达参数并用。
设计基准 `SettingsLayout.baseWidth/baseHeight = 560/620`，620 是「关于」页完整内容高度。

## 指针线性模式

「接管并提供线性追踪」开启、加速度数值为 0 时，Smoose 写的是 **-1（IOFixed -65536）**，
并尝试启用 macOS Sonoma+ 的 `HIDUseLinearScalingMouseAcceleration`；两者合起来才是 1:1 线性。
**只把数值写成 0 不会关闭系统加速曲线**（0 = 最小加速度，低速仍发黏）。

部分设备（例如本机罗技 USB Receiver）不暴露线性缩放键：写入回显成功、读回仍是 null。
此时按 LinearMouse 的 `supportsLinearPointerScaling` 语义回退到只靠 -1，属正常状态，
指针页会显示「线性标志 不支持(回退 -1)」，不算写入失败。

内建触控板（`Built-In` / FIFO 设备）**不参与加速度接管**：本机实测写 -1 读回 0，
线性缩放键也不支持，所以旧开关「同时应用到内置触控板」已移除（仅保留旧存档兼容字段）。
状态区会明确列出「内建触控板由系统管理（不写入加速度）」—— 它既不算成功也不算失败，
不会再把整段状态标红。外接鼠标 / 接收器照常接管。

可用下面的命令精确核对（**不要**不加 `--matching`，否则列的是全部 HID 服务，容易被误判）：

```bash
hidutil property --matching '{"PrimaryUsagePage":1,"PrimaryUsage":2}' --get HIDMouseAcceleration
hidutil property --matching '{"PrimaryUsagePage":1,"PrimaryUsage":2}' --get HIDUseLinearScalingMouseAcceleration
```

「恢复系统默认」会把加速度还原到 `IOHIDSystem.HIDParameters` 里的系统默认（通常 2.5），
而不是 App 启动时的设备读数。

## 罗技 HID++ DPI 档位

「指针」页的罗技专属区会先向设备查询 `0x2201`（Adjustable DPI）能力，
**档位完全来自设备回报**，不再写死 400…3200。本机罗技接收器实读结果是
100–25600 DPI、步进 50、当前 5400、默认 1600，所以 Picker 里会有 25600。
两个接收器里只有一个支持该 feature（另一个返回 index 0），不支持时会明确写原因，
**不显示档位也不下发写入**。

选好档位要点「应用」才写入；Smoose 会检查报文是否被接受、设备回显，并再读一次当前 DPI，
只有读回值等于目标值才显示「已应用…（读回确认）」，否则显示具体失败原因。

协议细节与不可回退契约见 `SPEC.md` §29，真机探针与部署记录见 `HANDOFF.md` §4.9；
内建触控板隔离契约见 `SPEC.md` §30 / `HANDOFF.md` §4.10。

## 硬件 DPI 快捷键切换自动同步

指针页可见时保持一条**非独占** HID++ 长连接，300ms 读一次 `GET_SENSOR_DPI`；
0x2201 没有 DPI 变更通知，只能主动读。Smoose **只更新显示、绝不回写硬件**：
界面会明确显示「鼠标快捷键切换 DPI → 14700 DPI（已同步显示，未回写硬件）」。
同步不因 App 失活而暂停（DPI 键恰恰在 Smoose 不是前台时按），写入 / 重新探测前先停连接。
真机验收：5400 → 14700，重启后仍一致，独立探针复读硬件真值确认未被回写。
契约见 `SPEC.md` §31 / `HANDOFF.md` §4.11。

## 首次授权 / 系统设置跳转

旧地址 `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`
在 macOS 27.3 会落到「Device Control and Data Access」，已改用
`com.apple.settings.PrivacySecurity.extension` 打开「隐私与安全性」，
再点「辅助功能」勾选 Smoose 即可。

如果系统设置进程卡死（报 `You can't open the application "System Settings" because
it is not responding.` / `open` 返回 `-1712`），这是 macOS 自身状态，
`killall "System Settings"` 后重试即可；Smoose 会用 completionHandler 接住失败，
显示带具体原因的中文提示 + 「重试」+ 手动路径，不再只弹英文系统框。
本地诊断入口 `open smoose://onboarding`（不动 TCC 授权即可复测引导页）。
契约见 `SPEC.md` §32 / `HANDOFF.md` §4.12。

## 光标放大开关（为什么「开启」不等于「生效」）

`CGDisableCursorLocationMagnification` 是系统自带的「摇动鼠标指针以定位」偏好键，
语义反相（功能开 → 键为 false）。真机确认键没写错，但 **macOS 的 WindowServer
只在登录会话启动时加载它**：第三方只写 plist 后，系统设置里的开关都不会刷新，
摇动鼠标也不会放大。Apple 社区资料从 El Capitan 起就明确要注销 / 重启。

所以 Smoose 现在：写入后用 `CFPreferencesCopyValue` **独立读回**校验，
失败会让开关回弹并显示带具体原因的红字 + 重试；写入成功也会明确显示
「已写入系统偏好 ✓ 但 macOS 只在登录时加载它，需重新登录才生效」，
不再把开关变蓝当作功能已生效。

想立刻生效，点「在系统设置里打开」（两步法冷启动直达「辅助功能 → 显示」页），
把 `Shake mouse pointer to locate` 关一次再打开即可。
契约见 `SPEC.md` §33 / `HANDOFF.md` §4.13。

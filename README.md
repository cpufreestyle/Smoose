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
| 每应用配置 | 按 bundle id 单独配置，或从「预设」一键套用（默认 / 干脆 / 丝滑 / 浏览器 / 原生 App / 聊天软件 / 跳过此 App） |
| 修饰键透传 | 按住 ⌘⌥⌃⇧ 等修饰键时跳过接管、原样透传（精确操作场景） |
| 滚轮加速 | 按住 ⌘⌥⌃⇧ 等指定修饰键时临时放大滚动倍率（1.2×–6×），松开立刻恢复，平滑尾巴自然收拢；对标 Mos Scroll Boost |
| 曲线预览 | 设置页与菜单栏实时绘制 0–500ms 归一化位移曲线及 95% 到位耗时，调参手感直观可见 |
| 按键绑定 | 中键与侧键 3/4/5 绑定到调度中心、启动台、⌘⇥、显示桌面、浏览器前后、切换桌面、截图面板等；支持前后键互换、抬起时触发、按应用单独绑定 |
| 原生轻扫手势 | 侧键「前进 / 后退」优先投递原生触控板轻扫手势（Safari/Chrome/Finder 平滑跟手翻页），替代 Cmd+[ / Cmd+]，不再与文本输入框光标冲突 |
| 指针加速度 | 直接改写 IOHIDSystem 的 HID 参数（等价于 LinearMouse 核心能力），0 = 线性无加速 |
| 指针速度倍率 | Event Tap 原地改写 `mouseMoved` 的 delta（`HIDPointerResolution` 在现代 macOS 不可写，所以不走 HID） |
| 指针放大 | 开关系统光标放大 |
| 罗技硬件直控 | 纯 Swift 原生 HID++ 2.0 协议：自动检测 USB 接收器 / 蓝牙连接的罗技鼠标，直接读写硬件传感器 DPI（400–3200），无需常驻 Logi Options+ |
| 窗口自适应 | 设置窗口可拖拽调整大小，放大后内容跟随拉伸；菜单栏弹窗宽随内容 |
| 开机启动 | SMAppService 登录项 |
| 权限自愈 | 授权被撤销自动停 tap，恢复后自动重建；菜单栏绿点 = 已授权，红点 = 未授权 |
| 自动更新 | 版本源拉取 → SemVer 比较 → 增量进度下载 → **签名校验** → 替换重启，零第三方依赖 |

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
./run_tests.sh        # A B C D E G G2 G2b G2c G3 F F2 H 十三段，离线
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
| H | 更新链路安全加固：HTTPS 强制 / sha256 / TeamIdentifier 比对 / 按拒因断言 + Mach-O 级前置自检（25 条断言，编译真源码） |

（上表是**实际执行顺序**；按字母念的规范顺序是 A B C D E F F2 G G2 G2b G2c G3 H。）

改引擎 / 持久化 / 自动更新代码后必须跑一遍，全部 PASS 才算完成。契约与断言清单见 [SPEC.md](SPEC.md)。

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

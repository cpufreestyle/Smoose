# Smoose — 项目交接文档（HANDOFF）

> 仿 [Mos](https://github.com/Caldis/Mos)（公认最好的 macOS 鼠标滚动增强工具）的原生菜单栏 App。
> 把鼠标滚轮的「一格一跳」重建成触控板那样的连续滚动曲线，并附带指针加速度 / 速度控制（LinearMouse 那一半）。
> 原生 Swift，零第三方依赖。
>
> 本文档面向接手维护的开发者，记录架构、能力、关键坑、构建方式与未决项。
>
> **2026-11-15 反编译审计轮（用户「反编译 优化*项目*」→ 修复单帧距离丢失 + 加入斜向锁定；PASS=104 FAIL=0，未发版）**：
> 本轮对 Smoose 自己的构建产物跑了 REA，不抽取闭源收费应用的源码，也不把第三方二进制实现搬进项目；
> 反编译只用于确认自有二进制里的类型/符号与调用边界，行为优化仍以公开算法和独立实现为准。
> REA 报告：`/tmp/smoose-rea/re-Smoose.md`（临时取证文件，不作为仓库依赖）。
> **根因**：`ScrollAxis.advance` 单帧输出上限是 512px。旧实现先执行 `sent += whole`，再把返回值截到
> ±512；当一帧应投递超过 512px（高倍率/大滚动量）时，超出部分已经记入 `sent`，后续帧永远不会补发。
> 离线复现「巨大单格 2000px」：预期 4800px，修复前实际 2112px，偏差 2688px。
> **修复**：先在 `Sources/ScrollAxis.swift` 把本帧输出夹紧到 ±512，再只把实际输出记入 `sent`；
> 余量留在 `current - sent`，下一帧继续投递。普通 1/20/60 格场景的总距离不变。
> **追加优化**：新增纯逻辑 `ScrollAxisLock`（`Sources/ScrollAxis.swift`）：当较小轴不足较大轴的
> `axisLockThreshold` 时丢弃较小轴，抑制触控板 / 高分辨率滚轮带出的横向抖动；默认 **0 = 完全关闭**，
> 真正的斜向滚动不受影响。全局「轴向与方向」和每应用「细节参数」都提供「斜向锁定」滑条，
> 旧配置缺键时解码为 0。该设计只借鉴公开的交互语义，不复制第三方源码。
> **回归**：`Tests/InterpTest.swift` 新增 2000px 单格场景；全量
> `SMOOSE_SWIFT_EXTRA=-disable-sandbox ./run_tests.sh` → **PASS=104 FAIL=0**（退出码 0，
> 新增 A2 阈值 / 双轴 / 负号 / 边界断言）。
> 构建 `SMOOSE_SWIFT_EXTRA=-disable-sandbox ./build.sh` RC=0，Mach-O sha256
> `7e5ecc32bc6b0bc119da79af0d614303fed7fef8177e7531d6a32ce1617f1e39`，`codesign --verify --deep --strict`
> 通过、`TeamIdentifier=6U2DQJ6Z2N`。已 ditto 到 `/Applications/Smoose.app` 并重启（pid 70747，
> 1.5.0 / build 14）；旧包备份在 `docs/backups/Smoose.app.prev-1.5.0-20261115_222651.app`。
> **未发版；代码与文档提交 `61215e3` 已推送到 GitHub `main`（远端基线 `fa8d16c`，快进推送）。**
> 线上仍是 v1.5.0。下一轮若要继续对照收费应用，只做公开行为/接口差异，不复刻内部源码。
>
> **2026-11-15 易用性 P0（用户「继续」→ 首屏状态条 + 一键诊断 + 简易/高级模式；PASS=104 FAIL=0，未发版）**：
> ① 常规页顶部新增四格状态条：辅助功能 / 滚动接管 / 指针设备 / 当前 App；异常项点一下直接跳到对应标签页，
> 不再让用户在六页设置里找原因。② 关于页新增「复制诊断报告」与「重新检测」：诊断文本由纯函数
> `HealthStatus.report` 生成，包含权限、事件 tap、当前 App 专属规则、指针设备数、最近滚动来源与回环计数；
> 重新检测会重新校验权限、补建 tap、刷新 PointerController 与 HID++。③ 常规页新增「简易 / 高级」分段：
> 简易模式只保留总开关、输出方式、常用曲线、预设和开机；高级模式才显示曲线细节、轴向、透传和按住加速。
> ④ 「按应用」新增预设立场：顶部可选「自动识别」或手动模板；自动识别覆盖聊天、浏览器、终端 / 编辑器保守白名单，
> 手动选择优先；新增后每行还有「套用预设模板」菜单，未知 App 仍沿用全局。
> UI 真机截图确认状态条与模式切换没有挤坏六页标签；全量 harness 仍为 **PASS=104 FAIL=0**，构建
> `7e5ecc32bc6b0bc119da79af0d614303fed7fef8177e7531d6a32ce1617f1e39`，部署 pid 70747。
> **未发版；代码提交 `61215e3` 已推送到 GitHub `main`，本次交接更新随后提交并推送。**
>
> **2026-11-14 状态（已发版 v1.5.0）**：下面这段「11-14 状态核对 + v1.5.0 设计方向」是
> 当天早间的快照，**已被当天下午的两次发布动作覆盖**，读现状请看下面「第四十轮」。
> 一句话现状：线上 `/releases/latest` = **v1.5.0**（asset `Smoose-1.5.0.zip` / 1,192,543 字节 /
> `sha256:0368ccbe…`），`/Applications/Smoose.app` 也是同一个包（1.5.0 / build 14）。
>
> **2026-11-14 第四十轮（用户「执行吧」→ 发布 v1.5.0；已发版）**：
> 当天 GitHub 恢复可达（此前 DNS 被 fake-ip 劫持，`github.com` / `api.github.com` 均超时），
> `gh` 仍是 `cpufreestyle` 已登录，于是把三件事一次做完：
> ① `Resources/Info.plist` 版本 1.4.6/13 → **1.5.0/14**；
> ② `SMOOSE_SWIFT_EXTRA=-disable-sandbox ./scripts/release.sh`（不带 `--github`）打
> `dist/Smoose-1.5.0.zip`（1,192,543 字节 / `sha256:0368ccbe…`）并验顶层 `Smoose.app` + TeamID；
> ③ `scripts/publish.sh`（先 `--dry-run` 自检）走 curl REST 上传，末尾以 `GET /releases/latest`
> 闭环核对 tag / asset / digest / size 四项全部一致，并回填 `dist/Smoose-1.5.0.json` 的 url。
> Release notes 没有用 `--generate-notes`（本仓库无提交历史、生成不出内容），改用
> `gh release create --notes-file` 手写变更说明，再由 `publish.sh` 复用同一个 Release 传 asset。
> 发布后把同一个包 ditto 到 `/Applications` 并重启（pid 56612，`1.5.0` / build 14，签名校验通过）；
> 旧包（1.4.6 本地构建）备份在 `docs/backups/Smoose.app.prev-1.4.6-build-14-<ts>.app`。
> **踩坑记录**：`scripts/release.sh` 重跑会产出字节不同的 zip（编译时间戳），所以
> **发版完成后再跑一次 release.sh 就会让 dist 与线上不一致** —— 判断发版状态永远只认线上 digest。
> 仍未做（明确不做）：`release.sh --github` 分支（历史上 14 次 POST 全败，`publish.sh` 才是可用路径）；
> 项目仍无 `.git`，源码不随 Release 分发。
>
> **历史快照（2026-11-14 早间）**：以下内容记录的是 v1.5.0 尚未实现时的状态，保留用于追溯。
> 自 11-12 07:00 部署后，源码（`Sources/` `Probe/` `build.sh` `run_tests.sh` `scripts/`）**零改动**；
> 现役 `/Applications/Smoose.app` 仍是当日部署版（版本 1.4.6 / build 13、二进制 sha `371d150b…`、
> `TeamIdentifier=6U2DQJ6Z2N`，进程 pid 已随机器重启变化但二进制未变）。
> 11-14 04:08 的 `build/Smoose.app` 被重跑、同期 `dist/Smoose-1.4.6.zip` 又被外部进程重打
> （sha `6ea04b5c…`）——**核实这只是外部进程反复重打 dist，不代表有新发版**；线上
> `/releases/latest` 至今仍是 `v1.4.6 / 0db37dcb…`，判断发版状态只认这个 digest，别比对本地 dist。
> 11-12 之后项目树新增/变动的**非源码**文件：`docs/device-detection-design.md`（v1.5.0 设计方案，
> 状态「待实现」）、`.gitignore`（新增忽略 `dist/`、`docs/backups/`、`logs/`、`/-`）。
> **v1.5.0 规划已成型**：`docs/device-detection-design.md` 完整写了「设备级滚动类型识别 + 每设备覆盖」，
> 针对 README 记录的「`ignoreTrackpad` 是全局唯一开关、关掉会误伤内置触控板」缺陷。核心是三层判定
> （设备显式覆盖 → 按 HID usage 的能力分类 → 事件启发式兜底），旁路 `IOHIDManager` 影子监听 + 50ms
> 时间窗把滚动事件归属到来源设备；关键不变式是「无设备信息时逐字退化为现状」，零回归。
> 关联契约 `SPEC.md` §42，目标版本 v1.5.0，**已于同日实现完毕**（见下一段），设计文档 §11 的 6 步全部落地。
> 接手者要动这块，先读 `SPEC.md` §42 的契约与不变式。
> 回滚路径仍是 `docs/backups/Smoose.app.prev-1.4.6-20261112_070100.app`。
>
> **2026-11-14 第三十八轮（用户「按这个方案开始」→ 实现 v1.5.0 设备级滚动类型识别；PASS 96→102，未发版未部署）**：
> 按 `docs/device-detection-design.md` §11 落地：
> 新增 `Sources/DeviceAttribution.swift`（`DeviceKey` / `DeviceCapabilityClassifier` /
> `DeviceScrollPolicy` 三个纯逻辑 + `DeviceAttribution` 影子监听）；`Model.swift` 加
> `DeviceVerdict` 三档枚举与 `StoredState.deviceVerdicts`（`decodeIfPresent`，旧配置解码为空表），
> 并纳入 `ScrollConfigSnapshot`（改判定必须重新 `apply`，否则覆盖静默不生效）；
> `ScrollEngine.handleWheel` 把 `continuous && config.ignoreTrackpad` 换成三层判定
> `DeviceScrollPolicy.shouldIgnore(...)`；`App.swift` 启动监听；指针页每台设备多一个「滚动判定」下拉。
> **硬不变式**：归属失败（`device == nil`）+ `.auto` 时结论逐字等于 `continuous && ignoreTrackpad`，
> 即 v1.4.6 行为；V7 用四组合断言钉死。归属靠 `IOHIDManager` 非独占监听 + 50ms 时间窗匹配
> `CGEvent.timestamp`，全程只读，不 open / 不 seize 设备。
> **已知行为变化（认定是修复而非回归）**：能力层把「Mouse 集合 + 连续事件」的设备
> （Magic Mouse、部分高分辨率鼠标）判为滚轮鼠标，不再被 `ignoreTrackpad` 放行；误判时在设备行手改。
> harness 新增 V 段 6 项（V1–V15 + V_W 接线守卫）与三趟负例（override / fallback / builtinkey），
> Q 段补 Q30 与 `Q_MUT_verdict`。`run_tests.sh` **PASS=102 FAIL=0**，`build.sh` RC=0。
> 顺带把 harness 里 10 处编译源码清单补上 `DeviceAttribution.swift`（漏了会整体编译失败）。
> **已部署 `/Applications` 并重启（12:59）**：现役包 sha `f437f6bb…`、pid 44617、`codesign --verify --deep
> --strict` 通过、`TeamIdentifier=6U2DQJ6Z2N`；旧包（11-12 版，sha `371d150b…`）已 `mv` 到
> `docs/backups/Smoose.app.prev-1.4.6-20261114_125228.app`，要回滚就把它 ditto 回去。
> **部署时踩到并修掉一个必崩点**：`Thread { [weak self, weak manager] in ... }` 里的 `manager` 是
> `IOHIDManager`（CF 类型 / `__NSCFType`），CF 对象**不能进 weak 捕获列表**，启动瞬间直接
> `Cannot form weak reference to instance of class __NSCFType` 崩掉（进程起来 1 秒内消失，无 .ips）。
> 改成 `let mgr = manager; Thread { [weak self, mgr] in` 后正常。**以后再包 CF 类型都要先落一个
> 局部常量**，别写 `weak`。
> 另加了 3 行 `NSLog`（监听启动 / 登记台数 / 权限被拒）。**注意 `open` 启动时 NSLog 只落到
> stderr（被丢掉）**，`/usr/bin/log show --predicate 'process == "Smoose"'` 里看不到它 ——
> 验收要直接跑二进制：`/Applications/Smoose.app/Contents/MacOS/Smoose 2>&1 | head`，
> 本机实测输出「设备归属监听已启动，登记 3 台设备」。（zsh 内置 `log`，查日志要用 `/usr/bin/log`。）
> **未发版、未提交**，线上仍是 v1.4.6 / `0db37dcb…`。
> 设备归属要真机验证：`IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` 若为 denied，
> 归属恒为 nil（滚动照常，功能静默失效），此时菜单栏「最近一次滚动来源」会显示启发式文案。
>
> **2026-11-14 第三十九轮（用户「执行吧」→ 修设备插拔与设备表刷新；PASS 102→103，已部署）**：
> 部署 v1.5.0 后复查「插拔设备列表是否立刻更新」时发现两个真问题，写成 SPEC §43：
> ① `PointerController.startDeviceWatch()` 只 `Open` + 注册回调，**从未 `ScheduleWithRunLoop`** ——
> IOHIDManager 的回调不挂到在跑的 run loop 就一个都不派发，于是 §4.5 / D24 声称的「插拔事件驱动」
> 从未生效；实际靠 8 秒兜底轮询，而那个轮询第一行就 `guard pointerAccelManaged`，
> **没开「接管加速度」的用户插上新鼠标后设备列表永远不刷新**，除非重开设置。
> ② `DeviceAttribution` 不是 `ObservableObject`，行视图读静态方法 → 「自动识别为」定格在窗口打开那一刻。
> 修法：manager 挂主 run loop（回调本来就把重刷丢回主线程，不必另起线程）；
> `DeviceAttribution` 改 `ObservableObject` + `@Published devices`（登记/移除时主线程发快照），
> `PointerDeviceRow` 订阅它。新增 S40a/b/c 三条文本守卫。
> **未验证**：物理插拔的端到端效果需要真机插拔一次；代码只保证「回调会被派发」的前提成立。
> `run_tests.sh` **PASS=103 FAIL=0**，已重新 ditto 到 `/Applications` 并重启
> （sha `ad8f6456…`，pid 24270，签名校验通过）。**未发版、未提交**。
>
> **2026-11-12 第三十七轮（用户「可以」→ 本地部署到 `/Applications` 并重启；未发版）**：
> 把此前一直停在 11-10 19:03 的现役包换成 11-12 最新源码构建 —— 也就是说本机首次同时包含
> v1.4.6 之后的全部修复（AX 自动重载重入/冷启动/首压/落盘/焦点、Updater digest 与版本-内容绑定、
> HID++ 协议层、scrollSig 解耦）。流程：`run_tests.sh` 基线 PASS=96 FAIL=0 →
> `SMOOSE_SWIFT_EXTRA=-disable-sandbox ./build.sh` RC=0 → 退出旧进程（pid 32635，
> TERM 后轮询 `/bin/kill -0` 确认真的退出）→ `mv` 现役包到
> `docs/backups/Smoose.app.prev-1.4.6-20261112_070100.app`（**移动而非覆盖复制**，避免 ditto
> 合并留下旧的混杂文件，旧包完整可回滚）→ `ditto --noqtn build/Smoose.app /Applications/Smoose.app`
> → `open -g` 重启，新 pid 21501，2 秒后仍存活，无崩溃报告。
> 校验不是「命令没报错」：`codesign --verify --deep --strict` 通过、`TeamIdentifier=6U2DQJ6Z2N`、
> 现役二进制 sha256 `371d150b…` 与 build 产物**逐字节一致**、`nm` 中 `ScrollConfigSnapshot` 37 处。
> 辅助功能授权仍在：系统级 `/Library/Application Support/com.apple.TCC/TCC.db` 中
> `kTCCServiceAccessibility|app.smoose.macos|2`（用户级 db 里没有，别只查用户级就误判授权丢失）；
> 与 `build.sh` 用 Apple Development 证书做 DR 绑定的设计一致，重新编译不需要重新授权。
> 最后打开 `smoose://settings?tab=pointer` 便于验收。
> **未发版、未提交**（无 `.git`）：线上 `/releases/latest` 仍 `v1.4.6 / 0db37dcb…`，`dist` 没动；
> `dist/Smoose-1.4.6.zip` 06:57 又被外部进程重打（1,163,369 字节 / `e713e767…`，今天第四次），
> 再次印证判断发版状态只认线上 digest。要回滚就用上面那个备份目录覆盖回去。
>
> **2026-11-12 第三十六轮（用户「继续」→ 滚动配置签名解耦；PASS 90→96，未发版）**：
> 承接 §39 留下的两条热路径待办。用户中途追问「为什么要解耦」，先讲清因果链：
> `Views.swift` 写 `prefs.cursorZoomEnabled` → Combine `objectWillChange` 不携带字段名 →
> `Model.persist()` 无条件 `ScrollEngine.shared.apply(s)` → 该方法在 `ScrollEngine.lock` 下
> `phaseTracker.reset()` / `pointerRemX/Y = 0` / `suppressedButtons.removeAll()`，
> 而 tap 线程的 `handlePointerMove` 用同一把锁。所以拨一个与滚动无关的开关，
> 会在滚动手势进行中重置相位状态机、造成一次跳变或 `triggerOnMouseUp` 半边按钮卡住。
> 本轮新增 `ScrollConfigSnapshot`（10 个 config 依赖字段）+ `ScrollReapplyPolicy.needsApply`，
> `persist()` 只有快照变化才 `ScrollEngine.apply(s)`；其余字段只落盘。
> **硬约束**：`pointerSig` 与 `.smoosePointerConfigChanged` 通知路径、S31a–e 文本守卫、
> `UserDefaults.standard.set(data, forKey:)` 全部原样；`PointerController.apply(force:false)`
> 仍无条件调用（它自带 `appliedSignature` 短路，且 S31 通知会驱动 `refresh`）。
> 独立快照而非复用 `pointerSig` 是必须的：后者只含 3 个 HID 加速度字段，ScrollEngine 一个都不读，
> 拿它 gate 会让主开关/倍率/绑定/触发时机整体静默失效。
> harness 新增 Q 段：Q1–Q29 整编真 `Model.swift` + 计数桩，逐字段验证「相关字段必触发 / 无关字段不触发」，
> 并用真 `persist()` 序列证明「拨光标开关 → 零次 ScrollEngine.apply」；Q_W 盯接线与落盘，
> Q_MUT_field / gate / persist / Q_WMUT 四趟负例全部抓红。**首次 persist 仍会 apply 一次**
> （`lastAppliedScrollConfig == nil`，启动时 config 必须有值），此时没有滚动手势，无害。
> **GamePerf 按页门控评估后明确不做**：`Views.swift:796-800` 写明游戏页数据来自本来就在跑的
> tap + CVDisplayLink（刻意设计，零额外开销）；`refreshDevices()` 挂在 1Hz `recompute` 上，
> `recordPointer` 跑在 tap 独立线程。门控要给热路径加跨线程同步、补 onAppear 冷启动采样，
> 还会让设备列表 stale，收益可能为负。CVDisplayLink 是插帧刚需，任何时候都别停。
> 本轮 `build.sh` RC=0、`codesign --verify --deep --strict` 通过、`TeamIdentifier=6U2DQJ6Z2N`。
> **未发版、未部署 `/Applications`、未提交**；线上仍是 v1.4.6 / `0db37dcb…`。
>
> **2026-11-12 第三十五轮（用户「1 2」→ 抽 HID++ 协议层 + 只读排查接收器；PASS 89→90，未发版）**：
> 承接「不换 GPUI / 不跨平台 / 用户在 Win 也用罗技」三轮结论。本轮只做两件低风险的事：
> ① **协议层抽离**：`Sources/HIDPPProtocol.swift`（124 行，只 `import Foundation`）收下原
>   `LogitechHIDPP.swift` 第 5–119 行的 `HIDPPDPICommand / HIDPPDPIList / HIDPPDPIParser /
>   HIDPPDPIWriteVerdict / HIDPPDPIWrite`；原文件 748→636 行，只剩 macOS IOKit 传输层与
>   DPI 自动同步。`build.sh` 变 18 个编译单元。harness 22 处引用全部同步：10 处全量编译列表
>   带上新文件、L 段改为直接编译协议层、`HSRC`/`NHSRC` 拼接两文件、`NCOMPILE` 与 `nmut` 副本
>   带上新文件、**L_MUT / L_MUT2 改为直接变异新文件**。新增 `proto_purity_guard`（P1–P4：
>   不许 import IOKit/AppKit/SwiftUI/CoreGraphics、不许出现 IOHIDDevice/CFRunLoop/NSWorkspace/
>   DispatchQueue、必须仍有 Parser/Write 两个类型）+ L_MUT3（注入 `import IOKit` 必须抓红）+ LW14
>   （build.sh 必须编译新文件）。**反向验证**：L_MUT/L_MUT2 改打新文件后仍分别被 L23、L16/L17
>   抓红，证明抽出去的代码仍在被测路径上；L_MUT3 抓红证明纯度守卫不是假绿。最终 PASS=90 FAIL=0。
> ② **只读排查接收器**：新增 `Probe/HIDPPReadOnlyProbe.swift`（只枚举、不 open、不 SetReport、
>   不注册回调）。真机结果：7 个 0x046D HID 接口、**两个物理接收器 0xc547 / 0xc548 各带一个
>   0xFF00 HID++ 控制接口**（与第三十三轮「两个 USB Receiver」一致）；源码记录 0xc547 支持
>   0x2201（featureIndex=7），0xc548 明确不支持。竞争进程同驻：`lghub_agent`、`lghub_system_tray`、
>   `logioptionsplus_agent`（含各自 updater 与登录项）、BetterTouchTool、Smoose。
>   ⚠️ 准确性修正：**Windows 的「接收器独占」不能直接套到 macOS** —— IOKit 允许多个 client
>   打开同一 HID 设备；风险是同一条 0xFF00 通道上多进程并发下发 HID++ 请求导致响应串扰，
>   而不是「谁把谁踢掉」。`smoose.state` 里没有 HID++ 探测状态，无法从偏好断言当前是否被干扰。
> **环境坑**：`ioreg` / `system_profiler` 在 agent 沙箱（连脱沙箱也一样）返回 0 行，必须用 Swift
> `IOHIDManager` 探针才拿得到设备；第一次基线 E 段 `rm build: Operation not permitted` 是沙箱对
> 残留 `build/` 的拦截，清掉目录后基线恢复 PASS=89 FAIL=0，与代码无关。
> 本轮**未发版、未部署 `/Applications`、未提交**。`dist/Smoose-1.4.6.zip` 在 05:58 又被外部
> 进程重打（manifest 的 url 再次被清空，sha 每次都不同，故不在此写死）；线上 v1.4.6 始终是
> `0db37dcb…`。本地 `dist/` 会被反复覆盖，**判断发版状态只认 `GET /releases/latest` 的 digest**；
> 线上 Release 与本机 `/Applications` 本轮我都没动。
>
> **2026-11-10 第三十四轮（用户说「你定」→ 自主选定并执行优化清单：自动重载链路 5 个真 bug + 更新器安全闭环 + 发布脚本入库；PASS 79→89，未发版）**：
> 起点是上一轮两路只读审查合并后的清单（P0 五条 / P1 四条 / P2 别动）。本轮**只做能靠纯函数断言守住、不碰滚动与采样热路径**的部分：
> ① `CursorZoom.swift` 五个真 bug：
>   - **重入互斥**：新增值类型 `CursorZoomSyncQueue`（`submit` / `finish`），`scheduleAuto` / `runNow` 统一走 `enqueue` 串行；正在跑时又来的目标只记「最后一次」，跑完补一次 —— 不是跳过。防抖等待单独存 `debounceTask`，**绝不 cancel 已进 `perform` 的任务**（同步 AX 调用取消不了，只会留半截状态）。旧实现两个 `apply` 会并发抢焦点、AXPress 可能偶数次抵消。
>   - **冷启动假失败**：`perform` 在 `open()` **之前**读系统设置进程是否已在跑；`CursorZoomSyncPolicy.pollDelaysMilliseconds` 给 16 次轮询分配间隔（冷启动 16×1600ms≈25.6s / 已在跑 16×250ms=4s）。旧实现固定 4 秒，而真机冷启动约 20 秒 → 必然 `targetNotFound`。`for _ in 0..<16 {` 与 `guard let t = target` 两处 PW34/PW35 精确串原样保留。
>   - **首压失败仍按第二下**：`shouldPerformSecondPress` 要求 `press1Code == 0 && afterFirst != before` 才允许「离开再回来」的第二压。旧实现首压 -25204 也照按，会把开关留在非目标态、plist 反相却只回一句失败。
>   - **落盘读回太早**：新增 `shouldKeepWaitingForStored`（最多 8×125ms），等系统设置异步写完再交给 `verdict`；等不到照旧判失败，四条硬门槛一个没放宽。
>   - **焦点被硬拽回**：`shouldRestoreFocus` 仅当当前前台仍是 `com.apple.systempreferences` 才 `activate`；25 秒窗口里用户主动切走就不打扰。`restoreFocus(previousFront)` / `target.activate(options:)` / PW65–69 路径原样保留。
> ② `UpdateModel.swift` / `Updater.swift` 安全闭环：
>   - `Asset` 增加 `digest` 并解析 `assets[].digest` 的 `sha256:` 前缀，顶层显式 `sha256` 优先；只认 sha256，别的算法不拿来当 sha256 比。以前默认 GitHub 源下校验 100% 跳过。
>   - 新增 `UpdatePackageVersionCheck.verdict`：解压后读包内 `CFBundleShortVersionString`，与 `manifest.version` 按 SemVer 归一化比对，不一致抛 `versionMismatch`、读不到抛 `bundleVersionMissing`。堵住「版本源声明 9.9.9 却指向合法签名的旧包」的静默降级 —— 旧包的 codesign / TeamID 全都过。`declaredVersion` 作为参数传进后台队列，不去读 @Published；签名链与 TeamID 底线一点没动。
> ③ `scripts/publish.sh` 入库：把 v1.4.6 那次靠 `/tmp` 临时脚本成功的 curl REST 流程固化，参数化版本 / 仓库，POST 前先 GET、重试前再 GET、同名 asset digest 一致就跳过、末尾以 `GET /releases/latest` 的 tag / asset / digest / size 四项闭环，再回填 `dist/*.json`。`--dry-run` 只做本地前置自检（顶层 `Smoose.app` / 包内版本 / codesign）。**没有执行过发布**。
> ④ `README.md` 三处过期数字：最新版本 1.4.3→1.4.6（补线上真实字节数与 sha）、源码 15→17 个编译单元、`PASS=59`→`PASS=89`（两处）；补一段发版流程与「发布后别再跑不带 `--github` 的 release.sh」。
> ⑤ **harness**（`run_tests.sh` 新增 Z / Z_W / Z_W2 / Z_MUT / Z_WMUT 共 10 段）：Z1–Z40 编译真 `CursorZoom.swift` + `SettingsLauncher.swift` + `UpdateModel.swift` 断言纯策略；Z_W 14 项文本守卫防「纯函数全绿但没接线」；Z_MUT 6 趟 + Z_WMUT 1 趟负例变异，每趟先确认「文件确实被改 + MUTANT 标记存在」，再要求对应 FAIL 标签变红且进程非零退出。
>   **反向验证真的抓到一次断言假绿**：初版 `Z_MUT_press2` rc=0 没抓红 —— Z18 那个负例里「首压报错」和「值没变」同时成立，短路掉 `press1Code == 0` 后仍被另一个条件挡住。补 `Z40`（首压报错但值已变）单独卡住这个原因，重跑才全红。这正是「断言要能表达具体原因」的实例。
>   最终 `SMOOSE_SWIFT_EXTRA=-disable-sandbox ./run_tests.sh` → **PASS=89 FAIL=0**，退出码 0；7 个变异全部抓红。
> ⑥ 编译验证：`SMOOSE_SWIFT_EXTRA=-disable-sandbox ./build.sh` RC=0，1.4.6/13，`codesign --verify --deep --strict` 通过，`TeamIdentifier=6U2DQJ6Z2N`。**坑**：`strings` 查方法名报 0 是假阴性（方法名不进 cstring 段），`nm -a` 才看得到 `assetDigestSHA256` / `shouldPerformSecondPress` / `pollDelaysMilliseconds`；别拿 `strings` 计数判断「逻辑有没有进二进制」。
> ⑦ **本轮明确不做**（留给下一轮，都有真实回归面）：`Model.persist()` 的独立 scrollSig 解耦（拨光标开关会 `phaseTracker.reset()` 并抢 `ScrollEngine.lock`；不能复用 `pointerSig`，见 §32 与 11-09 记忆）、GamePerf 按页门控（会动 S35/S36 采样契约）、`findTarget` 主线程 AX 遍历、README/SPEC 章节编号重排。理由：都要改运行时热路径或大量交叉引用，和本轮「小改 + 可断言」的边界不符。
> ⑧ **现场状态（重要）**：本轮期间 `dist/Smoose-1.4.6.zip` 于 23:22 被**外部进程**重打（1,154,585 字节 / sha `61cfbf94…`，manifest url 被清空），不是本轮操作；线上 Release 仍是 `v1.4.6` / `sha256:0db37dcb…`，未受影响，本轮也没有覆盖 dist。`/Applications/Smoose.app` 仍是 11-10 的本地构建。**未发版**：`Info.plist` 仍 1.4.6 / 13；项目无 `.git`，全部改动保持未提交；发版属于需用户单独确认的不可逆操作，本轮没有执行。
>
> **2026-11-10 第三十三轮（用户看到「游戏」页两行都叫 USB Receiver，问「有两个重复了吗」→ 不是重复，是两个物理接收器；UI 同名时追加 PID / USB 位置，本地已部署双向验收，未发版）**：
> 用户原话「有两个重复了吗」+ 截图（游戏页三行：两个 USB Receiver 1000 Hz + 内建触控板 125 Hz）。
> ① **结论：不是重复**。取证用 `ioreg -l -w0` 的树形结构：系统里有**两个物理罗技接收器**
>    —— `USB Receiver@01120000`（PID 50504 / LocationID 17956864，4 个 USB 接口，`lghub_agent`
>    在每个接口上都开着 user client）和 `USB Receiver@03100000`（PID 50503 / LocationID 51380224，
>    3 个接口，同样有 `lghub_agent`）。用与 App 相同的 API（`IOHIDServiceClient`）读两个指针服务：
>    PID 50504 那个的 `DeviceUsagePairs` 有 5 项（鼠标 / 键盘 / consumer / telephony…），
>    PID 50503 那个只有 2 项（鼠标 + 指针）。所以是两台不同设备，各自一个鼠标集合。
> ② **为什么不能去重**：合成一行会谎报设备数，更糟的是加速度写入会少写一台
>    （`PointerController.apply` 是对 `devices` 逐台写的）。反过来，原样显示两行同名也不对 ——
>    用户无法判断接管覆盖了哪几台。所以选「同名时追加物理标识」。
> ③ **改动（4 个文件，全部只影响显示，未碰写入路径）**：
>    `GamePerf.swift` 新增纯函数 `DeviceLabel.disambiguate/hasSameNameSibling`（PID 优先，
>    退回 USB 位置，两者都没有就原名，不编假标识）；`PointerController.MouseDevice` 增补
>    `locationID/productID`，`apply()` 的三条状态行走 `statusLabel()` 消歧；
>    `App.swift` 的 `deviceSource` 透传这两个字段；`Views.swift` 游戏页行标题 + 指针页设备行
>    用同一个纯函数，游戏页脚注补一句「多行同名不是重复」。
> ④ **harness**：新增 H42（7 项）覆盖 `DeviceLabel` 的每条分支，包括「单设备不加后缀」
>    「PID 优先」「退回 USB 位置」「两者都没有就原名」。第一次跑全量 **FAIL=2**，两个都是真问题：
>    H 段编译失败（harness 里三处 `GameDeviceInfo(...)` 直构没带新字段）、
>    MW4 接线守卫红（它断言 `skippedLine(name: device.name)` 这个字面量，而我把参数包成了
>    `statusLabel(...)`）。两处都已按新意图修好 —— 守卫的语义（跳过行必须带设备名）没变。
>    最终 `SMOOSE_SWIFT_EXTRA=-disable-sandbox ./run_tests.sh` → **PASS=79 FAIL=0**。
> ⑤ **真机双向验收**：`ditto` 部署 + 重启，AX 树读回游戏页三行标题已变成
>    `USB Receiver（PID 50504）` / `Apple Internal Keyboard / Trackpad（内置）` / `USB Receiver（PID 50503）`；
>    指针页设备行与加速度状态行同样带 PID，且两台都显示「线性 1:1 · 回读 -1.000」。
>    独立只读探针（`Probe/AccelReadProbe.swift`）同时确认两个指针服务都是 -65536。
> ⑥ **未发版**：`Info.plist` 仍 1.4.6 / 13。回滚点
>    `docs/backups/Smoose.app.prev-1.4.6-20261110_183900.app`（= 上一轮 1.4.6 + 第三十一轮悬停解释）。
>
> **2026-11-10 第三十二轮（用户问「鼠标怎么有段时间被控制」→ 结论是 macOS 自己的指针加速曲线，且线性接管写入当时已失效；新增只读取证探针 + SPEC §37，未发版）**：
> 用户原话「鼠标怎么有段时间被控制」，与 2026-10-18/10-19 问过的「刚移动很慢后面正常」
> 「停一段时间以后启动非常慢」是同一现象。本轮**没有改 App 代码**，只做了真机取证、恢复生效、
> 固化探针与文档。
> ① **结论：被控制的不是鼠标移动，是 macOS 的加速曲线**。该曲线速度相关、低速增益 < 1：
>    刚起步 / 停久了再动时增益被压低，光标像被拽住，手速上来后增益升满就「正常了」。
>    按用户当前配置（`pointerSpeedManaged=false`、`pointerSpeedFactor=1`）Smoose 对
>    mouseMoved **一个字节都不改**（`handlePointerMove` 的 `needRewrite` 恒 false，原样放行），
>    所以手感差异不可能来自事件 tap，只能来自 IOHID 层。当前存档实测：
>    `pointerAccelManaged=true` / `pointerAccelerationValue=0`（线性）/ `cursorZoomEnabled=false` /
>    每应用只有微信一条滚动规则 / 侧键绑定为空。
> ② **取证（本轮核心，全部可复现）**：独立只读探针（见 ④）在 App 未运行时报
>    G502 X 的两个指针服务 `HIDMouseAcceleration = 0`；`open -g` 启动 Smoose 后 **12 秒内**
>    两个服务都变 `-65536`，状态区同步变绿「线性 1:1（加速与灵敏度均禁用）· 回读 -1.000」。
>    `0 ≠ 关闭`：0 = 最小加速度，曲线仍在（只是最弱）；`-65536` 才是 LinearMouse 语义里的
>    「加速与灵敏度均禁用」。所以用户那段时间的体感就是曲线重新接管了。
> ③ **写入的持久性实测（推翻两个想当然）**：`osascript -e 'quit app "Smoose"'` 后值**不掉**
>    （仍 -65536）；App 退出状态下鼠标静置约 4 分钟、5 次采样仍 -65536。
>    `uptime` = 5 天 15 小时、`pmset -g log` 无 sleep/wake 事件 → 那个 0 与重启/睡眠无关。
>    因此本轮开始时值是 0 的最合理解释：App 上次长时间运行期间写入漂移（2026-11-09 记录过
>    同一现象「跑约一天后停在 0、重启 App 立刻恢复」），之后 App 被退出，再没人改写。
>    **注意本轮开始时 App 根本没在运行**（登录项里有 Smoose、无崩溃报告）—— App 不在跑时
>    线性接管和滚轮增强同时失效，用户很容易把两者都归因到「鼠标」。
> ④ **新增 `Probe/AccelReadProbe.swift`（只读，绝不写设备）**：与会试写 0/163840/65536 的
>    `Probe/main.swift` 区分开。列出事件系统里符合 GenericDesktop/Mouse 用法的服务及其加速度读数，
>    按 -65536 / 0 / 163840 给出判定，退出码 0=全部线性、2=有服务没接管、3=没有外接指针服务。
>    用法 `swiftc Probe/AccelReadProbe.swift -o /tmp/accelread -framework IOKit && /tmp/accelread`。
>    为什么需要独立进程读数：App 状态区读的是自己写后的回读，「写进去之后又被系统改回去」
>    只有独立进程能发现（本轮就是这么抓到 0 的）。
> ⑤ **写入落在哪些节点（本轮实测，此前只有推测）**：G502 X 的 USB Receiver 同时暴露
>    鼠标 / 键盘 / 消费类控制共 5 个 HID 集合，`IOHIDServiceClientConformsTo(GD_Mouse)`
>    只认其中 2 个鼠标集合，写入也只落这 2 个；键盘与 consumer 集合上的同名键与指针手感无关。
>    另：`HIDUseLinearScalingMouseAcceleration` 走 service client 读回是 nil（状态区显示
>    「线性标志 不支持(回退 -1)」），而 ioreg 的 registry 视图显示 1 —— 两个视图不一致，
>    以 service client 视图为准（App 就是这么读的），这也是状态区那句话的来源。
> ⑥ **文档**：SPEC §37 记录契约、四条已验证断言与未验证项。
> ⑦ **未决（不要当结论）**：0 的来源未能定位，需要复现「长时间运行后漂移」才能继续；
>    漂移机制（怀疑旧 client 的回显读到的是写入值而非内核真值，使 8 秒轮询签名恒等永久短路）
>    **只是推测，零证据**。下一步若要动代码，方向是给轮询加一条独立读回校验，
>    但必须先能复现，否则就是盲改——等用户决定是否值得做长跑验证。
> ⑧ **本机状态**：Smoose 已重新启动（pid 见 `pgrep -f MacOS/Smoose`），2/2 指针服务线性，
>    设置窗口停在「指针」页（`open "smoose://settings?tab=1"`）。未发版：`Info.plist` 仍
>    1.4.6 / 13，本轮未改 App 代码，本机二进制与线上 1.4.6 + 第三十一轮悬停解释一致。
>
> **2026-11-09 第三十一轮（「有必要的地方加入悬停显示解释」→ 补满 12 个键 + 修掉 harness 里一个真假绿；本地已部署双向验收，未发版）**：
> 用户原话就一句「有必要的地方加入悬停显示解释」。上一轮（未记入本文档的中间态）已经铺了
> `Sources/HelpText.swift` 文案表和 29 处挂载，本轮补齐剩余控件，并在补 harness 变异时
> 挖出 T_W 段一个**从上线起就没生效过**的检查。
> ① **新增 12 个键 + 11 处挂载**（挂载总数 29 → 40，键 35 → 47）：
>    每应用细节参数里的 4 个轴向开关 + 模拟触控板 + 按住透传（`appRuleSmoothVertical` /
>    `appRuleSmoothHorizontal` / `appRuleReverseVertical` / `appRuleReverseHorizontal` /
>    `appRuleSimulateTrackpad` / `appRuleBypass`）、「添加应用」菜单（`addAppRule`）、
>    关于页的请求权限 / 每天自动检查 / 重置全部设置（`requestPermission` / `autoCheckUpdates` /
>    `resetAllSettings`）、指针页的重新检测 / 恢复系统默认（`pointerRefresh` / `pointerRestoreDefaults`）。
>    没有为了凑数把「跟随全局」「取 1.0（原速）」这种一眼懂的也挂上 —— 悬停气泡太多会变噪音。
> ② **挖出并修掉 T_W 的假绿**：`for C in $TCASES` 在本脚本（zsh）里**不做单词拆分**，
>    `$TCASES` 是一整串带换行的参数，而 BSD `grep -F` 把 pattern 里的空行当「匹配任意行」，
>    所以「每个键都必须在 Views.swift 里有调用点」这条**恒真**，从来没抓到过未接线的键。
>    改成 `${=TCASES}` 后第一次跑就报出真实的 `boostModifiers` —— 它的 `help:` 实参跨行
>    （`ModifierBypassRow(..., help: .boostModifiers` 换行再写 `)`），而我第一版边界正则
>    只写 `[^A-Za-z0-9]`（行尾符不参与 grep 逐行匹配）又造成虚报；最终写成
>    `([^A-Za-z0-9]|$)`，且 `$` 必须是双引号串末的裸 `$`。`${C}` 的显式花括号也不能省：
>    `$C[^A-Za-z0-9]` 被 zsh 当成对 C 取下标，报 `bad math expression`。
>    这三个坑都写进了 SPEC §36 和 run_tests.sh 的注释，不是只改代码。
> ③ **T_W 抽成函数 `tw_guard()`**：为的是让新加的 T_MUT3 能把整条守卫喂给摘过挂载的副本。
>    原来的 T_WMUT 只验证「变异体造得出来」，属于自证；T_MUT3 摘掉 `.smooseHelp(.addAppRule)`
>    后真跑一遍守卫，必须报「未接线的键: addAppRule」—— 已 PASS。
> ④ **新增真机探针 `Probe/AXHelpProbe.swift`**：`smooseHelp` 写没写、T_W 只做文本断言，
>    都证明不了「运行中的 App 真把 toolTip 设到 NSView 上」—— SwiftUI 的 `.help()` 在某些
>    容器里会被吞掉。探针用 `AXUIElementCopyAttributeValue(k, "AXHelp")` 从 WindowServer 读回。
>    **实测 99 个控件带 tooltip**：tab0 常规 43 / tab1 指针 30 / tab2 每应用 11 /
>    tab3 按键 6 / tab4 游戏 1 / tab5 关于 4；`--all` 顺带列出无 tooltip 的控件。
> ⑤ **本机部署**：`codesign --verify` 通过（TeamIdentifier=6U2DQJ6Z2N，与现役同证书），
>    ditto 到 `/Applications/Smoose.app`，`open -g` 重启；12 条新文案在出厂二进制里逐条命中。
>    回滚点 `docs/backups/Smoose.app.prev-1.4.6-20261109_210958.app`（= 线上 1.4.6，无悬停解释）。
>    授权记录在系统级 TCC.db，同证书重签不掉，重启后 `defaults read` 正常。
> ⑥ **验证**：全量 `PASS=79 FAIL=0`（上轮 78 + T_MUT3）。E 段整包编译过 Views.swift +
>    HelpText.swift，所以键名打错 / 挂载点语法错会直接让 E 段红。
> ⑦ **如实记录的未覆盖边界**：每应用「细节参数」折叠组里那 6 个轴向开关，真机 AX 树上读不到
>    —— 折叠内容连 AX 树都没有，且 `focusAppID` 只能从菜单栏面板设置，脚本展不开。
>    这 6 处的证据只有三条：文案在二进制里逐条命中 + T_W 3 要求每个键都有调用点 +
>    同一个 `List` 容器里的「接管」复选框和两个滑条已实测带 tooltip。
>    菜单栏面板是 `NSPopover`，不出现在 `kAXWindowsAttribute`，探针同样读不到。
>    要补真机读数，需要手工点开折叠组后重跑 `/tmp/axhelp --expand`。
> ⑧ **未发版**：`Info.plist` 仍是 1.4.6 / 13，本机 = 线上 1.4.6 + 本轮悬停解释。
>    等用户明确说「推送」再抬版本发 Release。
> ⑨ **顺带修正的文档错误**：`smoose://settings?tab=N` 的真实 tab 顺序是
>    0 常规 1 指针 2 每应用 3 按键 4 游戏 5 关于，代码注释里原写的是「1 每应用 2 按键」，
>    已按实测改正（SPEC §36、探针注释）。
>
> **2026-11-09 第三十轮（用户「推送」→ 发 v1.4.6，第二十六～二十九轮全部上线）**：
> ① 版本抬到 `1.4.6` / `CFBundleVersion 13`；`SMOOSE_SWIFT_EXTRA=-disable-sandbox ./run_tests.sh`
>    → **PASS=73 FAIL=0**（含 MUT11–MUT14 / P_WMUT 反 drift）。
> ② `SMOOSE_SWIFT_EXTRA=-disable-sandbox ./scripts/release.sh`（**不带 `--github`**，只本地出包，
>    避开 `gh` 在轮换代理节点上 POST 不稳）→ `dist/Smoose-1.4.6.zip` 1130497 字节、
>    sha256 `0db37dcb…defa15`、签名 `Apple Development: qm0819@hotmail.com (5F66DDWD6H)` /
>    `TeamIdentifier=6U2DQJ6Z2N`（与现役包同一张证书，TCC 的 DR 不变）。
> ③ 发布走 `curl` REST 幂等脚本（`/tmp/smoose_publish_146.sh`）：每次 POST 前先 GET
>    `/releases/tags/v1.4.6` 与 `/releases/:id/assets` 确认（超时 ≠ 失败），asset 传
>    `uploads.github.com`，**失败重试绝不重建 zip**（LC_UUID 会让 sha 变）。
>    本轮一次即成：Release id `439040662` / POST 201、asset POST 201；
>    `GET /releases/latest` = `v1.4.6`，asset `digest=sha256:0db37dcb…defa15` 与本地一致。
>    `dist/Smoose-1.4.6.json` 的 `url` 由发布脚本补填（不带 `--github` 时 release.sh 留空）。
> ④ 增量确认：解出线上 `v1.4.5` asset（1104409 字节，sha `a820f4d4…ea0c6`）的 Mach-O 做字节比对，
>    `AX_FIND_CURSOR` / `CursorZoomSessionSync` / `CursorZoomAutoSyncPolicy` /
>    `PointerAccelRetryPolicy` / `CursorZoomSyncLedger` 在线上 1.4.5 **全为 0**，新包各 ≥1 ——
>    证实 26–29 轮此前确实没发过，不是重发同一包；`SettingsLayout` 两边同为 26，布局修复已在 1.4.5。
> ⑤ 端到端：下载线上 asset sha256 与产出端逐字节一致 → 顶层 `Smoose.app`、版本 1.4.6/13、
>    `codesign --verify --deep --strict` 通过、TeamIdentifier 与 `expectedTeamIdentifier` 对齐 →
>    真源码 `UpdateCheck.decide` 对线上 `releases/latest`：`1.4.3/1.4.4/1.4.5 → available(1.4.6)`
>    且 url 指向该 asset，`1.4.6/1.5.0 → upToDate`（`UPDATECHECK-OK`）。
> ⑥ 本机部署：备份 `/tmp/Smoose.app.prev-1.4.5-20261109_192052.app` → 退出旧进程 →
>    用**下载的线上包** ditto 到 `/Applications/Smoose.app` → `open -g` 重启（pid 98141）。
>    系统级 `/Library/.../TCC.db` 里 `kTCCServiceAccessibility | app.smoose.macos | auth_value=2` 保留
>    （⚠️ 授权记录在系统级库，用户级 `~/Library/.../TCC.db` 查不到，别拿空结果当「授权丢了」）。
> ⑦ 前面四轮里所有「未发版」标注都是当时状态，现已随 v1.4.6 发布；
>    **代码与文档改动仍保持未提交**（本目录无 `.git`，未推任何源码仓库）。
>    残留限制不变：自动重载会短暂打开系统设置，画面效果只能由用户摇鼠标确认。
>
> **2026-11-09 第二十九轮（「为什么必须点立即生效」→ 开关变化自动重载 + 修掉重启后的假提示；本地已部署双向验收，未发版）**：
> 用户问「为什么必须点立即生效」，回答是两条通道不同：`CGDisableCursorLocationMagnification` 由 WindowServer
> 只在登录会话启动时读，第三方写 plist 不热重载；只有系统设置自己拨 `AX_FIND_CURSOR` 才触发会话重载。
> 用户回「你定」，于是选「开关变化自动跑 + 修状态显示」并落地：
> ① `CursorZoom.swift` 新增 `CursorZoomAutoSyncPolicy`（防抖 600ms、`shouldTrigger(writeOK:)` 只在写盘成功时触发、
>    `LedgerDisplay` 三态 / `ledgerMessage` 文案 / `shouldRecord` 失败绝不记账）与 `CursorZoomSyncLedger`
>   （UserDefaults 写、CFPreferences 独立读回校验）；`CursorZoomSessionSync` 改 `ObservableObject`，
>   统一由单例调度 `scheduleAuto` / `runNow`，自动与手动**共用同一个 `apply` 和四条硬门槛**，
>   成功后写 ledger，失败不写。
> ② `Views.swift`：`@ObservedObject zoomSync`、`applyCursorZoom` 写盘成功后 `scheduleAuto`、手动按钮走 `runNow`
>   （取消 pending 避免拨两遍）、状态区改用 `ledgerMessage`、`onChange(of: lastResult)` 刷新系统值；
>   旧文案「本次会话：尚未重载」彻底删除（那是 App 丢了记录，不是系统状态回退）。
> ③ **焦点恢复**：`apply` 必须在 `perform` **之前**取 `NSWorkspace.frontmostApplication`，完成后用
>   `NSRunningApplication.activate(options: [.activateAllWindows])` 恢复。真机实测 `NSApp.activate(ignoringOtherApps:)`
>   在 macOS 27 不可靠（前台会掉到 Finder），已删除该路径，PW69 守着不许回来。
> ④ 验证：全量 **PASS=73 FAIL=0**（上轮 68 + MUT11–MUT14 + P_WMUT）；新增 S40–S61、PW47–PW69。
>   变异抓红：写盘失败也自动跑→S41；失败也写 ledger→S45–S50；忽略记录方向无脑 upToDate→S53/S54；
>   重启后代用户宣称「已生效」→S57；预先写 `lastResult = .applied` / 跳过独立读回→PW50/PW55。
> ⑤ 真机：**只拨开关、不点按钮** → `plist 1→0`、`AX_FIND_CURSOR '1'`、ledger 落盘、
>   文案「按「开启」重新加载 ✓ 请摇动鼠标确认光标会变大」；反向 `0→1` / `'0'` / 「不再放大」；
>   前台 BEFORE/AFTER 均为 Smoose；重启 App 后显示「上次在 18:59 已让系统按「关闭」重新加载」、
>   无「尚未重载」、HID `-65536` 无红字。最终状态留在关闭、系统已重载。
> ⑥ **耗时实测**：系统设置进程冷启动首轮约 20 秒（那个进程长驻后响应慢），之后每次 **2.4 秒**。
>   stale 文案如实写「首次冷启动可能要十几秒」，不写「短暂」这种乐观措辞。
> ⑦ **验收坑**：App 还在运行时直接读 `~/Library/Preferences/app.smoose.macos.plist` 可能看到**未 flush 的旧 ledger**
>   （`UserDefaults.synchronize()` 在新系统是 no-op），与 cfprefsd 视图短暂不一致；重启 App 后磁盘与 UI 一致。
>   判断 ledger 是否正确，以重启后的 UI / 磁盘为准，别拿进程运行中的磁盘快照当结论。
> ⑧ **未发版**：`Info.plist` 仍是 1.4.5 / 12，本机 = 线上 1.4.5 + 第二十七～二十九轮修复。
>   等用户明确说「推送」再抬版本发 Release。代价要如实说明：自动重载会短暂打开系统设置，
>   画面效果仍只能由用户摇鼠标确认，程序不代其宣称。
>
> **2026-11-09 第二十八轮（「打开摇动放大却没生效」= 会话同步单向写死「关」+ 系统值覆盖用户选择；本地已部署双向验收，未发版）**：
> 用户先说「继续」（要收尾冷启动窗口测量），随即反馈「现在我打开移动，加大鼠标头的功能，它没法生效」，
> 于是先把新故障处理完，再补完冷启动测量。
> ① **真机证据链**：`defaults read app.smoose.macos` 解出 `smoose.state.cursorZoomEnabled=False`，
>    但设置页仍显示 `已写入系统偏好 ✓` —— 用户点过「开」，开关却已被改回「关」；
>    `CGDisableCursorLocationMagnification = 1`（禁用）。再用同签名 AX 探针点「立即生效」：
>    `PLIST` 保持 `1`、文案是「请摇动鼠标确认**光标不再放大**」—— 按钮干的事就是把系统拨回关，
>    与用户想要的开启完全相反。
> ② **根因两层**（都在上一轮第二十六轮引入的「不注销即时生效」里）：
>    - `CursorZoomSyncPolicy.verdict` 把终态硬编码成 `AXValue="0"` / `stored="1"`，
>      `press2Needed = (before == "0")`、`CursorZoomSessionSync.apply()` 不带目标参数 →
>      **整条链路只会关闭**。用户开启后点按钮，系统反被拨回关还报绿（假绿中的方向错）。
>    - `Views.syncZoomFromSystem()` 每次 `.onAppear` 用系统值回写 `prefs.cursorZoomEnabled`，
>      `App.syncCursorZoomFromSystem()` 启动时同样回写 → 用户刚选的「开」被覆盖。
>      加上状态文案全是关闭视角（「偏好是关的、光标仍可能放大」「把这个开关关一次再打开」），
>      开启方向没有任何正确指引。
> ③ **修法（方向无关）**：`CursorZoomSyncResult.applied` 带 `enabled`；
>    `CursorZoomSyncPolicy` 新增 `desiredAX / desiredStored / needsDoublePress`，
>    `verdict(..., desiredEnabled:)` 的终态与落盘校验都按目标方向；
>    `SessionSync.apply(desiredEnabled:)` 由指针页传 `prefs.cursorZoomEnabled`；
>    已是目标态拨两次「离开再回来」强制系统重写，不是目标态拨一次即到位；
>    成功文案按方向写「光标会变大 / 不再放大」，且始终要求用户实测画面。
>    `.onAppear` 改为**只读观测**，不再回写 prefs；新增「系统偏好与当前开关不一致」橙色提示；
>    `statusMessage` 改为「让系统设置在本次会话按当前开关状态重新加载」。
>    `App.swift` 启动同步保留：写入成功后系统值与用户期望一致，真机验证重启不会覆盖。
> ④ **验证**：全 harness `PASS=68 FAIL=0`（上轮 66 + 新增两趟变异）。
>    P/S 段补 S26–S39（开启方向终态、文案、按压次数），P_W 补 PW36–PW46 双向接线守卫；
>    新增 MUT9（verdict 写死成「只会关」→ S28/S29 红）、MUT10（按压次数写死 → S36/S38 红）。
>    **两个自造的假绿坑**：MUT9 初版把变异打在 `apply→perform` 参数上，纯逻辑断言根本不调用
>    那段，于是「没抓红」其实是变异没落在被测路径；改成打在 `verdict` 本体才有效。
>    另修 `grep "^FAIL S2"` 前缀误匹配 `FAIL S28` 导致的假判红（统一改成 `^FAIL $CASE( |$)`）。
> ⑤ **真机双向验收**（同签名 AX 探针点控件 `AX#2`）：
>    开 → `PLIST 1→0`、`AX_FIND_CURSOR '0'→'1'`、文案「按「开启」重新加载 ✓ …光标会变大」；
>    关 → `PLIST 0→1`、`AX_FIND_CURSOR '1'→'0'`、文案「按「关闭」…光标不再放大」；
>    最终按用户诉求留在**开启且已重载**。重启 App 后开关仍为开（`PLIST=0`、checkbox=1），
>    HID 参数 `-65536` 无红字。
> ⑥ **顺带补完「继续」的原任务（冷启动窗口）**：注入 `HIDMouseAcceleration=0` → kill → 启动，
>    高频采样到 `-65536` 只用 **0.33 秒**（进程出现后 0.01 秒），说明启动时序没有真空期，
>    第二十七轮的「启动粘滞」确实不是启动慢，而是长跑后失败被固化。
> ⑦ **未发版**：`Info.plist` 仍是 1.4.5 / 12，本机 = 线上 1.4.5 + 第二十六轮会话同步
>    + 第二十七轮 HID 自愈 + 本轮双向同步。等用户说「推送」再抬版本发 Release。
>    边界不变：画面效果程序观测不到，必须用户摇鼠标确认；「本次会话」只在本次运行内保留，
>    重启回「尚未重载」是**少报**而非假绿。
>
> **2026-11-09 第二十七轮（「启动粘滞」= HID 写入失败被永久短路 + client 不自愈；本地已部署验收，未发版）**：
> 用户只说「启动粘滞」。按 §4.8 的历史（用户曾把「静止后起步发黏」叫「启动慢」）先查真机、
> 拿到硬证据再动手，没有先反问：
> ① 现象复核：`hidutil --matching 鼠标` 读 `HIDMouseAcceleration = 0`（不是 -65536），
>    设置页状态区 `USB Receiver … 回读 -0.000  ⚠️ 写入未生效`；而 `0` 正是 §4.8 记的
>    「最小加速度、低速增益 <1」的起步发黏值。点「重新检测」**无效**，重启 App 立刻
>    恢复 `-1.000 / -65536`。App 已连续运行约 1 天（uptime 3d21h，未重启机器）。
> ② 根因两层，都靠证据排除：
>    - **失败态被签名固化**：`apply()` 失败时把 `settled` 存成「实际读回值 0」，
>      下一轮 `readings` 读到的还是 0 → `signature == appliedSignature` →
>      `apply(force:false)` 直接短路，8 秒轮询**永远不再重写**。
>      旧注释 / K18 断言都写着「存实际值以重试」，但只验了 `settled == 0`，
>      没验重试真会发生 —— 断言本身就是假绿。
>    - **client 不能重建**：`private let hidClient = IOHIDEventSystemClientCreateSimpleClient(...)`，
>      长时间运行后 `IOHIDServiceClientSetProperty` 静默失效（写回显成功、读回恒 0），
>      所以连 `refresh(force:true)` 也救不回来，只有重启进程才恢复。
> ③ 修复（`Sources/PointerController.swift`）：新增纯函数 `PointerAccelRetryPolicy`
>    （storedSignature / nextFailureCount / shouldRebuild / shouldQuickRetry）——
>    **失败轮清空签名**，保证下一轮必定重写；成功轮照常缓存，短路优化不丢。
>    连续失败 2 轮且过 30s 冷却 → `scheduleForceRefresh()` 重建 client + 全量重枚举；
>    失败后 1 秒另有一次快速重试（上限 5 次，防每秒自循环）。`hidClient` 改 `var`，
>    `refresh(force:true)` 时重建；失败文案补「（正在自动重试）」。
>    两处旧注释「存失败值能让下轮签名不同」已更正（那正是假的）。
> ④ harness：K 段扩到 K1–K34（K22 用**真实签名**模拟「下轮会不会短路」），
>    K_W 补 KW10–KW18 + KW_PRE；新增 K_MUT3（恒缓存签名 → K21/K22/K23 红）、
>    K_MUT4（失败计数恒 0 → K24/K25 红）、K_WMUT（改回 let / 绕过策略 / 摘掉快速重试
>    → KW13/KW10/KW18 红）。**K_MUT3 第一轮把我自己写的占位串断言抓成假绿**：
>    `"sig-ok"` 变异后碰巧仍不等于真实签名，K22/K23 不变红；改用真实签名后修好。
>    全量 `PASS=66 FAIL=0`（上轮 63 + 3 段）。
> ⑤ 真机验收：部署 `/Applications/Smoose.app`（备份 `/tmp/Smoose.app.prev-*`、验签通过）；
>    启动 → `回读 -1.000 / -65536` 无红字；点「重新检测」（走重建 client）仍 `-1.000`；
>    人为用 hidutil 注入漂移 0 → 11 秒后自动纠回 -65536。
>    **验收边界**：句柄失效无法脚本化复现，所以「连续失败 → 自动重建」只由纯函数断言 +
>    变异验证守住，没有真机端到端；需日常跑一段时间看是否复发。
> ⑥ **未发版**：`Info.plist` 仍 1.4.5 / 12，本机 = 线上 1.4.5 + 光标放大会话同步 + 本轮自愈。
>    §4.8 的老结论仍成立：**`-1` 是否真的消除主观发黏只能靠手感**；这轮修的是
>    「参数掉回 0 且永不恢复」这个可观测 bug，不宣称解决所有手感问题。
>
> **2026-11-07 第二十四轮（DPI 非幂等写入实测 + 发版 v1.4.3；已发版、已提交）**：用户从
> 待确认清单里点选「发版 / 提交」与「非幂等 DPI 往返实测」，按「先验证后发版」执行。
> ① 新增 `Probe/HIDPPNonIdempotentRoundTrip.swift`（**手动开发探针，不进 harness**，
> 否则每次回归都会动用户硬件）：独立只读会话读原值 → `SeizeDevice`（与 App 写入路径
> 一致）写一个**不同的合法档位** → 读回确认 → 写回原值 → **第三个独立会话**复核。
> 真机 `featureIndex=7 / sensor=0 / 100–25600 / 步长 50`，原值 **5400**（说明上次记录的
> 14700 后来被切回过），`5400 → 5450 → 5400` 每步 `rc=0`、设备回显与独立读回一致；
> 若 SET 其实没生效（旧版假绿），读回仍是 5400 会当场报红。硬件最终恢复原值、未留改动。
> **§4.9 记的「只验过幂等写入」缺口至此补齐。**
> ② 版本 1.4.2 → **1.4.3**（`CFBundleVersion` 9 → 10），全量 harness `PASS=59 FAIL=0`；
> `/Applications/Smoose.app` 已部署 1.4.3（Mach-O `af84277c…`、`codesign --verify --deep
> --strict` 通过、TeamIdentifier `6U2DQJ6Z2N` 不变，备份 `/tmp/Smoose.backup.20261107_124055.app`）。
> ③ 代码已提交并推送：远端 `2ea1eaf..1a19d96 main -> main`（SSH 通道，第 3 次重试成功）。
> ④ Release **v1.4.3** 已发：https://github.com/cpufreestyle/Smoose/releases/tag/v1.4.3 ，
> asset `Smoose-1.4.3.zip` 1,096,543 字节、sha256 `c2d6daec…`；`GET /releases/latest`
> 已指向 v1.4.3（非 draft / 非 prerelease），服务端 asset `digest` 与本地包逐字节一致；
> `dist/Smoose-1.4.3.json` 已填好 url + sha256。
> ⑤ 两个环境坑见 §6.1d：`release.sh` 内部会调 `build.sh`，受限环境**必须**带
> `SMOOSE_SWIFT_EXTRA=-disable-sandbox`；代理免费节点轮换时 `gh` 的 Go 客户端在 POST 上
> 持续 EOF / TLS 超时，改用 `curl` 直调 REST + 幂等重试才通。历史各轮写的「未发版 / 未提交」
> 是当时状态，均已随本轮 v1.4.3 关闭。
>
> **2026-11-07 第二十五轮（横屏设置窗口响应式多列，已扩到 3 列 + 修重复 section；本地已部署，未发版）**：
> 用户问「横屏一页显示不全，有没有必要改多列」，随后确认要「自适应」并「可以超过两列」。
> 结论：**多列是对的解法**，根因是固定 560×620 单列画布——矮屏上窗口被 OS 压到低于
> 620 高时，`uiScale` 下限钳在 1，~576pt 内容就被裁掉底部。改造**没有重构缩放系统**
> （`logicalSize` 横屏本就返回更宽逻辑画布），只是让标签页在画布够宽时切多列把高度压低：
> ① `SettingsLayout.columns(forLogicalWidth:)`：`<760 → 1 列`，`[760,1140) → 2 列`，
> `≥1140 → 3 列`（阈值 `twoColumnLogicalWidth=760` / `threeColumnLogicalWidth=1140`）；
> `EnvironmentValues.layoutColumns` 默认 1，保证独立预览仍是单列。
> ② `ResponsiveForm<Col0,Col1,Col2>`：三组内容**互不重复**，1 列时合并进一个 `Form`
> （顺序 c0→c1→c2，外观同旧版），2 列时 c0 独立一列 + c1/c2 右列上下堆叠，3 列时三组各一列；
> 都保持 `.grouped` 风格。
> ③ `ScaledTabContent` 按逻辑画布宽度算列数注入环境。
> ④ **滚动 / 指针 / 按键 / 游戏** 四页改成三组不重复分区；**按应用**（List 占满宽）与
> **关于**（居中基准高度）保持单列。
> ⑤ **顺手修了一个之前分栏留下的重复 bug**：General 的「轴向与方向 / 临时透传 / 按住加速 /
> 预设」、Pointer 的「指针速度 / 说明 / 状态」、Game 的「就绪度」被同时复制进 left 与 right，
> 单列 / 两列都会显示两份——现已按三组唯一分区消除重复。
> ⑥ harness J 段补 J23–J28（560→1、759→1、760→2、1139→2、1140→3、2000→3）。
> 全量 `PASS=59 FAIL=0`；本地 `/Applications/Smoose.app` 已部署（仍是 **1.4.3** 构建、
> 验签通过、TeamIdentifier `6U2DQJ6Z2N` 不变，备份 `/tmp/Smoose.backup.20261107_162207.app`）。
> **未发版、未提交、未推远端**——等你横屏实测（拖到约 1140pt 宽应看到 3 列）确认后再抬版本。
>
> **2026-11-07 第二十六轮（光标放大：设置页同步系统真值 + 不注销即时生效；本地已部署验收，未发版）**：
> 用户连续反馈「关闭了移动鼠标放大，但它还会放大」「你要在设置里面同步」「要不注销也能生效」。
> **上一轮的判断要更正**：先前把 `-10004 privilege violation` 当成「这条路走不通」，
> 其实拦的是终端 `osascript` 进程；只读 TCC.db 确认 `kTCCServiceAccessibility | app.smoose.macos |
> client_type=0 | auth_value=2` —— **Smoose 自己有辅助功能授权**（按 bundle id 授予，
> 同证书签名的探针可继承）。`last` 也证实用户并未真正注销重登，所以「等你注销」不是解法。
> ① `Probe/AXCursorZoomProbe.swift`（手动探针，不进 harness）：以 `app.smoose.macos` +
> `Apple Development: qm0819@hotmail.com (5F66DDWD6H)` 签名成 `/tmp/SmooseAXProbe.app`，
> 实测 `AXIsProcessTrusted()=true`，系统设置 Display 页里目标开关的稳定标识是
> **`AXIdentifier = AX_FIND_CURSOR`**（SwiftUI checkbox 的 title/description 是空的，
> 别按文案找）。`toggle` 实测：`AXValue 0 → 1 → 0`、plist `1 → 0 → 1`、两次 AXPress 均 rc=0。
> 说明 GUI 拨动会走系统写入通道并触发 WindowServer 重载，无需注销。
> ② `Sources/CursorZoom.swift` 新增 `CursorZoomSyncResult` / `CursorZoomSyncPolicy` /
> `CursorZoomSessionSync`：两步 URL 打开 Display 页 → 最多 4s 轮询找 `AX_FIND_CURSOR` →
> 当前为关时拨两次（关→开→关，中途短暂经过「开」只为触发写入）→ **四条硬门槛**缺一不宣称生效：
> 两次 AXPress 都成功、拨动后值确实变了、终态 `AXValue=="0"`、落盘 `CGDisable…=="1"`。
> 每个失败分支带具体原因（未授权 / 打开失败原因 / 找不到 / AXPress 错误码 / 无响应 / 终态不符），
> 成功文案也**不替用户宣称画面效果**，明确「请摇动鼠标确认，程序无法代你观测」。
> ③ `Sources/Views.swift` 指针页拆成两套状态：`系统偏好：…（进入本页时从系统读回）`
> 与 `本次会话：尚未重载 / …结果`，`.onAppear { syncZoomFromSystem() }` 每次进页都从
> cfprefsd 读回真值并同步本地缓存，消除「开关显示关、实物还在放大」的单一布尔假绿；
> 新增 `Button("立即生效（无需注销）")`，失败时显示红字 + 重试。
> ④ harness：P 段并入 S1–S25 纯逻辑断言（含 S10–S13 读不到值、S25 错误码优先级），
> P_W 补 PW22–PW35 接线守卫；新增 P_MUT5–P_MUT8 四趟变异并**逐条反向验证**：
> 短路四条硬门槛 → S4/S5/S7/S8/S9/S25 全红；只抹终态 → 仅 S8 红（S9 不误报）；
> 只抹落盘 → 仅 S9 红（S8 不误报）；成功文案改成「已生效，无需确认」→ S17/S18 红。
> 全量 **`PASS=63 FAIL=0`**（基线 59 + 4 趟变异）。
> ⑤ 部署验收：`build.sh` 编译签名通过 → `/Applications/Smoose.app`（备份 `/tmp/Smoose.app.prev-*`），
> `codesign --verify --deep --strict` 通过；二进制用 Python `bytes.count` 确认含
> `AX_FIND_CURSOR` / `立即生效（无需注销）` / `请摇动鼠标确认`（**别用 `grep -a` 搜中文常量，会漏报**）。
> 重启后 `open smoose://settings?tab=pointer`，用同签名 AX 探针读窗口文本，实测显示
> 「系统偏好：已关闭」「本次会话：尚未重载」；再 AXPress 点「立即生效」，
> 设置页变为「已让系统重新加载设置 ✓ 请摇动鼠标确认…」，plist 终值 `1`。
> **主 App 内 `AXIsProcessTrusted()` 为真、整条链路端到端跑通**。
> ⑥ **未发版**：`Info.plist` 仍是 1.4.5 / 12，本轮代码是「线上 1.4.5 + 会话同步」的本地构建。
> 用户已回「好了」确认摇鼠标不再放大（画面效果只能由人确认，程序不代用户宣称）；
> 复核时 plist=`1`、设置页仍显示 `.applied`。代码保持未发版，说「推送」后再抬版本发 Release。
> ⚠️ 残留限制：「本次会话」状态只在本次 App 运行内保留，重启 App 会回到「尚未重载」（保守，不假绿）；
> 画面效果本身程序观测不到，必须由人确认。
>
> **2026-11-07 第二十三轮（修「光标放大开启不生效」，未发版）**：用户截图显示
> 「快速移动鼠标时放大光标图标」开关是蓝色，但功能没生效。真机复现确认
> **键没写错**：系统设置里点该开关时全局域只有 `CGDisableCursorLocationMagnification`
> 变化（0↔1）、GUI 同步变色；但第三方只写 plist 后，系统设置 GUI 不刷新、切页重进也不刷新。
> Apple Developer Forums / Jamf 资料一致：该键由 WindowServer 在登录会话启动时加载，
> 改完需**注销 / 重启**才生效。旧 `CursorZoomController.apply()` 写完就返回、无读回校验、
> Toggle 立刻变蓝 —— **假绿**：显示「已开启」但实际功能没生效、也没有任何提示。
> 修复：写后用 `CFPreferencesCopyValue` **独立读回**（不用进程内缓存），
> 读不到 / 不一致判失败并让开关回弹 + 带具体原因的红字 + 重试；
> 写入成功也明确标「待重新登录生效」，并给「在系统设置里打开」按钮走系统自己的即时路径。
> **顺带抓出第二个假绿**：上一轮以为 `Seeing_Display` 能直达 `Display` 页，其实是连续
> 发三个 URL 时前一个导航残留；冷启动逐个复测 A `?Seeing_Display` / B `?display` /
> C `?Accessibility_Display` 及 `?pane=display` / `?page=display`，**全部只到 Accessibility 首页**。
> 可靠解法是两步：先发不带 anchor 的基础 URL 拉起进程，再发 `?display`
> （间隔 0.4 / 1.0 / 2.0s 三种都稳定到 `Display`）。
> 新增 harness **P 段 31 项 + P_W 21 条接线守卫 + P_MUT/P_MUT2/P_MUT3/P_MUT4 四趟变异**
> （恒绿写入判定 / 抹掉生效条件 / 换回旧 URL / 去掉两步法第一步，均按具体 case 报红），
> 全 harness `PASS=59 FAIL=0`。真机：点开关 plist 0→1→0（两次读回校验均通过）、
> 状态行显示「已写入系统偏好 ✓ 但 macOS 只在登录时加载它，需重新登录才生效…」；
> 冷启动点按钮 → 系统设置标题 `Display`、Pointer 区 Shake 开关可见、无报错弹窗。
> 新 Mach-O `d76f4f09…`，验签通过、TeamIdentifier `6U2DQJ6Z2N` 不变；备份
> `/tmp/Smoose.backup.20261107_015252.app`。**未发版、未提交**。详见 §4.13 / SPEC §33。
>
> **2026-11-07 收尾复核（非功能改动）**：重跑全量 harness `PASS=59 FAIL=0`；
> 把 harness 重建的 `build/Smoose.app` 与 `/Applications/Smoose.app` 逐字节比对，
> 两者同为 2038576 字节、仅末尾 258 字节（签名 / LC_UUID 区）不同，代码与只读数据一致
> —— 现役包确含第二十至二十三轮全部修复（关键文案字节级反查全命中）。
> `codesign --verify --deep --strict` 通过、TeamIdentifier 不变。
> 复核方法与两个会误导结论的坑见 §6.1c。该段记录的是复核当时的状态，
> 现已在第二十四轮随 v1.4.3 发版并推送。
>
> **2026-11-07 第二十二轮（修「点打开系统设置报错」，未发版）**：用户截图
> `You can't open the application "System Settings" because it is not responding.`
> （背景是别的 App 的 Welcome 页，不是 Smoose）。只读复现：`open` 旧 deep link 返回
> **-1712 AppleEvent 超时**，System Settings 进程 PID 778 已连续运行约 26h、
> 主线程停在事件等待不处理 AppleEvent —— **报错来自系统设置进程卡死，不是按钮的 URL 写错**。
> `killall "System Settings"` 后同一 URL 立即 `rc=0`，两次复测稳定。
> 顺带抓出第二个真 bug：旧 anchor `Privacy_Accessibility` 在 macOS 27.3 落到
> **Device Control and Data Access**，不是辅助功能授权列表；实测 ExtensionKit 真 ID
> `com.apple.settings.PrivacySecurity.extension` 才打开「隐私与安全性」。
> Smoose 的「去授权」同样中招：已换新 URL，并用 completionHandler 接住失败，
> 显示带具体原因的中文提示 + 「重试」+ 手动路径，不再把英文系统弹窗甩给用户、
> 也不静默吞掉失败。新增 `SettingsLauncher.swift`（已进 build.sh）、诊断入口
> `smoose://onboarding`（不动 TCC 就能复测引导页）。harness **O 段 14 项 + O_W 13 条
> 接线守卫 + 三趟变异**，全 harness `PASS=53 FAIL=0`。真机：点「去授权」→ 系统设置窗口
> 标题 `Privacy & Security`、无报错弹窗、引导页无红字与重试。Mach-O `f5bd2265…`，
> 验签通过、TeamIdentifier `6U2DQJ6Z2N` 不变（TCC 保留）；备份
> `/tmp/Smoose.backup.20261107_011302.app`。**未发版、未提交**。详见 §4.12 / SPEC §32。
>
> **2026-11-06 第二十一轮（鼠标硬件 DPI 快捷键切换后自动同步，未发版）**：用户要求
> 「用快捷键切换了鼠标 DPI 以后软件要同步」。真机探针纠正一次误判：
> `IOHIDDeviceOpen(None)` 并非收不到 HID++ 响应，独立进程预热后 **15/15** 读到当前 DPI；
> 当初的 0 响应只是接收器休眠（头 2–3 个请求超时 476/489/313ms，预热后单次 GET 约 25ms）。
> 查 Solaar `notifications.py`：**0x2201 没有 DPI 变更通知**（DPI 变化只在
> ONBOARD_PROFILES 的 resolution_index 事件里给索引、不带数值），所以只能主动 GET 当前值。
> 实现：`HIDPPDPISync` 纯决策 + `HIDPPWatchSession` 非独占长连接（300ms 轮询、3 次预热、
> 连续失败退避），`handleSyncReading` 只更新显示、**绝不回写硬件**；写入/重探前先停连接。
> **门禁不能含「App 是否前台」**：第一版加了 `appActive`，真机连拍第 41 帧起提问面板一抢
> 焦点就显示「自动同步已暂停」，而硬件 DPI 键恰恰在 Smoose 非前台时按，已删掉并在 N_W 加反例守卫。
> harness N 段 23 项 + N_W 26 条守卫 + 三趟变异，当时全 harness `PASS=48 FAIL=0`。
> **真机端到端**：用户按 DPI 键后独立探针读回 **14700**（原 5400），界面显示
> `鼠标快捷键切换 DPI → 14700 DPI（已同步显示，未回写硬件）`，当前硬件 DPI 与下拉框
> 均为 14,700；重启 App 后仍一致，硬件真值复读未被回写。详见 §4.11 / SPEC §31。
>
> **2026-11-06 第二十轮（修「内置触控板导致状态区整段红字」，未发版）**：上一轮顺带发现
> 勾了旧开关「同时应用到内置触控板」后，内建触控板不接受 `HIDMouseAcceleration = -1`
> （回读 0），`allOK=false` 把整个「状态」区标红 —— 是**假失败**：那台设备从未被接管。
> 修复：`PointerAccelPolicy.scope/eligible` 恒排除 builtIn（旧开关降级为存档兼容字段、
> UI 里那个没有载体的开关已移除）；跳过的设备**显式列出**「内建触控板由系统管理（不写入加速度）」，
> 且**不参与 `allOK`**（只收真正写入过的设备结果，空结果判红）。
> 新增 harness **M 段 16 项 + M_W 9 条接线守卫 + M_MUT/M_MUT2/M_MUT3 三趟变异**
> （触控板重新纳入写入 / 恒绿 / 抹掉跳过原因都必须报红），全 harness `PASS=43 FAIL=0`。
> 真机截图验收：状态区三行全为灰白（两行 USB Receiver 回读 -1.000 + 一行触控板跳过说明），
> 红字消失；罗技 0x2201 仍显示 100–25600 / 当前 5400 DPI。
> 新二进制 Mach-O sha256 `6b0fe9c8…`，`codesign --verify --deep --strict` 通过、
> TeamIdentifier `6U2DQJ6Z2N` 不变（TCC 授权保留）；备份
> `/tmp/Smoose.backup.20261106_233055.app`。**未发版、未提交**。详见 §4.10 / SPEC §30。
>
> **2026-11-06 第十九轮（修 HID++ DPI 档位只到 3200，未发版）**：用户指出鼠标 DPI
> 上限 **25600**，截图里 Picker 却只到 3200。深挖发现整条链路是假绿：`supportedDPIs`
> 与 `currentDPI: 1000` 全是硬编码、`setDPI` 把 feature ID 高字节 `0x22` 当 feature index、
> `0x03` 当 function、忽略 `IOHIDDeviceSetReport` 返回值并不看回显就显示「已应用硬件 DPI」。
> 真机探针（独立 Swift，报文对齐 libratbag `hidpp20.c`）：两个 `0xFF00` 接收器里
> **pid=0xc547 支持 0x2201（featureIndex=7）**，回报 **100–25600 DPI / 步长 50 /
> 当前 5400 / 默认 1600**；pid=0xc548 返回 index=0（明确不支持）。
> 修复：真实 `getFeature` 查 index → 后台同步 HID++ 会话读 count / DPI list / 当前 DPI →
> 档位由设备回报生成（含 25600）→ 写入用 `0x38` + 真实 index，**写后读回校验**才报绿；
> 探测失败/不支持不显示档位、拒绝写入。写入改显式「应用」按钮（`onAppear` 同步当前值
> 曾意外触发一次 SET）。新增 harness **L 段 30 项 + L_W 13 条 + L_MUT/L_MUT2**，
> 全 harness `PASS=38 FAIL=0`；幂等写入 5400→5400 真机 VERIFIED（未改动用户设置）。
> 新二进制已部署 `/Applications`（Mach-O sha256 `63d18d35…`），验签通过；
> 备份 `/tmp/Smoose.backup.20261106_225536.app`。**未发版**。详见 §4.9 / SPEC §29。
>
> **2026-11-06 第十八轮（二次纠正「静止后起步发黏」根因，未发版）**：用户明确是
> **挪指针发黏**，且把全部 HID 服务的 `HIDMouseAcceleration` 写成 0 后**仍然发黏**。
> 静置 70 秒采样读数恒为 0 —— 推翻 §4.5 的「系统把值重置成 163840、8 秒轮询补回」：
> 漂移根本没发生。真正根因：**0 只是「最小加速度」，不是「关闭加速」**，系统仍走
> 速度相关增益曲线（低速 <1 → 起步发黏、速度上来才跟手 = 用户说的「慢慢恢复正常」）。
> 核对 LinearMouse 源码后改为：线性模式写 **-1（IOFixed -65536）**，并尝试写
> `HIDUseLinearScalingMouseAcceleration=1`（Sonoma+ 线性缩放）；本机 USB Receiver
> 不支持该键（整数 / 布尔都写不进、读回 null），按 LinearMouse 的
> `supportsLinearPointerScaling` 语义回退到只靠 -1，**不算写入失败**。
> 另修「恢复系统默认」基线：改从 `IOHIDSystem.HIDParameters` 读全局默认（2.5），
> 不再把「App 启动时的设备读数」当默认（真机曾显示「系统默认 -1.000」）。
> 新增 harness **K 段 20 项 + K_W 接线守卫 + K_MUT / K_MUT2 两趟变异验证**，
> 全 harness `PASS=34 FAIL=0`；真机回读两个 USB Receiver 均为 -65536、状态区无红色警告，
> 静置 32 秒保持。新二进制已部署 `/Applications`（Mach-O sha256 `87099b52…`），
> `codesign --deep --strict` 通过；备份 `/tmp/Smoose.backup.20261106_223038.app`。
> **手感是否真的不再发黏仍需用户实测确认；未发版**。详见 §4.8 / SPEC §28。
>
> **2026-11-06 第十七轮（修「页面放大以后内容没放大」，未发版）**：用户反馈设置窗口拉大后
> 内容仍是一小坨、字号不变。根因：`SettingsWindow` 只有 `minWidth/minHeight` 下限，
> 各 Tab 的字号 / 间距 / 420pt 内容宽度全是硬编码点数，窗口变大只是把这块内容居中。
> 修复：新增 `SettingsLayout`（基准 560×620、2× 封顶、取宽高较小比例的等比系数）+
> `ScaledTabContent`（按逻辑尺寸布局后 `scaleEffect` 铺满），六个标签页全部接入；
> `TabView` 保持根视图 —— 真机验证过把整个 TabView 包进缩放容器会裁掉系统标签栏。
> 620 而非最初的 520 是「关于」页完整内容实测高度（520 会把说明压成单行、页脚裁掉），
> 另留 44pt 让位给系统标签栏（放在缩放之后，不参与等比）。
> 新增 harness **J 段 23 项 + J_W 接线守卫 + J_MUT 变异验证**，全 harness `PASS=30 FAIL=0`；
> 真机截图确认标签栏完整、说明两行、页脚可见、文字清晰无裁切。
> 新增本地诊断入口 `smoose://settings?w=1080&h=900`（脚本化设定窗口尺寸，非法值忽略）。
> 新二进制已部署 `/Applications`（Mach-O sha256 `fcfcec82…`），`codesign --deep --strict` 通过、
> TCC `auth_value=2` 保留；备份 `/tmp/Smoose.backup.20261106_211932.app`。**未发版**。详见 §4.7 / SPEC §27。
>
> **2026-11-06 第十六轮（修「鼠标静置后起步发黏」，未发版）**：用户反馈「鼠标停止一段时间后
> 再动非常慢，然后慢慢恢复正常」。根因不是预热/卡顿，而是 **HID 加速度被系统重置后 Smoose 看不见**：
> 配置 `pointerAccelManaged=true / value=0`（强制线性）依赖 `HIDMouseAcceleration` 持续为 0，
> 但鼠标省电挂起 / HID 重枚举时 macOS 会把它恢复成系统默认 `163840`(UI 2.5)；系统加速曲线是
> 速度相关增益，低速增益 < 1 → 起步黏，速度上来才「恢复」。旧 `apply(force:false)` 的签名只含
> 「配置值 + registryID 列表」，这两样都没变 → 60 秒兜底轮询永久短路，再也不纠正。
> 只读探针实测：罗技接收器两个 HID 接口（PID 50503 / 50504），一个 `0`、一个 `163840`，**两者都可写**。
> 修复：签名纳入设备当前读数、轮询 60s→8s 且不再全量枚举、IOHIDManager 插拔回调触发 force 重刷、
> 写后读回校验。新增 harness **I 段 14 项**，全 harness `PASS=27 FAIL=0`；真机端到端实测
> 人为把接口改回 2.5 后 **6 秒自动纠回 0**，退出 App 的负例 12 秒保持 2.5（排除「系统自己改回」）。
> 新二进制已部署 `/Applications`（Mach-O sha256 `7346f355…`），授权 `auth_value=2` 保留。详见 §4.5。
>
> **2026-11-03 第十五轮（参照 Mos / LinearMouse 优化轮，未发版）**：对照 `caldis/Mos`
> （Swift 重写后的 `Mos/ScrollCore/`：`ScrollCore` / `ScrollPoster` / `ScrollPhase` / `ScrollFilter` / `ScrollEvent`）
> 与 `linearmouse/linearmouse`（`EventTransformer/SmoothedScrollingEngine`）找差距，落地三件事：
>
> ① **合成事件带相位**（根因修复）。早期 `post()` 写出 `isContinuous=0`、`scrollPhase=0`、
> `momentumPhase=0` 的像素增量，消费端（Chrome / Safari / 原生 `NSScrollView`）看到的是
> 「物理鼠标滚轮 + 像素增量」，于是套用自己的行量化与动量，Smoose 调好的曲线被二次加工 ——
> 这就是「同一条曲线，Mos 里更跟手」的根因。现在按 Mos 的 `PhaseValueMapping` 写
> `isContinuous=1` + tracking/momentum 相位 + 零增量收尾帧。新增 `Sources/ScrollPhases.swift`
> （`ScrollPhaseValue` / `SyntheticScrollFields` / `ScrollPhaseFields.write` / `ScrollPhaseTracker`），
> 两个阈值 0.18s / 0.45s 对齐 Mos；详见 SPEC §26。
>
> ② **点击刹车**：左键按下立刻收掉滚动尾巴（含未走完的距离），并补一帧零增量收尾事件，
> 移植 Mos `mouseLeftEventCallBack → ScrollPoster.stop`。
>
> ③ **Launchpad / Dock 透传**：滚轮路径原来只放行了指针；Launchpad 寄宿在 Dock 进程
> （前台 bundle id `com.apple.dock`），合成滚动事件在里面不被识别，补上透传。
>
> 新增开关「模拟触控板滚动」（默认开，per-app 可覆盖；关掉则与 1.4.2 逐字节一致）。
> harness 增至**二十六段 `PASS=26 FAIL=0`**（新增 S36–S38 编译真源码 + S39 十三条接线守卫，
> 8 条变异验证全部报红）。**未发版**：`/Applications/Smoose.app` 是含本功能的工作副本。
> **2026-11-03 清理轮（收尾）**：Spotlight 搜 "sm" 的副本噪音已清——`/Applications` 的 7 个隔离备份
> `mv` 到 `~/.smoose-rollbacks/`（点号目录不进 Spotlight，保留回滚能力），`~/Downloads` 的 2 个重复副本
> + 1 个旧版 zip 移到 `~/.Trash/smoose-cleanup-2026-11-03/`，全程 `mv` 无 `rm`、带 MANIFEST 可还原。
> 运行中的 `/Applications/Smoose.app`（当时 pid 78294）与桌面别名未动，harness 复跑 `PASS=26 FAIL=0`。
> **最后更新：2026-10-31 第九轮（发版轮）**（发布 v1.4.0 带来三大能力落地：
> ① 自动更新端到端真机实测闭环完成，`replaceApp` 引入注入与回滚契约，补齐 H26–H28 断言（解开 §7 长期未决项）；
> ② 滚轮加速快捷键（Scroll Boost）全面落地，按住指定修饰键临时放大倍率，离散/平滑无缝收拢（S1–S8）；
> ③ 滚动曲线可视化预览（ScrollCurvePreview）在设置页与菜单栏实时渲染 0–500ms 归一化插值位移与 95% 到位耗时（S9–S17）；
> 版本抬升至 1.4.0 → harness 升级至十四段 `PASS=14 FAIL=0` → 已部署至 `/Applications/Smoose.app`）。
> 上一轮 **2026-10-28 第五轮** 攻破的是「受限环境编译不了 Swift 宏」这条长期限制：
> `swiftc -disable-sandbox` → 全量编译 / 完整 harness 都能跑。
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
> **2026-10-31 第七轮（发版轮）**：第六轮的优化此前只存在于源码与本地构建里，用户的自动更新还只会拿到 v1.2.1。
> 本轮把版本抬到 `1.2.2`（`Resources/Info.plist` 的 `CFBundleShortVersionString` + `CFBundleVersion` 3→4），
> 跑 `./scripts/release.sh --github --repo cpufreestyle/Smoose` 重新签名打包并发布 Release `v1.2.2`
> （**必须重跑 release.sh 重建签名，不能用 plutil 改已签名包的版本号** —— `_CodeSignature` 会不符被拒）。
> 逐段复核发版链路（SPEC D18）：asset sha256 `81565ba6…` 与产出端一致、真源码 `decide` 对 current 1.2.1 解出
> `available(1.2.2)`、下载包签名有效且 Team ID 对齐。部署到 `/Applications` 用 ditto 配方 + 可逆隔离旧包
> （`mv Smoose.app Smoose-1.2.1-predeploy.app`，不用 `rm`），运行版本 1.2.2、二进制 sha256 `e3b0126a…`、
> 辅助功能授权 `auth_value=2` 保留、启动无崩溃。完整 harness 重跑 `PASS=13 FAIL=0`。
> 顺带修掉一处文档漂移：SPEC D11 自称「当前 harness 状态」却停在 `PASS=11`，与 D16/D17 的 13 矛盾，已改为
> 「段数演进快照，当前值以 D17 为准」。
> ⚠️ **本轮踩到的环境坑（记给接手人）**：用 `nohup … & disown` 起的后台 harness 会在工具调用结束时被会话回收杀掉，
> 且 `build.sh` 是 `rm -rf build` 再编译 —— 被杀时 `build/Smoose.app` 会停在只有 `AppIcon.icns` 的半成品状态。
> 跑完整 harness / release 要用常驻 PTY 会话（前台 `tee`），别用 nohup 后台；被打断后先重跑 `./build.sh` 复原产物。
>
> **2026-10-31 第八轮（1.2.3 + 1.3.0 连发）**：两轮小修。**1.2.3** 修「GUI 无法调整大小」——
> `SettingsWindow` 根视图固定 `.frame(width:560,height:520)` 把 `NSHostingView` 约束锁死，改为
> `.frame(minWidth:560,minHeight:520)`；同时把工作区里未推送的罗技 HID++ 直控
> （`Sources/LogitechHIDPP.swift`）、`TouchEvents.c` 原生轻扫手势、PointerTab 罗技 Section、
> Cursor Forge Lab 入口一并入库（远端 `3dbde7f`）。**1.3.0（用户钦定版本号，后续顺延）** 修
> 「窗口放大后内容不跟随」——关于页所有 `.frame(width:380)` 固定宽度改 `maxWidth:420`（随窗口拉伸），
> 版本源输入框 `maxWidth:340`；菜单栏面板 `width:330` 改 `minWidth:330`。
> `Info.plist` 曾被外部改成 1.3.0/5（非操作产生），1.2.3 曾临时纠回 1.2.3/5，1.3.0 正式定为 `1.3.0/6`。
> Release `v1.3.0` 已发：asset sha256 `7db37abe…`（932976 字节）与产出端逐字节一致，下载包
> `codesign --deep --strict` 通过、TeamIdentifier 对齐。部署 1.3.0 运行正常（二进制 sha256 `d1056d36…`），
> harness `PASS=13 FAIL=0`。隔离备份链：`Smoose-1.2.1-predeploy` / `-1.2.3-pre-130` /
> `-1.3.0-wrongver`（外部错误版本留证）。
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

> 下表前半段保留了历史快照；**当前实测以 `/Applications` 的 1.5.0 / build 14 和
> 2026-11-15 反编译审计轮记录为准**。旧行里的 1.4.2、`PASS=27` 等数字是当时版本，不再是现值。

| 项 | 状态 |
| --- | --- |
| 当前实测（2026-11-15） | `/Applications/Smoose.app` = **1.5.0 / build 14**，Mach-O sha256 `7e5ecc32bc6b0bc119da79af0d614303fed7fef8177e7531d6a32ce1617f1e39`，进程 pid 70747；源码 18 个 Swift 编译单元，全量 harness **PASS=104 FAIL=0**；本轮修距离守恒、加斜向锁定，并落地首屏状态条 / 一键诊断 / 简易高级模式 / 新增应用模板，未改版本号、未发版。 |
| 位置 | `/Users/a1-6/AI Shared/repo/Smoose/` |
| 功能完整性 | 滚动平滑 / 倍率 / 双轴 / 每应用 / 按键绑定 / 指针加速度 / 指针速度倍率 / 侧键动作 / 指针放大 / 游戏性能检测 / 合成事件触控板相位 / 点击刹车 全部已实现 |
| 已编译产物 | `/Applications/Smoose.app` 版本 **1.4.2**（**2026-11-01 v1.4.2 发版后部署**）。Mach-O 二进制 sha256 `d88b72054548a30bd49446447388df719bd919117fa662a31ab9e8456bc30dca`（1.4.2 发版部署后实测）。**2026-11-02 起 `/Applications/Smoose.app` 是未发版的工作副本**：2026-11-02 含游戏性能检测（Mach-O sha256 `cb00dbd3105ec7da…`）；**2026-11-03 第十五轮后含合成事件相位 + 点击刹车 + Dock 透传，Mach-O sha256 `f10ff7a677dbab1686639b90af85489e3227bfb3dff351f744c5e1f825d4358e`**（`codesign --verify --deep --strict` 通过、`TeamIdentifier=6U2DQJ6Z2N`、辅助功能授权 `auth_value=2` 保留、`open -a` 启动无崩溃、`smoose://settings?tab=scroll` 弹出 560×548 设置窗），`codesign --verify --deep --strict` 通过、`TeamIdentifier=6U2DQJ6Z2N`、辅助功能授权 `auth_value=2` 保留、启动无崩溃、真机预览四项指标均为真实数据）。含 10-26 安全加固、10-27/10-28 修复、10-29 upToDate 反馈与六项优化、10-31 罗技 HID++ 直控 + 原生轻扫手势、窗口可调整大小（1.2.3）与内容自适应（1.3.0）、滚轮加速快捷键（1.4.0）、滚动曲线实时预览（1.4.0）；`codesign --verify --deep --strict` 通过、`TeamIdentifier=6U2DQJ6Z2N` 与客户端期望一致、辅助功能授权 `auth_value=2` 保留、启动无崩溃。隔离备份链（2026-11-03 清理轮已整体移至点号目录 `~/.smoose-rollbacks/`，不进 Spotlight，保留回滚能力；目录内 `MANIFEST.txt` 逐条记录版本 / build / sha256 / 体积 / 理由）：`Smoose-1.2.1-predeploy.app` / `Smoose-1.3.0-pre-140.app` / `Smoose-1.4.0-pre-141.app` / `Smoose-1.4.1-pre-deploy.app` / `Smoose-1.4.2-pre-deploy.app` / `Smoose-1.4.2-pre-gameperf.app`（含游戏功能前的最后一个可用版，可回滚）/ `Smoose-1.4.2-pre-phase.app`（含本轮相位功能前的最后一个可用版，Mach-O `cb00dbd3…`，可回滚）。自动更新端到端安装已真机闭环实测（D20）。部署用 ditto 配方，见 §6.1a。**2026-11-06 第十六轮重新部署**（含加速度漂移修复，未发版），Mach-O sha256 `7346f355db861bd135e9133a0b18ca849f5b37f04d85803ee7e51cfe51e173ff`，`PASS=27 FAIL=0`，真机端到端 6s 自愈已验证 |
| 源码 | `Sources/*.swift` **14 个文件**（2026-11-03 新增 `ScrollPhases.swift`，相位纯逻辑约 190 行；2026-11-01 时为 12 文件 3971 行，其后新增游戏性能检测约 480 行 + Model/App/Views/ScrollEngine 改动；总行数以 `./build.sh` 编译清单为准） |
| 构建 | `build.sh`（签名身份三级回退：`SMOOSE_SIGN_ID` → 自动探测本机 Apple Development 证书 → ad-hoc 并警告） |
| 发布 | `scripts/release.sh`（打 zip + 自检 + 可选发 GitHub Release） |
| 验证 | `run_tests.sh`（harness，A/B/C/D/E/F/F2/G/G2/G2b/G2c/G3/S/S18-S24/S25-S27/S28-S31/**S32-S35/S36-S39**/H/**I** **二十七段**，2026-11-06 `PASS=27 FAIL=0`；I 段 14 项验加速度签名对 HID 参数漂移敏感（含变异验证）；H 段已补 H31–H41 游戏性能检测断言，S35 为游戏页 URL 直达守卫，**S36–S39 为合成事件相位 / 点击刹车 / 接线守卫**）、`Tests/InterpTest.swift`、`Probe/main.swift` |
| 规格 | `SPEC.md`（契约 + 断言，见 §9 落位规则） |
| 版本源 | GitHub `cpufreestyle/Smoose`（public，已发 v1.1.0 / v1.2.0 / v1.2.1 / v1.2.2 / v1.2.3 / v1.3.0 / v1.4.0 / v1.4.1 / v1.4.2 / **v1.4.3**，**latest = v1.4.3**（2026-11-07，asset sha256 `c2d6daec…`）；**版本号从 1.4.0 起顺延**） |

入口形态：**纯 AppKit**，不是 SwiftUI `App` 协议。详见 §3。

> **2026-11-03 清理轮（Spotlight 副本噪音收尾）**：用户截图反馈 Spotlight 搜 "sm" 出现一堆 Smoose 副本。
> 本轮把 `/Applications` 的 7 个隔离备份整体 `mv` 到 `~/.smoose-rollbacks/`（点号开头目录不进 Spotlight，
> 保留回滚能力；`MANIFEST.txt` 逐条记录版本 / build / sha256 / 体积 / 理由），`~/Downloads` 的 2 个重复副本
>（与 `Smoose-1.3.0-pre-140.app` 逐字节相同的旧 1.3.0 构建，sha `d1056d36…`）+ 1 个 `Smoose-1.3.0.zip`
>（sha256 `7db37abe…`，GitHub Release v1.3.0 已有）移到 `~/.Trash/smoose-cleanup-2026-11-03/`（同样带 MANIFEST）。
> 全程 `mv` 无 `rm`，可还原。运行中的 `/Applications/Smoose.app`（1.4.2 工作副本，当时 pid 78294）
> 与桌面别名未动。其他位置已复查无残留（`/Applications/Smoose.app.new` 不存在，仓库 `Probe/` 是 harness
> 引用的活探针、`build/` `dist/` 是 gitignore 产物，均保留）。清理后 harness 复跑 `PASS=26 FAIL=0`。
---
> **2026-11-02 清理轮（workspace 瘦身）**：把 36 项冗余产物移到 `~/.Trash/smoose-cleanup-2026-11-02/`（含 `MANIFEST.txt`，逐条记录原路径 / 体积 / 理由，可整体拖回还原）。仓库 23M → 4.0M。
> 归档内容：`dist/` 里 4 个旧预部署 `.app` + 9 个旧版 zip + 7 个旧 json、`/Applications` 里 9 个**未记载**的额外备份、桌面 5 个 `.MichaelClip.app.old.*` 隐藏副本 + `.DS_Store`、`/tmp/smoose_git_sync_140` 临时克隆；另 `rmdir` 了空的 `logs/`。
> **上表记载的 5 项回滚备份链一个没动**（`-1.2.1-predeploy` / `-1.3.0-pre-140` / `-1.4.0-pre-141` / `-1.4.1-pre-deploy` / `-1.4.2-pre-deploy`），`dist/Smoose-1.4.2.zip` 保留（F 段需要）。清理后 harness 复跑 `PASS=23 FAIL=0`。
> 未动：`~/Desktop/MichaelClip.app`（旧版 v2.2.0 实例，**当时正在运行**，PID 34021，bundle id `com.michaelqiu.clip` 与 Smoose 的 `app.smoose.macos` 不同）——要一并清掉需先退出该进程。
---

> **2026-11-02 游戏性能检测轮（SPEC §25）**：新增 `Sources/GamePerf.swift`，设置窗口加「游戏」tab，
> 采集全部复用已有回调（CGEvent tap + CVDisplayLink），对 Smoose 自身零额外系统开销。
> 真机预览四项指标均为真实数据：G502 X 接收器 1000 Hz / 内置触控板 125 Hz（IORegistry 实读）、
> 指针事件率 744 Hz、移动抖动 p50/p99/max = 0.38/7.94/42.20 ms、
> 指针延迟 p50/p99/max = 0.07/0.73/1.62 ms、显示 120.2 Hz 掉帧 0.0%。
> **本轮修掉两个真 bug**：① `recompute()` 里 `for i in 1..<count` 在空数组时构成 `1..<0`，
> 启动后第一次定时器 tick 即 SIGTRAP，表现为「点桌面图标完全没反应」；
> ② `CGEvent.timestamp` 时基不统一 —— HID 事件是 mach tick，经 `CGEvent.post()` 注入的事件是
> **开机以来纳秒数**（比值恰为 timebase 125/3），导致指针延迟恒 0、事件率被算小 41.67 倍、
> 2 秒窗口过滤整体失效。旧交接文档「timestamp 与 mach_absolute_time 同时基」只对 HID 事件成立，已作废。
> 另修 harness 假绿：H/D 段只 `grep '^FAIL'` 时，编译产物崩溃（`Fatal error:` 不以 FAIL 开头）也算通过，
> 现要求退出码 0 且打出 H-OK / D-OK。harness 增至二十二段 `PASS=24 FAIL=0`，
> H31–H41 变异验证 12/12 报红（两条等价变异暴露了「未环绕快照」测试盲区，已补 H32l）。
> 新增 `smoose://settings?tab=<name>` 可直达任一标签页（预览 / 远程诊断用，AppleScript 点 tab 不可靠）。
> **未发版**：版本仍 1.4.2，新功能还没走发版流程。
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
  （`SMOOSE_SWIFT_EXTRA=-disable-sandbox ./run_tests.sh` → **`PASS=13 FAIL=0`**，2026-10-31 实测），
  验的是真源码不是逻辑副本。10-28 那趟是 11 段，此后 G2b（10-29）与 G2c（10-29 优化轮）各加一段。
  此前（10-27）只能用退化手段：本沙箱编译不了含 SwiftUI 宏的 Views/App/CursorZoom，改用不含宏的
  7 文件子集 + H 段真实 `main.swift` 编译执行。该手段现在只用于「想快一点拿到反馈」。
- **计数器别混**：H 段自己有 25 条断言；`PASS=13 FAIL=0` 是整个 harness 的 **13 个 stage** 全部通过。
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
| 每应用配置 | 按 bundle id 单独配置，或一键套预设；新建规则时聊天类 App 自动套「聊天软件」档（`chatBundleIDs` 白名单） |
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

> ⚠️ **2026-11-06 二次纠正：下面「加速度不是设一次就永久生效」整节的根因结论已被推翻。**
> 静置 70 秒采样读数恒为 0、把所有 HID 服务也写成 0 后用户仍反馈发黏，说明系统并没有
> 周期性把值重置回 163840。真正病根是「写 0 ≠ 关闭加速」（见 §4.8）。
> 本节记录的「读数签名 / 8 秒轮询 / 插拔回调」作为防御性兜底保留（设备重枚举确实会丢参数），
> 但**不要再把它当成「起步发黏」的解释**。

- 参数都是 IOFixed（16.16）：`HIDMouseAcceleration = 163840` → 2.5。
- **老路线 `IOServiceOpen(IOHIDSystem, kIOHIDServerConnectType)` 在现代 macOS 被拒（返回 `0xE00002BD`）**，必须走 `IOHIDEventSystemClientCreateSimpleClient` + `IOHIDEventSystemClientCopyServices` + `IOHIDServiceClient*`。
- 每个设备的加速度存在哪个键由 `HIDPointerAccelerationType` 指定（外接鼠标 = `HIDMouseAcceleration`，触控板 = `HIDTrackpadAcceleration`）。
- 写回：`IOHIDServiceClientSetProperty(device.client, accelKey, NSNumber(value: Int(want * 65536)))`（返回 `Bool`，不要写 `!= 0`）。
- **`HIDPointerResolution` 只能从 IORegistry 读到、写不回去** —— 这是「速度」不能在 HID 层做的原因，才有 §4.6。

#### ⚠️ 加速度不是「设一次就永久生效」（2026-11-06 实测，别再退回旧写法）

`pointerAccelerationValue=0` 是往 HID 设备写参数，而 macOS 在**鼠标省电挂起 / 唤醒 / HID 重枚举 /
显示器休眠**时会把它恢复成系统默认（`163840` = UI 2.5）。恢复后系统加速曲线是速度相关增益：
低速移动增益 < 1 → 起步特别黏，速度上来增益才爬升 —— 这就是用户说的「慢慢恢复正常」，
不是预热、不是卡顿，也没有东西在「恢复」。

旧实现的致命组合：重刷只有四处（App 启动 `force:true`、配置变更通知、`didWakeNotification`
**仅整机睡眠**、UI 手点「重新检测」），而 60 秒兜底轮询被 `apply` 的签名短路挡掉 ——
签名只由「配置值 + registryID 列表」组成，**不含设备实际读数**，系统改了值它完全看不见。
写入失败过一次也一样：签名已被标成「已应用」，之后永久不重试。

现在（§4.5 修复后）：
- `PointerAccelSignature.make` 把每个 eligible 设备的**当前加速度读数**纳入签名；
  `apply(force:false)` 存的是「全部符合期望」的签名，所以没漂移时短路、漂移时必重写。
- 兜底轮询 **8 秒**，且只调 `apply(force:false)`（读属性 + 对漂移设备写），**不再全量枚举 IOKit**。
- `IOHIDManager` 的 matching / removal 回调触发 `refresh(force:true)`（0.15s 合并，
  一个接收器常连着冒好几个回调），覆盖「鼠标自己睡了又醒」——`didWakeNotification` 盖不到这条。
- 写后读回比对期望 IOFixed；`setProperty` 返回 true 但值没落地也判失败，
  且一台都没管住时 `lastWriteOk=false`（旧实现全跳过也报绿）。

真机实测：人为把 `rid=4294972593` 改成 163840 后 **6 秒自动纠回 0**；退出 App 的负例
12 秒保持 163840，排除「系统自己改回 0」。harness I 段 14 项 + 变异验证（把读数从签名
移除后 I2/I3/I4/I11b/I14 五条变红）守住这条契约。

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

### 4.7 设置窗口放大后内容等比联动（2026-11-06，`Views.swift` / `App.swift`）

**现象**：用户把设置窗口拉大后，内容仍是原来那一小块居中，字号一点没变。

**根因**：`NSWindow` 带 `.resizable`，`SettingsWindow` 早就从固定 `frame(width:height:)`
改成了 `minWidth/minHeight` 下限（当时只解决了「拖不动」，没解决「内容不跟随」）。
但各 Tab 的字号、`VStack` spacing、`frame(maxWidth: 420)` 全是硬编码点数，
窗口变大只是把这块 560×520 的内容居中，四周留白。

**修复**：

1. `SettingsLayout`（纯函数，可单测）：`baseWidth=560`、`baseHeight=620`、`maxScale=2.0`；
   `uiScale(w,h) = clamp(min(w/560, h/620), 1...2)`，取两个方向较小的比例，保证不裁切；
   `logicalSize(w,h) = (w/s, h/s)`，放大后的视觉尺寸恰好等于窗口尺寸。
2. `ScaledTabContent<Content>`：每个标签页单独包一层 `GeometryReader`，
   内容按 `logicalSize` 布局 → `.scaleEffect(s, anchor: .topLeading)` → 外层 frame 铺满。
   **只包页面内容，绝不包 `TabView` 本体**：macOS 的 TabView 标签栏由窗口 toolbar 参与布局，
   包住整个 TabView 后标签栏会跑到内容区之外被裁掉（第一版真机截图就是这样，已回退）。
3. `baseHeight` 取 620 而不是窗口最初的 520：「关于」页完整内容约 617pt，
   按 520 排版会把长说明压成单行加省略号、页脚「开源致敬」被裁。同时给该说明加
   `.fixedSize(horizontal: false, vertical: true)` 保证两行。
4. `tabBarInset = 44` 放在 `scaleEffect` **之后**：`scaleEffect` 会吃掉 SwiftUI 的 safe area
   inset，图标会顶到标签栏上；44pt 是固定的实际点数，不参与缩放。可用高度先扣掉它再算 s。
5. `App.swift`：NSWindow 初始 contentRect / `minSize` 都改用 `SettingsLayout.baseWidth/baseHeight`，
   避免两处基准漂移。
6. 本地诊断入口 `smoose://settings?w=…&h=…`（`SettingsLayout.debugWindowSize`）：
   没有 UI scripting 权限的环境里用它脚本化设窗口尺寸验证缩放；只接受 300…4000，
   其余忽略，不影响正常开窗。可配 `?tab=about`。

**取舍**：只把窗口拉宽而高度不变时 s 仍为 1（内容横向铺开但字号不变）——
按宽度放大必然裁掉纵向内容，宁可留白不裁切。「关于」页的 420pt 内容块仍是居中固定宽，
所以放大后左右仍留白，但留白比例从原来的 ~61% 降到 ~25%。

**验证**：harness 新增 J 段 23 项（封顶 / 裁切不变量 / 防御 / 诊断入口）、
J_W 接线守卫（六个页全包 `ScaledTabContent` + `TabView` 保持根视图）、
J_MUT 变异验证（把 `uiScale` 换回恒 1× 后 J2/J3/J4/J14/J15 必须报红），
全 harness `PASS=30 FAIL=0`。真机截图（1080×900）确认标签栏六个标签完整、
蓝色图标不压标签、说明两行、页脚可见、文字清晰、无裁切。

> 部署事故备忘：一次 `build.sh` 失败后仍继续执行了部署链（`&&` 链被 `for …; done;` 打断），
> 空产物覆盖了 `/Applications/Smoose.app`。已用备份恢复并改为 `set -e` + 部署前
> `[[ -s Mach-O ]]` 前置检查。**部署前必须验产物存在且 `codesign --verify` 通过。**

### 4.8 「静止后起步发黏」真正根因：0 ≠ 关闭加速（2026-11-06，`PointerController.swift`）

**用户反馈**：鼠标静置后再挪，起步迟钝、位移偏小，连续动一会儿才跟手；前两轮按
「HID 参数被系统重置」修过，用户第三次明确说「启动慢问题没修复」。

**推翻旧结论的证据链**（不要再靠猜）：

1. `hidutil property --matching '{"PrimaryUsagePage":1,"PrimaryUsage":2}' --get HIDMouseAcceleration`
   精确匹配鼠标后两个 USB Receiver 都是 **0**；不带 matching 列出的 163840 是其它 HID 服务，
   不是鼠标，容易误判。
2. 静置 **70 秒每 2 秒采样**，两个接口恒为 0，从未变成 163840 → 旧根因「系统周期性重置」不成立；
   上一轮所谓「6 秒自动纠回」其实是拿一次人工注入的漂移当成了日常复现。
3. 可逆实验：把**全部** HID 服务的 `HIDMouseAcceleration` 从 163840 改成 0，用户反馈**还是黏**。
   （实验后已用 `/tmp/restore_hid.swift` 精确还原 137 个非鼠标服务，鼠标设备留给 App。）
4. `IOHIDSystem.HIDParameters.HIDMouseAcceleration=163840`、`com.apple.mouse.scaling=2.5`
   是全局默认字典；设备实例属性与全局默认不是一回事，别拿全局值当「没写进去」的证据。

**真正根因**：`HIDMouseAcceleration = 0` 在 macOS 语义里是「最小加速度」，**不是关闭加速**。
系统仍按速度相关增益曲线处理，低速增益 < 1，所以起步特别黏、速度上来才「恢复正常」。
用户说的「慢慢恢复」是**同一次移动内速度上升**，不是等待 App 轮询补回 —— 时间尺度完全不同。

**LinearMouse 源码核对**（`Modules/PointerKit/Sources/PointerKit/PointerDevice.swift`、
`LinearMouse/Device/Device.swift`）：

- `pointerAcceleration` 取值 `[0,40] ∪ {-1}`，注释明确：`-1 means acceleration and sensitivity are disabled`；
  `setPointerAcceleration(-1)` 写 `IOFixed(-1 * 65536) = -65536`，即 1:1 线性。
- macOS Sonoma+ 另有 `useLinearScalingMouseAcceleration`：设备实例写
  `HIDUseLinearScalingMouseAcceleration=1` 才切线性缩放路径；`Device.supportsLinearPointerScaling`
  由 `initialUseLinearScalingMouseAcceleration != nil` 判断，**读不到就回退到只写 -1**。
- `getSystemProperty` 用的是 `IOServiceOpen(..., kIOHIDParamConnectType, ...)`，
  与本项目早年被拒的 `kIOHIDServerConnectType`（0xE00002BD）不是同一个连接类型。

**修复**：

1. `PointerAccelPolicy.plan(value:)`：UI 值 0 → `(ioFixed: -65536, linear: 1)`；
   > 0 → `(Int(value*65536), 0)`（自定义加速度时关掉线性缩放）。
2. `apply()` 对每台设备**双写**：先 `HIDUseLinearScalingMouseAcceleration`，再 `accelKey`；
   写后读回两者，`PointerAccelSnapshot.linear` 也纳入签名（设备重枚举丢标志时能发现）。
3. **本机实况**：`HIDUseLinearScalingMouseAcceleration` 写入回显成功但读回恒为 `(null)`
   （`hidutil --set` 用整数 1 / 布尔 true 都一样）。`PointerAccelPolicy.linearOutcome` 按
   LinearMouse 的 `supportsLinearPointerScaling` 语义把「不支持」判为**回退成功**，
   否则状态区会常驻红色「写入未生效」，且失败态被写进签名后短路 —— 又是一次假绿。
   支持该键的设备仍会写 1 并校验；写入失败会存实际回读值以便下轮重试。
4. `systemDefaultAcceleration()`：`IORegistryEntryFromPath("IOService:/IOResources/IOHIDSystem")`
   → `HIDParameters["HIDMouseAcceleration"]`（本机 163840 = UI 2.5）。
   旧实现把「首次枚举时的设备读数」当系统默认，App 重启后读到自己写过的 0 / -1，
   界面显示「系统默认 -1.000」，点「恢复系统默认」等于没恢复。`restoreDefaults()`
   现在同时还原加速度和线性标志。
5. UI：设备行显示「线性 1:1 / 线性缩放 开|关|无」，滑条 help 明说「只写 0 不会关闭加速曲线」。

**验证**：harness 新增 K 段 20 项（-1 / 线性标志 / 签名含标志 / 回退语义 / 顺序无关）、
K_W 接线守卫（apply 双写、读回、签名、restore、全局默认基线）、
K_MUT（把 plan 换回「恒写 0」→ K1/K2/K6 报红）、
K_MUT2（把「硬件不支持」误判为失败 → K16/K19 报红）；全 harness `PASS=34 FAIL=0`。
真机：两个 USB Receiver 回读 `-65536`、线性键 `(null)`（回退路径）、状态区灰色无警告、
`codesign --verify --deep --strict` 通过、静置 32 秒参数保持。

**仍需人工确认**：`-1` 是否真的消除「起步发黏」只能靠手感；若线性后指针整体变快/变慢，
用「自定义移动速度倍率」滑条补偿（Event Tap 改 delta，§4.6）。**未发版**。

### 4.9 HID++ 0x2201 真实 DPI 能力（2026-11-06，`LogitechHIDPP.swift` / `Views.swift`）

**用户反馈**：「我这个鼠标的 DPI 最高有 25600」，截图里罗技区 Picker 却只有
400…3200 DPI。表层是档位表不够长，实质是**整条链路从未真正工作过**。

**旧实现的四处假绿**（都要记住，别再犯）：

1. `scan()` 里 `currentDPI: 1000`、`supportedDPIs: [400,...,3200,4000]` 是写死的，
   且 UI 根本没用这个字段，Picker 另有一份 `[400,...,3200]`。
2. `statusMessage = "已连接 Logitech USB Receiver (支持 HID++ 2.0)"` 只凭
   `usagePage == 0xFF00` 推断，从没向设备查询过 feature。
3. `setDPI` 报文 `req[2] = 0x22`：那是 feature **ID** 的高字节，不是 feature **index**；
   `req[3] = 0x03` 也不是合法 function（address 应为 `(fn<<4)|swId`）。
4. `_ = IOHIDDeviceSetReport(...)` 丢弃返回值，不等响应、不读回，随后无条件
   `statusMessage = "已应用硬件 DPI: \(target)"` 并改本地 `currentDPI`。

**真机探针取证**（`/tmp/hidpp_probe.swift` / `hidpp_dpi4.swift` / `hidpp_roundtrip.swift`）：

- 本机两个 `0xFF00` HID++ 接口：`pid=0xc547` 的 `getFeature(0x2201)` 回报
  `11 01 00 08 07 00 02` → **featureIndex = 7**；`pid=0xc548` 回报 index **0 = 不支持**。
  所以「对所有罗技设备无差别下发」本身就是错的。
- HID++ 2.0 的 `address = (function << 4) | 0x8`，0x2201 的四个 function 落到
  `0x08`（sensor count）/ `0x18`（DPI list）/ `0x28`（当前 DPI）/ `0x38`（写入）。
  报文格式对齐 libratbag `src/hidpp20.c` 的 `CMD_ADJUSTABLE_DPI_*`，DPI 为 big-endian 原始值。
- `GET_SENSOR_DPI_LIST` 响应 `00 00 64 e0 32 64 00…`：`p[0]`=sensor0，
  `0x0064`=100、`0xE032`=步长 50（>0xE000 的项是步长编码）、`0x6400`=**25600**、`0x0000` 结束。
  `GET_SENSOR_DPI` 响应 `00 15 18 06 40` → 当前 **5400**、默认 **1600**。
- 响应有延迟（第一次常常超时，第二次才回），必须重试；`IOHIDDeviceOpen` 用
  `kIOHIDOptionsTypeSeizeDevice` 才稳定拿到响应，用完必须 `close`。

**修复**：

1. 新增 `HIDPPDPIParser`（`parseList` / `parseCurrent` / `selectableDPIs` / `setRequest`）与
   `HIDPPDPIWrite.verdict`（纯函数，可离线断言）。档位 = 设备回报的具体档位 +
   落在 `[min,max]` 且对齐步长的常用档位 + 当前值，天然包含 25600。
2. `HIDPPSession`：后台串行队列上的同步 request/response（注册 input report 回调 +
   当前线程 run loop 等待），不阻塞主线程；`probeGeneration` 作废过期探测结果。
3. `LogitechHIDPP` 状态机 `DPIProbeState`：`.ready` 才显示档位；`.unsupported` /
   `.failed` 显示原因、**不显示档位、拒绝写入**；不再假称「支持 HID++ 2.0」。
4. `setDPI` 用真实 featureIndex + `0x38`，检查 `SetReport` rc、设备回显
   （`echo==0` 允许协议 v0 不回显），再发 `0x28` 读回；只有 `readBack == target` 才
   显示「已应用…（读回确认）」并更新当前值，否则显示具体拒因且**不改本地状态**。
5. UI 改为「Picker + 显式『应用』按钮」。第一版用 `onChange(of: selectedDPI)` 自动下发，
   真机截图抓到「只是打开页面」就因为同步当前值触发了一次 SET；L_W 的 LW11 专门守这条。
6. 游戏页「设备参数」说明同步修正：传感器 DPI 不在 IORegistry，但**可以通过 HID++ 0x2201 实读**
   （旧文案「macOS 读不到，所以这里不显示 DPI」已证伪，见 SPEC §25 的推翻标注）。

**验证**：harness 新增 L 段 30 项（真机响应字节 → 100/25600/步长 50/当前 5400、
`0x38` 报文与 0x6400 大端、写入判定五类拒因、解析防御）、L_W 13 条接线守卫
（无硬编码档位 / 真实探测 / 失败不报绿 / 写入必须显式）、L_MUT（报文失败仍报绿 → L23 红）、
L_MUT2（featureIndex 写死 0x22 → L16/L17 红）；全 harness `PASS=38 FAIL=0`。
真机：App 内探测显示「HID++ 0x2201 已探测: 100–25600 DPI (步进 50)，当前 5400 DPI」，
Picker 5,400 DPI + 应用按钮；独立幂等写入 5400→5400 回报 `11 01 07 38 00 15 18`，
回显 5400、读回 5400 → VERIFIED（**未改动用户硬件设置**）。
`codesign --verify --deep --strict` 通过。

> **顺带发现 → 已在下一轮（§4.10）修复**：指针页「状态」区整段红字，第三行
> `Apple Internal Keyboard / Trackpad … 回读 -0.000 … ⚠️ 写入未生效`。
> 根因是用户勾了「同时应用到内置触控板」，而内建触控板不接受 `HIDMouseAcceleration = -1`，
> 于是 `allOK=false` 把整段标红。属上一轮（§4.8）遗留，与本轮 DPI 无关；
> 第二十轮按候选方案让 builtIn 设备不参与加速度写入、也不参与 `allOK` 判定。

**未覆盖**：写入验证是幂等的（写当前值），未实测「改成另一个 DPI 值」是否生效；
不擅自改动用户硬件设置。若设备休眠导致探测超时，UI 提示点「刷新」重试。**未发版**。

### 4.10 内建触控板不参与加速度接管（2026-11-06，`PointerController.swift` / `Views.swift`）

**现象**：指针页「状态」区整段红字，第三行
`Apple Internal Keyboard / Trackpad … 回读 -0.000 … ⚠️ 写入未生效`。

**根因**：不是写入失败，是**设备根本不支持**。真机上内建触控板写
`HIDMouseAcceleration = -1` 读回 0，`HIDUseLinearScalingMouseAcceleration` 也不支持；
旧开关 `pointerIncludeBuiltIn` 把它拉进 `eligible`，`allOK=false` 于是把整段标红。
开关是没有载体的假选项：勾了只会制造假失败，不会带来任何接管。

**契约（不可回退）**：

1. `PointerAccelPolicy.scope(builtIn:)` 把内建触控板归类 `.systemManagedBuiltIn`，
   `eligible()` 恒排除它；**与旧开关值无关**。该字段保留只为旧 JSON 能继续解码。
2. 跳过项必须**可见**：`PointerAccelStatus.skippedLine(name:)` 产生带设备名 + 具体原因
   的状态行，不带 `⚠️`、不复用「写入未生效」。静默跳过是另一种假绿。
3. 跳过项**不参与成功判定**：`allOK` 只由 `writeResults`（真正执行过写入的外接设备）决定；
   `writeResults` 为空判红 —— 只有触控板时不能报「已接管」。
4. `restoreDefaults()` 仍遍历全部设备，负责把旧版本对触控板的历史写入清回原始值。

**验证**：harness M 段 16 项（设备范围 / 状态合成 / 跳过可见，含「只有触控板不能报绿」）、
M_W 9 条接线守卫（apply 按策略筛选、`readings` 只来自 `eligible`、UI 无假开关）、
三趟变异：① `scope` 恒返回 `.externalMouse` → M1/M3/M4/M5/M7 红；
② `allOK` 恒真 → M9/M10/M11 红；③ 抹掉跳过原因 → M13 红。全 harness `PASS=43 FAIL=0`。
真机：`smoose://settings?tab=pointer` 滚到「状态」，三行均为灰白色：
两行 `USB Receiver 线性 1:1 … 回读 -1.000 系统默认 2.500`，
一行 `Apple Internal Keyboard / Trackpad：内建触控板由系统管理（不写入加速度）`。

**未覆盖**：没有实测触控板手感是否受旧版本历史写入影响；如需清理，点「恢复系统默认」。
**未发版、未提交**。

---

### 4.11 硬件 DPI 快捷键切换后的自动同步（2026-11-06，`LogitechHIDPP.swift` / `Views.swift`）

**现象**：用户在鼠标上按 DPI 键切档后，Smoose 界面仍停在旧值。

**根因与两个误判纠正**：

1. Solaar `notifications.py` 里 **0x2201 没有 DPI 变更通知**：DPI 变化只出现在
   ONBOARD_PROFILES 的 `resolution_index` 事件里且不带数值 → **必须主动 GET 当前值**。
2. 最初以为「`IOHIDDeviceOpen(None)` 收不到 HID++ 响应、必须 SeizeDevice」；
   独立进程实测 15/15 全部读到 5400，证明那只是**接收器休眠预热**（头 2–3 个请求
   超时 476/489/313ms，预热后单次 GET 约 25ms）。所以同步连接用 `None` 非独占打开，
   不霸占 Logi Options+ / Solaar 也要用的接口。

**契约（不可回退）**：

1. `HIDPPWatchSession` **只读**：不得出现 `0x38` / `HIDPPWrite` / `setDPI`；
   同步只更新 `currentDPI` / 档位 / 状态文案，**绝不回写硬件**。
2. 门禁只有 `windowVisible && dpiPageVisible && !isWriting && probeInfo != nil`；
   **不含 `appActive`**。硬件 DPI 键经常在 Smoose 非前台时按，加前台门禁等于关掉同步。
3. 变化判定必须分 case：`hardwareChanged` / `noChange` / `readFailed` /
   `outOfRange` / `ignoredWhileWriting`。读失败、越界、写入竞态都**不得吞成 noChange**。
4. 状态文案必须含「未回写硬件」，不得复用「已应用硬件 DPI」（会误以为 Smoose 写了设备）。
5. `warmupRequests >= 2`：接收器休眠的首个超时不能报成「读取失败」；连续失败要退避。
6. 硬件切到非常规档位（如 3300）时，Picker 仍须有这个选项，但整体仍受设备能力约束。

**验证**：N 段 23 项 + N_W 26 条接线守卫（含「同步链路只读」「无 appActive」）+
三趟变异（恒 noChange / 读失败伪装 noChange / 抹掉 writing 门禁，均按具体 case 报红）。
真机：按 DPI 键后独立探针 5400 → **14700**，界面同步显示 14,700 且标注「未回写硬件」，
重启 App 后仍一致。**未覆盖**：改成另一个 DPI 值的写入仍只验证过幂等值。

---

### 4.12 系统设置跳转：进程无响应与失效 deep link（2026-11-07，`SettingsLauncher.swift` / `Views.swift` / `App.swift`）

**现象**：点「打开系统设置」弹出
`You can't open the application "System Settings" because it is not responding.`

**根因（两层，别混为一谈）**：

1. **系统设置进程卡死**：PID 778 连续运行约 26h，`open` 返回 `-1712`（AppleEvent 超时），
   主线程 sample 停在 `mach_msg2_trap` 等事件却不处理 AppleEvent。这是 macOS 自身状态，
   **与哪个 App 的按钮无关**；`killall "System Settings"` 后同一 URL 立即 `rc=0`。
2. **旧 URL 已失效**：`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`
   在 macOS 27.3 落到 **Device Control and Data Access**；
   `com.apple.Accessibility-Settings.extension` 打开的是辅助功能**功能设置页**，
   两者都不是授权列表。ExtensionKit 真 ID 是 `com.apple.settings.PrivacySecurity.extension`，
   用它打开「隐私与安全性」，用户再点「辅助功能」勾选 Smoose。

**契约（不可回退）**：

1. `AccessibilitySettingsLauncher.urlString` 用新扩展 ID；**禁止回退**旧 anchor
   （O1/O2/O3 + O_MUT3 守住）。
2. 必须用带 `completionHandler` 的重载：只有 `error == nil` 才算 `.opened`；
   空/空白原因也判 `.failed` 并补明确原因，不得伪装成功。
3. 失败反馈三要素缺一不可：**具体原因 + 「重试」+ 手动路径**；视图必须显示红字与重试按钮。
   旧实现直接 `NSWorkspace.shared.open(url)` 把英文系统弹窗甩给用户，且失败被静默吞掉。
4. App **不替用户强杀系统进程**；只如实反馈并给出「强制退出系统设置后重试」的指引。
5. `smoose://onboarding` 是本地诊断入口，强制显示引导页，**不动 TCC 授权**
   （改 TCC 会让 App 立刻失去辅助功能权限）。

**验证**：O 段 14 项 + O_W 13 条接线守卫（含前置非空、编译列表接线、旧实现彻底消失）+
三趟变异（恒绿失败判定 / 空壳失败文案 / 换回旧 URL，均按具体 case 报红）。
真机：`smoose://onboarding` 唤起引导页 → CGEvent 真点「去授权」→ 系统设置窗口标题
`Privacy & Security`、无报错弹窗、引导页无红字与重试。**未覆盖**：未人为再次弄挂
System Settings 做真机 -1712 负例（失败路径由 O 段变异覆盖）。

**未发版、未提交**。

---

### 4.13 光标放大「开启不生效」与两步 deep link（2026-11-07，`CursorZoom.swift` / `SettingsLauncher.swift` / `Views.swift`）

**现象**：指针页「快速移动鼠标时放大光标图标」开关是蓝色，但摇动鼠标没有放大效果，
系统设置里也看不出变化。

**根因（两层，别混为一谈）**：

1. **不是键写错**：`CGDisableCursorLocationMagnification`（`.GlobalPreferences`，语义反相）
   就是这个开关的键。真机在系统设置里点开关，全局域只有它 0↔1，
   `com.apple.universalaccess` 无变化。
2. **是「写成功 ≠ 功能生效」**：macOS 的 WindowServer 只在登录会话启动时加载该偏好；
   第三方写 plist 后系统设置 GUI 不刷新、切页重进也不刷新，post 若干候选 Darwin 通知
   （`com.apple.WindowServer.cursor_cache` 等）也无效。Apple Developer Forums / Jamf
   从 El Capitan 起就明确「需 logout/reboot」。旧实现 `apply()` 无返回值、写完就报绿，
   Toggle 立刻变蓝 = **假绿**。

**契约（不可回退）**：

1. `apply()` 返回 `CursorZoomApplyResult`，写后必须用 `CFPreferencesCopyValue`
   **独立读回**（不能用 `UserDefaults` 进程内缓存 —— 写完立刻读必然是新值，又是假绿）；
   读不到 / 不一致判 `.readBackMismatch` 并带期望值与实际值。
2. `.writtenPendingRelogin` 是独立一类：**只表示偏好写好了**，不表示功能已生效。
   文案必须同时含「已写入」「重新登录」和可操作路径，禁止出现「已生效 / 立即生效」。
3. 失败时开关回弹：Toggle 用自定义 `Binding`，只有 `result.ok` 才更新
   `prefs.cursorZoomEnabled`；不得回到 `.onChange(of:)` 直接改状态（会来回回弹）。
4. 页面常驻说明「当前显示的是系统偏好值」，避免蓝色开关被误读成即时生效。
5. `DisplaySettingsLauncher.urlSequence()` **必须两步**：`[baseURLString, baseURLString + "?display"]`。
   冷启动单发带 anchor 的 URL 只到 `Accessibility` 首页（5 种 anchor 逐个复测均如此）；
   两步间隔 0.4 / 1.0 / 2.0s 均稳定到 `Display`。第二步失败必须报
   「已打开辅助功能，但未能直达显示页」+ 重试，不能报 `.opened`。

**验证**：P 段 31 项（反相映射 / 四类写入判定 / 三要素文案 / 两步 URL 序列）+
P_W 21 条接线守卫（独立读回、失败回弹、编译列表、两步真的接线）+
四趟变异：① `verdict` 恒绿 → P8/P9/P10 红；② 抹掉「重新登录」并宣称立即生效 →
P16/P18 红；③ 换回去授权 URL → P24/P25/P30 红；④ 去掉两步法第一步 →
P28/P29/P30 红。全 harness `PASS=59 FAIL=0`。

**真机**：CGEvent 真点开关，plist `0 → 1 → 0`（两次读回校验均通过，最终恢复用户原值），
状态行完整显示待重新登录文案、无红字；冷启动点「在系统设置里打开」→ 窗口标题
`Display`、Pointer 区 `Shake mouse pointer to locate` 可见且为开、无报错弹窗。

**未覆盖**：未做真机负例把 `CFPreferencesCopyValue` 弄失败（失败路径由 P 段变异覆盖）；
也没有实测「摇动鼠标放大效果」本身在重新登录后是否出现 —— 这是 macOS 侧行为，
Smoose 只能写入偏好与给出可操作路径。
**未发版、未提交**。

---

## 5. 配置格式（接手排查用）

- 持久化：`UserDefaults` 域 `app.smoose.macos`，key `smoose.state`，值为 `StoredState` 的 JSON。
- `StoredState` 字段：`masterEnabled` / `ignoreTrackpad` / `global` / `apps` / `launchAtLogin` / `bindings` / `appBindings` / `swapBackForward` / `triggerOnMouseUp` / `pointerAccelManaged` / `pointerAccelerationValue` / `pointerIncludeBuiltIn` / `pointerSpeedManaged` / `pointerSpeedFactor` / `cursorZoomEnabled` / `autoCheckUpdates`。
  其中 `pointerIncludeBuiltIn` 自 §4.10 起**只是旧存档兼容字段**：不再有 UI 控件、也不影响设备筛选（恒排除内建触控板）。
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
  SMOOSE_SWIFT_EXTRA=-disable-sandbox ./run_tests.sh   # 2026-10-31 实测 PASS=13 FAIL=0（十三段）
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

### 6.1c 2026-11-07 收尾复核：确认「现役包 = 最新源码」的正确姿势

复核时踩到两个会让人误判「修复没部署」的坑，记在这里：

1. **Mach-O 的 sha256 天然对不上**。`build/Smoose.app` 与 `/Applications/Smoose.app`
   的二进制分别是 `bb417c48…` 与 `d76f4f09…`，但两者长度同为 2038576 字节，
   逐字节比对**只有 258 个字节不同，且全部落在末尾 offset 2024653–2025347**
   （`__LINKEDIT` 里的签名 / LC_UUID 区）—— 代码段与 `__TEXT` 常量完全一致。
   每次 `swiftc` 都会换 LC_UUID、每次 `codesign` 都改写签名区，
   所以**不能用 hash 是否相等判断现役包是不是最新构建**；要判断可比「长度 +
   差异字节数 + 差异是否只落在签名区」。另外 `run_tests.sh` 的 E 段会直接调
   `./build.sh`（开头 `rm -rf "$BUILD"`），跑完 harness 后 `build/` 是刚重建的产物，
   更不能当作已部署包的副本。
2. **`/usr/bin/grep -a` 搜中文常量会漏报**。对现役二进制搜「需重新登录才生效」
   等 UTF-8 文案，`grep -a -c` 返回 0，看起来像第 23 轮没部署；换成按 UTF-8 字节
   `bytes.count(...)` 却是 2 处（第二十至二十三轮新增文案全部命中）。
   判断现役包含哪一轮修复，用 Python 字节反查，别用 grep 的中文匹配下结论。

```bash
/usr/bin/python3 - <<'PY'
B = open('/Applications/Smoose.app/Contents/MacOS/Smoose', 'rb').read()
for k in ('com.apple.settings.PrivacySecurity.extension', '?display',
          '需重新登录才生效', '鼠标快捷键切换 DPI', '内建触控板由系统管理'):
    print(k, B.count(k.encode()))
PY
/usr/bin/codesign --verify --deep --strict /Applications/Smoose.app
/usr/bin/codesign -dv /Applications/Smoose.app 2>&1 | /usr/bin/grep TeamIdentifier
```

### 6.1d 2026-11-07 发版链路的两个环境坑

**(a) `release.sh` 也要带 `-disable-sandbox`**（受限环境）。脚本第 53 行直接调
`"$ROOT/build.sh"`，环境变量会继承，所以
`SMOOSE_SWIFT_EXTRA=-disable-sandbox ./scripts/release.sh` 即可。不带时实测报
`Sources/Views.swift:1395: error: cannot assign to property: 'self' is immutable`
—— **不是真语法错**，是 SwiftUI `@State` 宏展不开之后的连锁误报；同一份源码带开关
一次编译通过。⚠️ `build.sh` 开头就 `rm -rf "$BUILD"`，编译失败会把 `build/` 清空，
所以发版前先确认现役包与备份都在（本轮已提前部署 1.4.3 + 备份
`/tmp/Smoose.backup.20261107_124055.app`，未受影响）。

**(b) 代理节点轮换时 `gh` 的 Go 客户端不稳，改用 `curl` REST + 幂等重试**。
Shadowrocket 日志显示 `api.github.com` / `uploads.github.com` 都落在
`DOMAIN-SUFFIX,github.com,PROXY # 🇯🇵 免费-日本N` 组，节点逐个轮换，部分节点对
CONNECT 直接回 503 / TLS 握手 EOF。实测：`git clone` 第 7 次成功、SSH `git push`
第 3 次成功（SSH 走 `ssh.github.com:443`，最稳）、`gh release create` **14 次全败**，
而 `curl -X POST` 到 REST 第 12 次返回 201、asset 上传第 6 次返回 201。
要点：
1. 每次重试前先 GET 目标资源确认是否已成功（**超时 ≠ 失败**），避免重复建 tag；
2. asset 必须传 `uploads.github.com`（`api.github.com/repos/.../releases/:id/assets`
   实测返回 404）；
3. 每次 `build.sh` 都会因 LC_UUID 变化让 zip 的 sha256 改变 —— **失败重试时不要再重建**，
   拿同一个 zip 传到成功为止，否则 manifest / Release notes 里的 sha 会对不上；
4. 闭环以 `GET /releases/latest` 的 asset `digest` 与本地 sha256 比对为准，
   别只看「命令返回 0」。

**(c) 别用管道接 `git push` 再拿 `$?` 判成功**（本轮真抓到的一次假绿）。
第一次推文档时写成 `git push | tail -3`，服务端其实回了
`Please make sure you have the correct access rights and the repository exists.`
（节点握手失败），但管道退出码是 `tail` 的 0，脚本照样打印「push ok」，
而 `origin/main` 还停在 `1a19d96`。正确写法：
`git push > /tmp/push.log 2>&1` 后直接判退出码，再用 SSH 的
`git ls-remote origin refs/heads/main` 与本地 `git rev-parse HEAD` 比对 sha，
不要只看输出里有没有「ok」字样。

---

## 7. 已知限制 / 未决项

- **与 Mos 差异与已知限制**：
  - 滚轮加速（Scroll Boost，1.4.0）、滚动曲线实时预览（1.4.0）已对齐 Mos；
    **2026-11-03 起合成事件的触控板相位（`isContinuous=1` + scroll/momentum 相位 + 零增量收尾帧）
    与点击刹车也已对齐 Mos**（`Sources/ScrollPhases.swift`，开关「模拟触控板滚动」默认开）。
    仍未做的三项及理由见 SPEC §26.9：LinearMouse 的速率投影（改距离语义）、
    速度式模型 + 惯性（作废已有曲线参数）、Mos 的 `CGEventPostToPid` 直投（不赌）。
  - 侧键与手势：走 macOS 标准 HID button 3/4/5，罗技鼠标（如 G502 X、MX 等）插上直接可用，支持 13 种原生动作与每应用覆盖；Logitech HID++ 2.0 硬件 DPI 直控已支持。厂商特有的 HID++ 侧键上报与手势层维持不做。
  - 输入法切换跟随等 Mos 附属功能维持不做（不属于鼠标增强主线）。
  - ~~更新替换后若签名身份变化无提示~~ **2026-10-31 已修（P2）**：`Updater.signingAuthority` 提取新旧 bundle 的叶子证书 Authority，
    若发生变更则在重启就绪视图中明确提示「新版本签名证书变更，重启后 macOS 可能会撤销辅助功能权限，届时需在系统设置中重新勾选」，并在 harness 中由 H29–H30 守住。
- **启发式风险**：触控板判定靠 `IsContinuous/ScrollPhase/MomentumPhase`，个别第三方设备可能误判。
- **距离倍率基准**：绝对基准依赖各 App 自身的行距换算，这正是 Mos 提供每应用配置的原因，本作同样支持。
- **数据竞争（已修，2026-10-29）**：`pointerRemX/Y` 在 tap 线程读写、`apply()` 主线程重置。原记录称「无锁、未修」，
  实际核对：`apply()` 有锁，无锁的是 `handlePointerMove` 的 rem 累积段（`lock.unlock()` 提前了）。
  现已全程持锁，G2c-8 断言守住（unlock 后不得再访问 rem），变异验证可抓回归。见 SPEC D17。
- **版本比较**：`UpdateCheck` 只看 SemVer，不校验降级；`minSystem` 解析失败时放行（不阻塞检查）。
- ~~自动更新的端到端安装未真跑~~ **2026-10-31 已真跑通（D20）**：将 `/Applications/Smoose.app` 降级为 1.2.1 隔离副本后，
  以真实驱动调用 `Updater.check` + `downloadAndInstall`，走 GitHub 真实源完整跑通 1.2.1 → 1.3.0 全流程
  （下载 → sha256 校验 → 签名与 TeamID 校验 → 替换 `/Applications/Smoose.app` → 成功就绪）。
  同时为 `replaceApp` 引入目标注入与原子回滚，并由 harness H26–H28 自动化测试守护。
- **2026-11-03 第十五轮（参照 Mos / LinearMouse）**：新增 `Sources/ScrollPhases.swift`
  （`ScrollPhaseValue` / `SyntheticScrollFields` / `ScrollPhaseFields.write` / `ScrollPhaseTracker`），
  合成事件改为按手势写 `isContinuous=1` + `scrollPhase` / `momentumPhase` + 零增量收尾帧；
  左键点击刹车（`ScrollAxis.brake()` + `NSEvent.addGlobalMonitorForEvents(.leftMouseDown)`）；
  滚轮路径补 `com.apple.dock`（Launchpad 寄宿进程）透传。开关 `ScrollProfile.simulateTrackpad` 默认开。
  harness 新增 S36–S39，二十六段 `PASS=26 FAIL=0`，8 条变异全部报红。详见 SPEC §26。
  **两条真机事实**：① `CGEvent(scrollWheelEvent2Source:units:.pixel…)` 造出来的新事件
  `isContinuous` **默认就是 1**，1.4.2 靠显式写 0 才关掉；② 相位状态机两个入口
  （tap 回调 `noteInput` / 显示链接 `advance`）必须都用 `CACurrentMediaTime()`，
  CVDisplayLink 的 `videoTime` 是另一套时基，混用会让 0.18s 阈值永久失效。
- **用户提过「Dock 继续」但症状不明（2026-10-31）**：已实测确认 Dock hover 放大、光标移开复位、无粘住都正常
  （10-19 的修复在 1.2.x 仍有效），当时配置 `pointerSpeedManaged=False`、`cursorZoomEnabled=False`。
  若用户再说 Dock 问题，先问清是哪种现象（放大失效 / 粘滞 / 图标不显示），别再盲改。
- ~~套预设会清掉「按住加速」配置~~ **2026-11-01 已修（D21）**：`ScrollProfile.preset(named:preservingBoostFrom:)`
  只覆盖曲线参数，boostModifiers / boostFactor 原样保留。此前点一次「浏览器」就把用户配好的 ⌘+4× 清回 0，
  加速静默失效且无提示。由 S18-S20 断言守住。
- ~~新建每应用规则一律「沿用全局」~~ **2026-11-01 已修（D22）**：微信 / QQ / Slack / Discord / Teams
  命中 `chatBundleIDs` 白名单，直接套「聊天软件」预设（speed 0.8），解决用户 10-31 反馈的微信滚轮过快；
  未命中 App 仍回落全局。由 S21-S24 断言守住。
- ~~加速滑条上限与引擎上限不同源~~ **2026-11-01 已修（D23）**：滑条从写死 `1.2...6` 改为
  `1.2...ScrollBoost.maxScale`，消除「拖不到上限」与「界面 6.0 实际 8.0」的读写不一致。由 S25-S27 守住。
- ~~罗技 HID++ 每 5 秒全量轮询~~ **2026-11-01 已改事件驱动（D24）**：注册 matching / removal 两个 IOHID 回调，
  `Unmanaged` 把 self 传进去。顺带修掉一个体验问题：插上鼠标最多等 5 秒界面才反映。由 S30 守住。
- ~~指针配置要等最多 6 秒才生效~~ **2026-11-01 已改事件驱动（D25）**：`persist()` 比对指针配置签名，
  真变了才发 `.smoosePointerConfigChanged`。~~兜底轮询拉长到 60 秒~~ **2026-11-06 反转（§4.5）**：
  当时拉长是因为每轮都会全量枚举 IOKit；现在枚举交给 IOHIDManager 回调，轮询只读属性，
  改成 **8 秒**才能及时纠正系统重置 HID 加速度。S31g 的守卫也随之从「≥30 秒」改成「≤10 秒」，
  并新增 S31h–S31k（轮询不碰全量枚举 / 两个插拔回调 / 读数进签名）。
- ~~加速键与透传键同键时无提示~~ **2026-11-01 已加界面警告（D26）**：`ScrollBoost.conflicts(bypass:boost:)`
  纯函数 + 「按住加速」段橙色提示。引擎行为本来就是对的（透传优先），补的是可发现性。由 S28/S29 守住。
  * ~~菜单栏点「下载并安装」后装完没反馈~~ **2026-11-01 已修（D27）**：MenuBarPanel 补上
  downloading / installing / readyToRelaunch 三个分支（进度条、安装中提示、立即重启 + 证书变更警告）。
  * ~~`dismiss()` 会丢掉已安装的更新~~ **2026-11-01 已修（D28）**：新版本已替换到 /Applications，
  收起横幅 = 丢掉唯一重启入口。readyToRelaunch 时 dismiss 为 no-op，该分支也不提供「稍后再说」。
  由 S32/S33 守住，且已真机端到端实测（D29）。
- **游戏性能检测的「实时指标」是 2 秒滚动窗口**：鼠标停下 2 秒后所有指针指标归零并显示「正在采样」。
  这是设计如此（要反映「刚才那一把」），但意味着**截图 / 演示必须趁鼠标还在动的时候抓**，
  否则会误判成功能坏了（2026-11-02 就这么误判过一轮）。
- **`CGEvent.timestamp` 时基不统一**（2026-11-02 实测，SPEC §25.2）：HID 事件是 mach tick，
  经 `CGEvent.post()` 注入的事件是开机以来纳秒数。任何直接拿 `event.timestamp` 和
  `mach_absolute_time()` 相减的代码都必须先过 `MachClock.normalize`。
- ~~`teamMismatch` 无自动载体~~ **2026-10-28 已解决（H25）**：用「改期望值」而不是「造假包」拿到载体 ——
  把测试二进制包进带 `SmooseUpdateTeamID` 的 `.app`，官方包就会撞上 teamMismatch。`verifySignature` 的
  三条拒因分支（ad-hoc → `notSigned`、篡改 → `signatureInvalid`、他人 Team → `teamMismatch`）现在都有断言。

---

## 8. 接手 Checklist

- [x] **2026-11-06 加速度漂移修复（§4.5）**：签名纳入设备读数 / 8s 轮询 / IOHIDManager 插拔回调 /
  写后读回校验；harness 新增 I 段 14 项（`PASS=27 FAIL=0`）、变异验证 5 条报红、真机端到端
  6s 自愈 + 退出 App 负例；新构建已部署 `/Applications`（1.4.2，sha256 `7346f355…`）。
  ✅ **2026-11-07 已随 v1.4.3 发版**：版本号抬到 1.4.3（`CFBundleVersion` 10）、
  Release asset 与 `latest` 均已复核（见顶部第二十四轮 / §6.1d）。
  注意仍要改**源码** `Resources/Info.plist` 再跑 `release.sh`，不能用 `plutil` 直接改
  已签名的构建产物（会让签名与 Info.plist 不符）。
- [x] `./build.sh` 编译通过并部署 `/Applications`（2026-10-07 首通；2026-10-22 部署 1.2.0；2026-10-27 部署含全部修复的新构建；**2026-10-31 部署 1.2.2**，见 §6.1a）
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

- [x] **2026-11-01 第十轮：加速配置与每应用建议档三条修复（SPEC §22，已完成）**。本轮只做「配了却静默失效」的配置层修复，
      引擎判定逻辑（S1-S8）本身没错，错在配置被整体替换：
      ① D21 套预设保留加速键（`preset(named:preservingBoostFrom:)`）；
      ② D22 新建每应用规则按 `chatBundleIDs` 白名单套「聊天软件」预设（治微信滚轮过快）；
      ③ D23 加速滑条上限与 `ScrollBoost.maxScale` 同源。
      harness 从十四段扩到十六段：S18-S24 编译**真实** `Sources/Model.swift`（给 `Preferences` 依赖的
      `ScrollEngine` / `PointerController` 两个单桩补空实现，不碰持久化），S25-S27 文本守卫 Views ↔ maxScale。
      变异验证：删掉 boost 保留两行 + 白名单去掉微信 → S18a/S18b/S19b/S21 报红；滑条改回 `1.2...6` → S25a/S25b 报红；
      恢复后 `PASS=16 FAIL=0`。
      已完成收口：`run_tests.sh` `PASS=16 FAIL=0` → `build.sh` 重新签名 → ditto 部署 `/Applications/Smoose.app`
      （备份 `/Applications/Smoose-1.4.0-pre-141.app`，版本仍 1.4.0，二进制 sha256 `4184a719…75ec`，
      `codesign --verify --deep --strict` 通过、TeamIdentifier `6U2DQJ6Z2N`、辅助功能授权 `auth_value=2` 保留）
      → clone 副本提交 `3f0c946` 并推送 main。**尚未发 Release**（改动是配置层修复，未抬版本号）；
      若要发版需先把 `Resources/Info.plist` 抬到 1.4.1 再跑 `scripts/release.sh --github`。

- [x] **2026-11-01 第十一轮：轮询改事件驱动 + 同键冲突提示（SPEC §23，已完成）**。清单里剩下的 P2/P3 三项全做完：
      D24 罗技 HID++ 5 秒轮询 → IOHID matching/removal 回调；D25 指针配置 6 秒轮询 → persist 签名比对 + 通知，
      兜底拉长到 60 秒；D26 加速键与透传键同键时界面橙色警告（`ScrollBoost.conflicts`）。
      harness 十六段 → 二十段（S28 编译真 ScrollAxis / S29-S31 文本守卫），`PASS=20 FAIL=0`。
      变异验证：`conflicts` 恒 false → S28e/f 红；删 removal 回调 → S30b 红；删发通知块 → S31b/e 红；
      兜底改回 6.0 → S31g 红。
      ⚠️ 过程里删掉过一个 `setObserving(_:)` 半成品（`isObserving` 只写不读、没人调用）——不留死代码。
      本轮同样**尚未发 Release**（版本仍 1.4.0）。

- [x] **发 v1.4.1（2026-11-01 完成）**：`Resources/Info.plist` 抬到 `1.4.1`（`CFBundleVersion` 8）→
      `./scripts/release.sh --github --repo cpufreestyle/Smoose` → Release `v1.4.1` 已发、asset `Smoose-1.4.1.zip`
      （951496 字节）已上传、`latest = v1.4.1`。逐段复核：下载的 zip sha256 `cdc55b60…e81a` 与产出端一致 →
      顶层即 `Smoose.app`、`CFBundleIdentifier=app.smoose.macos`、`codesign --verify --deep --strict` 通过、
      `TeamIdentifier=6U2DQJ6Z2N` → 真实 `UpdateCheck.decide(current:"1.4.0"/"1.3.0"/"1.2.3")` 均 `available(1.4.1)`、
      `decide(current:"1.4.1")` 与 `decide(current:"1.5.0")` 均 `upToDate`。
      发版内容是第十轮 D21-D23（配置层修复）+ 第十一轮 D24-D26（轮询改事件驱动、同键冲突提示），
      未动引擎滚动行为，所以从 1.4.0 升上来的手感不变。版本号提交 `6867a01`。
      部署后 `run_tests.sh` 复跑 `PASS=20 FAIL=0`。

- [x] **2026-11-01 第十二轮：更新流程的菜单栏出口（SPEC §24，已完成 + 真机端到端）**。用户从菜单栏点
      「下载并安装」后装完没反馈——`readyToRelaunch` 只在「关于」页有按钮，菜单栏完全不显示，
      且 `dismiss()` 能把它打回 idle，等于弄丢唯一的重启入口。修 D27（菜单栏补三个状态分支）+
      D28（dismiss 对 readyToRelaunch 为 no-op，该分支不给「稍后再说」）。
      harness 二十段 → 二十一段，`PASS=23 FAIL=0`；变异验证三项（删守卫 / 守卫顺序错 / 加回按钮）全抓到。
      两个断言坑已写进 SPEC：S32 必须在 `dismiss()` 函数体内比顺序，全文搜 `phase = .idle`
      会先命中 `cancel()` 那一处导致永远红；S33 判「不含稍后再说」前必须剥注释，解释「为什么不提供」
      的注释里本身就含这四个字。另外 `/bin/awk` 在这台机器上不存在，只能用 `/usr/bin/awk`。
      **真机端到端**：降到 1.4.0 后用编译进去的真实 Updater 驱动完整链路，phase 序列实测
      `checking → updateFound(1.4.1) → downloading(0→98%) → installing → readyToRelaunch(1.4.1)`，
      同进程内 `dismiss()` 前后 phase 不变（no-op 实测）。链路自己把 /Applications 装成了 1.4.1。
      本轮同样**尚未发 Release**（版本仍 1.4.1）。

- [x] **发 v1.4.2（2026-11-01 完成）**：`Resources/Info.plist` 抬到 `1.4.2`（`CFBundleVersion` 9）→
      `./scripts/release.sh --github --repo cpufreestyle/Smoose` → Release `v1.4.2` 已发、asset `Smoose-1.4.2.zip`
      （958043 字节）已上传、`latest = v1.4.2`。逐段复核：下载 zip sha256 `44184b2e…773f` 与产出端一致 →
      顶层 `Smoose.app`、`CFBundleShortVersionString=1.4.2` / `CFBundleVersion=9`、bundle id `app.smoose.macos`、
      `codesign --verify --deep --strict` 通过、`TeamIdentifier=6U2DQJ6Z2N` → 真实 `UpdateCheck.decide`
      对 GitHub 真实响应：`1.4.1` / `1.4.0` / `1.3.0` 均 `available(1.4.2)`，`1.4.2` / `1.5.0` 均 `upToDate`
      → 部署后复跑 harness `PASS=23 FAIL=0`。
      **为什么发这一版**：v1.4.1 的 asset 是第十/十一轮的代码，**不含**第十二轮的 D27-D29
      （菜单栏补齐更新全流程、dismiss 不丢已安装更新）。版本号提交 `451ad3e`。
      部署后 `/Applications/Smoose.app` 版本 1.4.2、Mach-O sha256 `d88b7205…0dca`、授权 `auth_value=2` 保留。

- [x] **2026-11-02 第十三轮：鼠标游戏性能检测（SPEC §25，已完成 + 真机预览，尚未发版）**。
      新增 `Sources/GamePerf.swift` 与「游戏」tab；采集复用已有回调（CGEvent tap + CVDisplayLink），
      对 Smoose 自身零额外系统开销。harness 二十一段 → 二十二段，`PASS=24 FAIL=0`。
      本轮修掉两个真 bug，都不是「功能没写对」而是「边界没守住」：
      ① `recompute()` 的 `for i in 1..<count` 在指针环为空时构成 `1..<0`，Swift 运行时直接 SIGTRAP ——
      触发条件是**默认状态**（启动后第一次 1 Hz tick，用户还没动鼠标），表现为「点桌面图标完全没反应」；
      ② `CGEvent.timestamp` 时基不统一：HID 事件是 mach tick，经 `CGEvent.post()` 注入的事件是
      **开机以来纳秒数**（同刻比值 41.6662 ≈ timebase 125/3，按 uptime 反查吻合）。
      不归一化时三个指标同时坏：指针延迟恒 0、事件率被算小 41.67 倍、2 秒窗口过滤整体失效。
      旧交接文档「timestamp 与 mach_absolute_time 同时基」只对 HID 事件成立，**已作废**。
      另修 harness 假绿：H/D 段只 `grep '^FAIL'`，而运行时陷阱打的是 `Fatal error:`（不以 FAIL 开头），
      二进制中途死掉也算通过 —— 删掉空数组守卫后 harness 全绿就是这么来的。现要求退出码 0 且打出 H-OK / D-OK。
      变异验证 12/12 报红；两条**语义等价**的变异没报红，其中一条暴露了「未环绕（total < capacity）快照顺序」
      这个测试盲区，补 H32l 后才抓住。教训：变异没报红时先怀疑变异本身等价，别直接宣称断言有牙。
      新增 `smoose://settings?tab=<name>` 直达标签页（AppleScript 点 SwiftUI tab 不可靠）。
      **真机预览**（修复后）：G502 X 接收器 1000 Hz / 内置触控板 125 Hz、指针事件率 744 Hz、
      移动抖动 p50/p99/max = 0.38/7.94/42.20 ms、指针延迟 p50/p99/max = 0.07/0.73/1.62 ms、
      显示 120.2 Hz 掉帧 0.0%。⚠️ 指标是 2 秒滚动窗口，鼠标一停就归「采样中」，截图要趁早。
      **尚未发版**：版本仍 1.4.2，`/Applications/Smoose.app` 是含新功能的工作副本。

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

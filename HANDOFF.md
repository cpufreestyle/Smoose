# Smoose — 项目交接文档（HANDOFF）

> 仿 [Mos](https://github.com/Caldis/Mos)（公认最好的 macOS 鼠标滚动增强工具）的原生菜单栏 App。
> 把鼠标滚轮的「一格一跳」重建成触控板那样的连续滚动曲线，并附带指针加速度 / 速度控制（LinearMouse 那一半）。
> 原生 Swift，零第三方依赖。
>
> 本文档面向接手维护的开发者，记录架构、能力、关键坑、构建方式与未决项。
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

| 项 | 状态 |
| --- | --- |
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

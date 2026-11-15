# 设备级滚动类型识别 + 每设备覆盖 — 设计方案

> 状态：**已实现（2026-11-14）**，落位见 `SPEC.md` §42、`Sources/DeviceAttribution.swift`
> 关联契约：`SPEC.md` §42（设备级滚动类型识别）
> 目标版本：v1.5.0

## 1. 背景

`README.md`「与 Mos 的差异 / 已知限制」记录了当前判定方式的缺陷：

> 触控板判定走 `IsContinuous`/`ScrollPhase`/`MomentumPhase` 启发式，个别第三方设备可能误判 → 关掉「忽略触控板」即可对该设备生效

这段话里的「对该设备生效」其实不成立。现状是全局单开关，一旦关掉，**所有**连续滚动设备（包括真正的内置触控板）都会失去忽略保护。用户同时用内置触控板和一台会误报 `IsContinuous` 的第三方滚轮鼠标时，无法同时满足两者。

## 2. 现状（代码事实）

| 位置 | 事实 |
|---|---|
| `Sources/ScrollEngine.swift:283-285` | 连续判定只读事件字段 88 / 99 / 123 |
| `Sources/ScrollEngine.swift:299` | `continuous && config.ignoreTrackpad` → 整事件透传 |
| `Sources/Model.swift:174` | `ignoreTrackpad: Bool`，**全局唯一** |
| `Sources/Model.swift:250` | `profile(for:)` 只按 bundle id 选择，无设备维度 |
| `Sources/GamePerf.swift:142-202` | 已有 `PointerDeviceRef`（registryID / productID / locationID / transport / builtIn）与同名消歧 |
| `Sources/LogitechHIDPP.swift:201-330` | 已有 IOHIDManager 枚举设备的成熟做法 |
| 全仓库 | **不存在**「事件 → 来源设备」的归属能力 |

结论：设备指纹设施已经有了，缺的是把事件和指纹连起来的那一环。

## 3. 目标与非目标

**目标**

1. 把「连续滚动 = 触控板」从猜升级为设备身份优先判定。
2. 允许按设备单独纠正误判，且不影响其它设备。
3. 归属失败时行为与现状**完全一致**（零回归）。

**非目标**

- 不做每设备滚动曲线（那是另一个需求，不在本次范围）。
- 不改变 `SPEC.md` §46 的默认行为契约。
- 不动 `profile(for:)` 的每应用选择逻辑。

## 4. 方案

### 4.1 三层判定，逐层兜底

```
设备显式覆盖（用户指定）
  ↓ 无覆盖
设备能力分类（按 HID usage 判定，静态可信）
  ↓ 归属失败或能力未知
事件启发式（现状 field 88/99/123）
```

任何一层给出结论即停止，保证「无设备信息时 = 现状」。

### 4.2 设备归属：影子 HID 监听 + 时间窗关联

CGEvent 不携带设备标识，因此需要旁路监听：

1. 用 `IOHIDManager` 以**非独占**方式监听 `kHIDPage_GenericDesktop` 下的 Mouse / Pointer 用法，以及 `kHIDPage_Digitizer` 下的 TouchPad 用法。
2. 为每台设备注册 input value callback，**只记录 `(设备键, 最后一次上报的 mach 时间)`**，不消费、不拦截、不改写任何输入。
3. `handleWheel` 取 `CGEventGetTimestamp(event)`，在 50ms 窗口内查最近的设备活动记录，作为本次事件的来源设备。

时间窗取 50ms 的依据：人手不可能在 50ms 内交替驱动两台设备产生连续滚动；单设备连发间隔通常 8–16ms（125–1000Hz），窗口足够覆盖。

### 4.3 设备能力分类

按 HID 描述符静态判定，不依赖事件表现：

| 特征 | 分类 | 语义 |
|---|---|---|
| `kHIDPage_Digitizer` + TouchPad 用法 | `.touchSurface` | 真实触控面，应受 `ignoreTrackpad` 保护 |
| `kHIDPage_GenericDesktop` + Mouse 用法 | `.wheelMouse` | 滚轮设备，应被平滑接管 |
| 其它 / 读不到 | `.unknown` | 回落到事件启发式 |

注意：Magic Mouse 归类为 Mouse 但实际产生连续滚动，属于「用户可覆盖」的典型场景，不做硬编码特判。

### 4.4 设备键

`registryID` 在重新插拔后会变，不能当持久键。采用：

```
builtIn 设备      → "builtin"
外接设备          → "pid:<productID>@loc:<locationID>"
两者都缺（蓝牙）  → "pid:<productID>@name:<product>"
```

与 `GamePerf.swift` 中「同名设备用 PID 消歧」的判据保持一致，避免两套设备身份。

## 5. 数据结构变更

`Sources/Model.swift`：

```swift
enum DeviceVerdict: String, Codable {
    case auto        // 交给能力分类 / 启发式
    case touchSurface
    case wheelMouse
}

struct StoredState {
    // 新增：设备键 → 用户指定判定；缺省表示 .auto
    var deviceVerdicts: [String: DeviceVerdict] = [:]
}
```

`StoredState` 已有手写 `init(from:)` 且全部走 `decodeIfPresent`（`Model.swift:223-242`），新字段追加一行即可，旧配置文件不会解码失败。

`ignoreTrackpad` 语义收窄为「没有设备级结论时的默认值」，不再直接作用于事件。

## 6. 判定流程

```
handleWheel(event)
  ├─ 计算 continuous（field 88/99/123，保持不变）
  ├─ device = DeviceAttribution.device(for: event.timestamp)
  ├─ verdict = device.map(stored.deviceVerdicts[key]) ?? .auto
  ├─ shouldIgnore =
  │     verdict == .touchSurface ? true
  │   : verdict == .wheelMouse   ? false
  │   : device?.capability == .touchSurface ? true
  │   : device?.capability == .wheelMouse   ? false
  │   : (continuous && config.ignoreTrackpad)      // 现状兜底
  └─ shouldIgnore → 透传；否则照常进入平滑链路
```

关键不变式：`device == nil` 且无覆盖时，表达式退化回 `continuous && config.ignoreTrackpad`，与当前实现逐字等价。

## 7. 边界条件

| 场景 | 处理 |
|---|---|
| 设备热插拔 | `IOHIDManager` 的 device matching / removal callback 增删表项；表为空时自然回落启发式 |
| 蓝牙设备 | 无 locationID，退到 `pid@name` 键 |
| 罗技接收器多集合 | 同一 registryID 多集合共享 pid/loc，天然合并为同一设备键 |
| 两设备同时滚动 | 50ms 窗口内取最近一次；极端并发下可能错配一次，下次事件自愈 |
| 归属失败 | 回落启发式，行为等同现状 |
| 输入监控权限缺失 | 监听注册失败，`device` 恒为 nil，功能降级但可用 |

## 8. 兼容性与契约

- `SPEC.md` §46 的默认路径不变：不配置设备覆盖时，判定结果与当前版本一致。
- 旧配置文件无需迁移。
- 新增字段全部带默认值，`Equatable` 语义不受影响。

## 9. 验收标准

1. 内置触控板：`ignoreTrackpad = true` 时连续滚动原样透传（与当前一致）。
2. 罗技 G502 X 接收器：滚轮平滑生效，不因 `ignoreTrackpad` 被误忽略。
3. 会出现误报的第三方设备：可单独标记为 `.wheelMouse`，标记后平滑生效，且内置触控板仍受保护。
4. 拔掉全部外接设备后重新插入：设备键稳定，覆盖配置仍命中。
5. 关闭设备覆盖（全部 `.auto`）：行为与 v1.4.6 逐项一致。

## 10. 风险

| 风险 | 级别 | 应对 |
|---|---|---|
| 50ms 时间窗在极端负载下失配 | 中 | 失配即回落启发式，不产生错误接管 |
| 监听需要输入监控授权 | 中 | 先实测；已有辅助功能授权大概率覆盖，不覆盖则功能降级 |
| 设备键在换 USB 口后变化 | 低 | 覆盖失效退化为 `.auto`，不会误判 |
| 无真机可测的第三方设备 | 中 | 用 `ignoreTrackpad` 反向验证：标记前误判、标记后正确 |

## 11. 实施拆分

| 步骤 | 产出 |
|---|---|
| 1 | `DeviceAttribution`：影子监听 + 时间窗表 + 设备键 |
| 2 | `DeviceCapability`：按 usage 分类 |
| 3 | `ScrollEngine.handleWheel` 接入三层判定 |
| 4 | `StoredState.deviceVerdicts` + 解码兼容 |
| 5 | 设置页设备列表增加「判定」下拉（自动 / 触控板 / 滚轮鼠标） |
| 6 | harness 单测：设备键生成、三层优先级、退化路径 |

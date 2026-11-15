import SwiftUI

/// 悬停解释的稳定键名。
///
/// 用枚举而不是散落的字符串字面量，是为了让 harness 能对文案表本身做断言：
/// 每个键都必须有解释、解释不能是占位短句、两个键不能共用同一句
/// （复制粘贴漏改是这类文案最常见的退化），以及 `Views.swift` 里真的用上了。
/// 散落字面量做不到这些，改名也会静默漏改。
///
/// 命名跟着「控件在界面上的作用」走，不跟着存储字段走 —— 同一个字段可能在
/// 多处出现（全局 + 每应用），键名按语义分。
enum HelpKey: String, CaseIterable {
    // MARK: 全局 · 滚动
    case masterEnabled
    case ignoreTrackpad
    case simulateTrackpad
    case speed
    case wheelLines
    case smoothness
    case minStep
    case axisLockThreshold
    case smoothVertical
    case reverseVertical
    case smoothHorizontal
    case reverseHorizontal
    case curvePreview
    case presets
    case launchAtLogin

    // MARK: 临时透传 / 按住加速
    case bypassModifiers
    case boostModifiers
    case boostFactor

    // MARK: 每应用
    case appRuleEnabled
    case appRuleSpeed
    case appRuleWheelLines
    case appRuleSmoothness
    case appRuleMinStep
    case appRuleAxisLockThreshold
    case appRuleSideButtons
    case appRuleSmoothVertical
    case appRuleSmoothHorizontal
    case appRuleReverseVertical
    case appRuleReverseHorizontal
    case appRuleSimulateTrackpad
    case appRuleBypass

    // MARK: 添加应用
    case addAppRule

    // MARK: 侧键绑定
    case sideButton
    case swapBackForward
    case triggerOnMouseUp

    // MARK: 指针
    case pointerAccelManaged
    case pointerAccelerationValue
    case pointerSpeedManaged
    case pointerSpeedFactor
    case cursorZoomEnabled
    case zoomApplyNow
    case zoomOpenSystemSettings
    case logiDPI
    case deviceRow

    // MARK: 关于 / 权限
    case requestPermission
    case autoCheckUpdates
    case resetAllSettings

    // MARK: 指针（设备操作）
    case pointerRefresh
    case pointerRestoreDefaults
}

/// 悬停解释文案表。
///
/// 只放「看标签猜不出来」的东西：语义边界、单位、以及容易误用的组合。
/// 一眼能看懂的开关不放 —— 悬停气泡太多会变成噪音，用户干脆不再悬停。
///
/// 文案纪律（由 harness T 段守着）：
///   · 说清「这个数字 / 开关改变什么」，而不是复述标签；
///   · 有单位就给单位，有系统默认值就给默认值；
///   · 涉及「程序观测不到、必须你自己确认」的地方必须写明，不代用户宣称。
enum HelpText {
    static func text(_ key: HelpKey) -> String {
        switch key {
        // MARK: 全局 · 滚动
        case .masterEnabled:
            return "总开关。关掉后 Smoose 完全退出滚动接管，滚轮恢复 macOS 原生的逐格跳动，其他所有设置项一起失效。"
        case .ignoreTrackpad:
            return "只处理鼠标滚轮。内建触控板和 Magic Mouse 本身就在输出连续滚动，交给系统处理，避免被二次平滑成拖影。"
        case .simulateTrackpad:
            return "把平滑后的滚动标记成触控板手势（带开始 / 结束 / 惯性相位），Chrome、Safari 会直接采用上面调好的曲线，不再自己二次加工。个别 App 表现异常时关掉，关掉后完全回到旧的「滚轮 + 像素」行为。"
        case .speed:
            return "距离倍率：一格滚轮实际走多远。≈4× 接近 Chrome/Safari 的原生距离，≈1.5× 接近原生 AppKit 控件；不同 App 的行距换算不同，这正是每应用配置存在的原因。"
        case .wheelLines:
            return "把一格滚轮折算成多少行。只影响滚轮鼠标，触控板不受影响；1 = 系统原样。"
        case .smoothness:
            return "插值时间常数，不是「强度」百分比。越大尾巴越长、越像触控板；越小越干脆、越接近原生逐格。下面的曲线图就是按这一档实时画的。"
        case .minStep:
            return "量化下限，单位像素。低于此值的微动也会被放大到这个值，避免轻推滚轮时没有反应；调太大则小幅度滚动会被跳过。"
        case .axisLockThreshold:
            return "斜向锁定：当较小轴不到较大轴的这一比例时，丢弃较小轴，抑制触控板或高分辨率滚轮带出的横向抖动。0 = 完全关闭；0.2 表示 20% 以下锁定。真正的斜向滚动不会被吃掉。"
        case .smoothVertical:
            return "是否平滑垂直方向的滚动。关掉后垂直方向保持原生逐格，水平方向仍按这里的设置平滑。"
        case .reverseVertical:
            return "把垂直滚动方向反过来，等于关掉系统「自然滚动」时给滚轮单独反向，两个设置不要同时改。"
        case .smoothHorizontal:
            return "是否平滑水平方向的滚动。多数 App 的水平滚动量本来就小，关掉可以让横向翻页更干脆。"
        case .reverseHorizontal:
            return "把水平滚动方向反过来，只影响左右横滚，不改变垂直方向。"
        case .curvePreview:
            return "按当前「顺滑度」实时画出的插值曲线：横轴是时间，纵轴是这一格滚轮的完成进度。尾巴拖得越长，实际手感越「飘」。"
        case .presets:
            return "一键套用一档手感，只覆盖曲线参数（距离倍率 / 顺滑度 / 最小步长 / 滚轮行数）；你配好的「按住加速」和「按住透传」键会原样保留。"
        case .launchAtLogin:
            return "登录时自动启动。需要 Smoose 放在「应用程序」文件夹内才能注册登录项，移动位置后要重新勾一次。"

        // MARK: 临时透传 / 按住加速
        case .bypassModifiers:
            return "按住这些修饰键时临时回到原生逐格滚动，用来做精细操作（PR 审阅、时间线、表格微调）。松手立即恢复平滑。"
        case .boostModifiers:
            return "按住这些修饰键时把「距离倍率」再乘一档，用来滚长文档和长网页。松手立即恢复。"
        case .boostFactor:
            return "按住上面那些键时，距离倍率再乘的倍数。上限与滚动引擎一致，拖不到更高的值不是界面坏了。"

        // MARK: 每应用
        case .appRuleEnabled:
            return "只对这个 App 生效的开关。关掉时该 App 走全局配置，这一行的所有数值都会被忽略。"
        case .appRuleSpeed:
            return "只覆盖这个 App 的距离倍率，其他 App 仍走全局。适合给代码编辑器、终端配低倍率，给设计工具配高倍率。"
        case .appRuleWheelLines:
            return "只覆盖这个 App 的每格行数。聊天类软件默认按「聊天软件」预设给了一档更慢的值。"
        case .appRuleSmoothness:
            return "只覆盖这个 App 的顺滑度。"
        case .appRuleMinStep:
            return "只覆盖这个 App 的最小步长。"
        case .appRuleAxisLockThreshold:
            return "只对这个 App 生效的斜向锁定阈值。0 = 关闭；例如 0.2 表示较小轴不足较大轴 20% 时丢弃它，适合浏览器 / 文档这类不希望页面轻微左右抖动的场景。"
        case .appRuleSideButtons:
            return "这个 App 的侧键绑定覆盖。选「跟随全局」表示不单独配，用「按键」页里的全局绑定。"
        case .appRuleSmoothVertical:
            return "只对这个 App 生效的垂直平滑开关。关掉后这个 App 的垂直滚动回到原生逐格，其他 App 仍按全局平滑。"
        case .appRuleSmoothHorizontal:
            return "只对这个 App 生效的水平平滑开关。多数 App 的水平滚动量本来就小，单独关掉可以让横向翻页更干脆。"
        case .appRuleReverseVertical:
            return "只把这个 App 的垂直滚动方向反过来。习惯关掉系统「自然滚动」的人常用它做补偿，别和系统设置同时改。"
        case .appRuleReverseHorizontal:
            return "只把这个 App 的水平滚动方向反过来，只影响左右横滚，不改变垂直方向，也不影响其他 App。"
        case .appRuleSimulateTrackpad:
            return "只对这个 App 把平滑后的滚动标记成触控板手势。优先级高于全局的同一个开关，个别 App 表现异常时在这里单独关掉。"
        case .appRuleBypass:
            return "只在这个 App 里，按住这些键临时回到原生逐格滚动。与全局的「按住透传」取并集，任一处命中就透传。"

        // MARK: 添加应用
        case .addAppRule:
            return "从正在运行的应用里挑一个，单独配置它的滚动手感。顶部「新增预设」可选手动模板；选「自动识别」时，聊天软件、浏览器和常见编辑器 / 终端会自动套对应模板，未知 App 沿用全局。新增后每行右侧的魔杖按钮仍可重新套模板。"

        // MARK: 侧键绑定
        case .sideButton:
            return "鼠标第 3 / 4 / 5 键（拇指侧键）按下去时执行的动作。罗技 G502 X、MX 等插上即可用，不需要额外驱动。"
        case .swapBackForward:
            return "有些鼠标的前进 / 后退键和 macOS 的习惯相反，打开后把 4 和 5 键互换。只影响按键映射，不改滚动方向。"
        case .triggerOnMouseUp:
            return "改成「松开按键时」才触发。按下即触发响应更快，但误触概率高；做演示或游戏时建议打开。"

        // MARK: 指针
        case .pointerAccelManaged:
            return "由 Smoose 接管指针加速度，等价于关掉 macOS 自带的加速曲线。关掉这个开关后下面的数值不生效，系统回到自己的曲线。"
        case .pointerAccelerationValue:
            return "0 = 严格线性（1:1，等同 Windows/Linux 的手感）；系统默认约 2.5。注意只把这个数值填成 0 并不会关闭加速曲线，必须同时打开上面的开关。"
        case .pointerSpeedManaged:
            return "用重写鼠标移动增量的方式自定义指针速度倍率（现代 macOS 的 HIDPointerResolution 不可写，只能走这条路）。"
        case .pointerSpeedFactor:
            return "1.0 = 系统原速。拖拽、绘图等按住按键的场景会临时保持系统原速，保证选区和拖放精度，所以实际手感不是全程等比。"
        case .cursorZoomEnabled:
            return "系统自带的「摇动鼠标指针以定位」：快速移动鼠标时指针临时放大，方便在多屏上找到它。macOS 只在登录时读这个偏好，拨动开关后 Smoose 会用自身辅助功能权限去系统设置里重载，效果需要你摇一下鼠标确认。"
        case .zoomApplyNow:
            return "现在就到系统设置里按当前开关状态拨动并校验终态，不用重新登录。会短暂打开系统设置窗口，完成后回到你之前所在的应用。"
        case .zoomOpenSystemSettings:
            return "打开系统设置的显示设置页，可以自己手动拨同一个开关。"
        case .logiDPI:
            return "通过罗技 HID++ 2.0 直改鼠标板载 DPI，不需要安装 Logitech G Hub。改的是鼠标里的值，换一台电脑也仍然有效。"
        case .deviceRow:
            return "当前检测到的指针设备，以及 Smoose 读到的加速度参数。显示「写入未生效」说明系统或驱动把值重置了，点「重新检测」再写一次。"

        // MARK: 关于 / 权限
        case .requestPermission:
            return "弹出系统授权框，让 Smoose 拿到辅助功能权限。没有它滚轮接管、指针调校和侧键绑定都不工作；刚授权完还不行就重启一次 App。"
        case .autoCheckUpdates:
            return "每天静默查一次版本源，发现新版本只在菜单栏和「关于」页提示，不弹窗也不自动下载。关掉后仍可手动检查更新。"
        case .resetAllSettings:
            return "清空全部配置（全局、每应用、侧键绑定）恢复出厂值，立即生效且无法撤销，同时把指针加速度恢复成 macOS 系统默认。"

        // MARK: 指针（设备操作）
        case .pointerRefresh:
            return "重新枚举指针设备，并把加速度 / 跟踪速度参数重写一遍。系统或驱动把值重置掉、状态区显示「写入未生效」时用它。"
        case .pointerRestoreDefaults:
            return "关掉 Smoose 的加速度接管，并把指针加速度与跟踪速度恢复成 macOS 系统默认值。之后手感完全由系统决定，可随时重新打开上面的开关。"
        }
    }
}

/// 悬停解释的统一入口。
///
/// 走 SwiftUI 的 `.help(_:)`（macOS 上等价于给背后 NSView 设 `toolTip`）。
/// 包一层的意义是给「哪里该有悬停解释」一个唯一的调用形状：以后要统一加
/// 「快捷键样式」「延迟」或改成 AppKit 直设 toolTip，只改这里一处。
extension View {
    func smooseHelp(_ key: HelpKey) -> some View {
        help(HelpText.text(key))
    }

    func smooseHelp(_ text: String) -> some View {
        help(text)
    }

    /// 可选键：没有解释的控件（例如「跟随全局」这种一眼懂的）走这条，
    /// 不需要调用点写 `if let`。
    func smooseHelp(_ key: HelpKey?) -> some View {
        modifier(OptionalHelpTip(key: key))
    }
}

/// `.help` 的开关版本。用 ViewModifier 而不是在调用点写 `if let`，
/// 是为了让两条分支共用一个返回类型（`some View` 不允许分支形状不同）。
private struct OptionalHelpTip: ViewModifier {
    let key: HelpKey?

    func body(content: Content) -> some View {
        if let key {
            content.help(HelpText.text(key))
        } else {
            content
        }
    }
}

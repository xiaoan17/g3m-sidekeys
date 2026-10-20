//
//  DesignTokens.swift — 全局设计 token
//
//  为什么要有这一层?
//
//  界面里到处散落着魔法数字: 内边距 20、18、16、14、12、圆角 10、
//  字号 15/13/12/11…… 换一个地方就得再猜一次, 改一次全窗口都得翻代码。
//
//  这里把「整套界面共用的那组量」集中到**一个**地方, 相当于 Web 项目里的
//  design token (Tailwind 的 theme / shadcn 的 CSS 变量)。好处:
//    - 改一处, 全局生效
//    - 浅色 / 深色自动适配, 不用在两处各写一遍
//    - 新增界面时照着 token 写, 风格自然一致
//
//  原则:
//    - 只有**语义** token (space.md / radius.card / text.title),
//      不暴露具体像素值给调用方
//    - 所有颜色都用 NSColor 的动态色, 系统切深浅色时自动跟随
//    - 想加第二个 UI 库之前先看看这里 —— 绝大多数需求一个 token 就够了
//

import AppKit

// MARK: - 间距

/// 间距刻度 (pt)
///
/// 4 的倍数, 方便对齐成 8pt / 4pt 网格。
enum Space {
    /// 4pt —— 标签与内容之间的最小缝隙
    static let xxs: CGFloat = 4
    /// 8pt —— 同一组元素内部
    static let xs: CGFloat = 8
    /// 12pt —— 卡片内元素之间
    static let sm: CGFloat = 12
    /// 16pt —— 卡片内边距、卡片之间
    static let md: CGFloat = 16
    /// 20pt —— 窗口内容边缘
    static let lg: CGFloat = 20
    /// 28pt —— 标题与内容之间的大留白
    static let xl: CGFloat = 28
}

// MARK: - 圆角

/// 圆角半径 (pt)
enum Radius {
    /// 6pt —— 小控件 (按钮、输入框)
    static let control: CGFloat = 6
    /// 10pt —— 卡片
    static let card: CGFloat = 10
}

// MARK: - 字号

/// 字号与字重
///
/// macOS 的 Dynamic Type 靠 `NSFont.systemFont(ofSize:)` 跟随,
/// 这里只给语义, 不给调用方写死字号的机会。
enum Typography {
    /// 窗口主标题
    static let title = NSFont.systemFont(ofSize: 17, weight: .semibold)
    /// 卡片小标题 (分组名)
    static let sectionTitle = NSFont.systemFont(ofSize: 11, weight: .semibold)
    /// 正文 / 行标题
    static let body = NSFont.systemFont(ofSize: 13)
    /// 次要说明文字
    static let caption = NSFont.systemFont(ofSize: 11)
    /// 快捷键显示 (等宽, 多个快捷键排在一起时不会左右跳动)
    static let shortcut = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
}

// MARK: - 颜色

/// 语义颜色
///
/// 全部用 NSColor 的动态色: 跟随系统深浅色, 也跟随用户的「强调色」设置。
enum Palette {
    /// 卡片背景
    static let cardBackground = NSColor.labelColor.withAlphaComponent(0.045)
    /// 卡片描边
    static let cardBorder = NSColor.separatorColor.withAlphaComponent(0.5)
    /// 分隔线
    static let separator = NSColor.separatorColor
    /// 主文字
    static let primaryText = NSColor.labelColor
    /// 次要文字
    static let secondaryText = NSColor.secondaryLabelColor
    /// 三级文字 (分组小标题)
    static let tertiaryText = NSColor.tertiaryLabelColor
    /// 强调色 (已自定义的绑定、选中态)
    static let accent = NSColor.controlAccentColor
}

// MARK: - 动效

/// 动画参数
///
/// 统一在这里定义, 避免各处随手写 0.25 / 0.2 导致节奏不一致。
enum Motion {
    /// 常规过渡 (悬停、按下)
    static let fast: TimeInterval = 0.15
    /// 稍慢的过渡 (窗口出现、布局变化)
    static let normal: TimeInterval = 0.25
}

// MARK: - 布局常量

/// 窗口与控件的固定布局量
enum Layout {
    /// 窗口最小宽度
    static let windowMinWidth: CGFloat = 560
    /// 窗口最小高度
    static let windowMinHeight: CGFloat = 420
    /// 快捷键徽标的最小宽度 (右对齐成一列)
    static let badgeMinWidth: CGFloat = 52
    /// 悬停高亮层的不透明度
    static let hoverAlpha: CGFloat = 0.06
}

//
//  BindingSettingsWindowController.swift — 按键绑定设置窗口
//
//  界面上一行一个物理来源 (侧键1/侧键2/滚轮按下/滚轮上滚/滚轮下滚),
//  每行一个下拉框, 可以为它挑一个预设动作, 或者现场录一条自己的组合键。
//
//  布局原则:
//    - 尺寸与间距全部取自 DesignTokens, 不写死魔法数字
//    - 用 Auto Layout 让内容自然撑开, 窗口尺寸由内容决定
//    - 分组用「卡片」(圆角 + 极浅底色) 而不是一堆贯穿全宽的分隔线,
//      视觉上更像 macOS 原生设置面板
//    - 名称 / 徽标 / 下拉框 三列严格对齐, 一眼能扫完
//
//  交互原则:
//    - 改过默认值的行会显示一个小圆点, 不用逐行对比就知道改了什么
//    - 鼠标悬停整行有高亮, 明确「这一行是可点的」
//    - 顶部状态胶囊实时显示「运行中 / 已暂停」
//

import AppKit

// MARK: - 下拉框

/// 带来源标记的下拉框
final class BindingPopUpButton: NSPopUpButton {
    var source: BindingSource?
}

/// 「自定义快捷键…」菜单项的标记 (不是一个 BindingAction)
final class CustomShortcutMarker: NSObject {
    static let shared = CustomShortcutMarker()
}

// MARK: - 卡片

/// 圆角卡片容器: 圆角 + 极浅底色, 用来分组
///
/// 注意: 颜色必须用 `NSColor` 的动态颜色 (`.windowBackgroundColor` 等),
/// 不要用 `quaternarySystemFill` —— 它是 macOS 14+ 才有的 API, 而本 App 的
/// 部署目标是 13.0, 用了会直接编译不过。
final class CardView: NSView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Radius.card
        layer?.cornerCurve = .continuous
        applyColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) 不支持 —— 本视图完全由代码构建")
    }

    /// 颜色是 CGColor, 不跟随外观自动切换, 需要在切换时手动刷新
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // 用带一点透明度的 labelColor 叠出「比窗口底色再深/浅一层」的卡片感,
            // 浅色和深色模式都能自动适配。
            layer?.backgroundColor = Palette.cardBackground.cgColor
            layer?.borderColor = Palette.cardBorder.cgColor
            layer?.borderWidth = 1
        }
    }
}

// MARK: - 行背景 (悬停高亮)

/// 行的背景层: 鼠标进入时高亮, 离开时复原
///
/// 单独做一个 view 铺在行底, 而不是给每个控件都加 hover 逻辑 ——
/// 一次实现, 所有行通用。
final class RowBackgroundView: NSView {

    /// 当前是否高亮
    private var isHighlighted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) 不支持 —— 本视图完全由代码构建")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                        options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                        owner: self,
                                        userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        setHighlighted(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHighlighted(false)
    }

    private func setHighlighted(_ highlighted: Bool) {
        guard highlighted != isHighlighted else { return }
        isHighlighted = highlighted
        applyBackground()
    }

    private func applyBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isHighlighted
                ? Palette.accent.withAlphaComponent(Layout.hoverAlpha).cgColor
                : nil
        }
    }
}

// MARK: - 状态胶囊

/// 顶部的小圆角胶囊, 显示当前运行状态
final class StatusPillView: NSView {

    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")

    /// 更新状态文案与配色
    func update(status: String, active: Bool) {
        label.stringValue = status
        label.textColor = active ? Palette.primaryText : Palette.secondaryText

        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = active ? Palette.accent : Palette.secondaryText
            dot.layer?.backgroundColor = color.withAlphaComponent(0.9).cgColor
            layer?.backgroundColor = color.withAlphaComponent(0.12).cgColor
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5

        label.font = Typography.caption
        label.alignment = .center

        let stack = NSStackView(views: [dot, label])
        stack.orientation = .horizontal
        stack.spacing = Space.xxs + 2
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.xs),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.xs),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Space.xxs + 1),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(Space.xxs + 1)),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) 不支持 —— 本视图完全由代码构建")
    }
}

// MARK: - 窗口控制器

final class BindingSettingsWindowController: NSWindowController {

    /// 每个来源对应的一行控件
    private struct Row {
        let popup: BindingPopUpButton
        let badge: NSTextField
        let dot: NSView
    }

    private var rows: [BindingSource: Row] = [:]

    /// 所有下拉框共用的宽度约束 (统一激活, 保证等宽)
    private var popupWidthConstraints: [NSLayoutConstraint] = []

    /// 顶部状态胶囊
    private var statusPill: StatusPillView?

    init() {
        // 先给一个有内容的估算尺寸, 真正的尺寸在 buildUI 之后由内容决定
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0,
                                                  width: Layout.windowMinWidth,
                                                  height: Layout.windowMinHeight),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.title = "按键绑定设置"
        window.isReleasedWhenClosed = false
        // 窗口里全是标准控件, 让 App 回到前台时能正常成为 key window
        window.hidesOnDeactivate = false
        super.init(window: window)

        buildUI()
        refresh()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(stateDidChange),
            name: .appStateDidChange,
            object: nil
        )
    }

    /// 本类完全用代码搭建界面, 不走 storyboard
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 不支持 —— 本窗口完全由代码构建")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// 打开窗口并置于前台
    func present() {
        refresh()
        guard let window else { return }
        // 首次打开时居中, 之后保持用户拖动的位置
        if !window.isVisible {
            window.center()
        }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - 界面搭建

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let titleStack = makeHeader()
        let sidesCard = makeCard(title: "鼠标侧键",
                                 subtitle: "G3M 侧键 · 标准鼠标的 button 3 / 4",
                                 rows: [.sideForward, .sideBack])
        let scrollCard = makeCard(title: "滚轮",
                                  subtitle: "滚轮按下 · 上滚 · 下滚",
                                  rows: [.middleClick, .scrollUp, .scrollDown])

        let root = NSStackView(views: [titleStack, sidesCard, scrollCard, makeFooter()])
        root.orientation = .vertical
        root.spacing = Space.md
        root.alignment = .leading
        root.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Space.lg),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Space.lg),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: Space.md + 2),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Space.md)
        ])

        // 卡片和底部说明要跟标题左边缘对齐、并且一样宽
        for view in [sidesCard, scrollCard] {
            view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate(popupWidthConstraints)

        // 窗口尺寸完全由内容决定
        content.layoutSubtreeIfNeeded()
        let width = max(Layout.windowMinWidth,
                        nameColumnWidth + Space.sm + popupWidth + Space.xs + Layout.badgeMinWidth + Space.sm + Space.lg * 2)
        let height = root.fittingSize.height + Space.md * 2
        window?.setContentSize(NSSize(width: width, height: height))
        window?.contentMinSize = NSSize(width: Layout.windowMinWidth, height: Layout.windowMinHeight)
    }

    /// 标题区: 标题 + 副标题 + 右侧状态胶囊
    private func makeHeader() -> NSView {
        let header = NSTextField(labelWithString: "按键绑定")
        header.font = Typography.title

        let subtitle = NSTextField(labelWithString: "为每个鼠标按键指定动作，改动立即生效，无需重启。")
        subtitle.font = Typography.caption
        subtitle.textColor = Palette.secondaryText

        let textStack = NSStackView(views: [header, subtitle])
        textStack.orientation = .vertical
        textStack.spacing = Space.xxs
        textStack.alignment = .leading

        let pill = StatusPillView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        statusPill = pill

        let row = NSStackView(views: [textStack, pill])
        row.orientation = .horizontal
        row.spacing = Space.sm
        row.alignment = .centerY
        // 标题占满剩余空间, 胶囊靠右
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pill.setContentHuggingPriority(.required, for: .horizontal)
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)
        return row
    }

    /// 一张卡片: 小标题 + 说明 + 若干行
    private func makeCard(title: String, subtitle: String, rows sources: [BindingSource]) -> NSView {
        let card = CardView()
        card.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = Typography.sectionTitle
        label.textColor = Palette.tertiaryText

        let sub = NSTextField(labelWithString: subtitle)
        sub.font = Typography.caption
        sub.textColor = Palette.tertiaryText

        let heading = NSStackView(views: [label, sub])
        heading.orientation = .horizontal
        heading.spacing = Space.xs
        heading.alignment = .firstBaseline

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(inset(heading, top: 0, leading: Space.sm, bottom: Space.xxs, trailing: 0))

        for (index, source) in sources.enumerated() {
            stack.addArrangedSubview(makeRow(for: source))
            if index < sources.count - 1 {
                stack.addArrangedSubview(makeInsetSeparator())
            }
        }

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: Space.xs + 2),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -(Space.xs)),
            // 每一行都撑满卡片宽度, 保证分隔线 / 下拉框右边缘对齐
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 480)
        ])

        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        return card
    }

    private func makeRow(for source: BindingSource) -> NSView {
        // 行背景 (悬停高亮)
        let background = RowBackgroundView()
        background.translatesAutoresizingMaskIntoConstraints = false

        // 「已自定义」指示点
        let dot = NSView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6)
        ])

        let name = NSTextField(labelWithString: source.displayName)
        name.font = Typography.body
        name.toolTip = source.hint
        // 来源名占一列固定宽度, 让同一窗口里所有行的下拉框左边缘对齐。
        // 宽度按最长的那条名字量出来 —— 不是写死的像素值, 换字号也不会错位。
        name.widthAnchor.constraint(equalToConstant: nameColumnWidth).isActive = true

        let popup = BindingPopUpButton(frame: .zero, pullsDown: false)
        popup.source = source
        popup.target = self
        popup.action = #selector(actionChanged(_:))
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.controlSize = .regular
        popup.font = Typography.body
        // NSPopUpButton 默认抗拉伸优先级很低, 在 stack 里会被额外空间撑宽。
        // 这里锁死宽度, 保证所有行下拉框等宽。
        popup.setContentHuggingPriority(.required, for: .horizontal)
        popup.setContentCompressionResistancePriority(.required, for: .horizontal)

        // 快捷键徽标: 显示当前绑定的实际组合键
        let badge = NSTextField(labelWithString: "")
        badge.font = Typography.shortcut
        badge.textColor = Palette.secondaryText
        badge.alignment = .right
        badge.lineBreakMode = .byTruncatingMiddle
        badge.widthAnchor.constraint(equalToConstant: Layout.badgeMinWidth).isActive = true
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        // 右对齐成一组: [徽标][下拉框] —— 徽标紧挨下拉框, 一眼看得出
        // 「这个框选的东西 = 这个快捷键」。中间留白由 name 吃掉。
        let trailing = NSStackView(views: [badge, popup])
        trailing.orientation = .horizontal
        trailing.spacing = Space.xs
        trailing.alignment = .centerY
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [dot, name, trailing])
        row.orientation = .horizontal
        row.spacing = Space.xs
        row.alignment = .centerY
        row.distribution = .fill
        row.edgeInsets = NSEdgeInsets(top: Space.xs,
                                      left: Space.sm,
                                      bottom: Space.xs,
                                      right: Space.sm)
        row.translatesAutoresizingMaskIntoConstraints = false

        // 背景铺满整行
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            row.topAnchor.constraint(equalTo: background.topAnchor),
            row.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])

        // 所有行共用同一个宽度值, 保证左侧下拉框严格等宽对齐
        popupWidthConstraints.append(popup.widthAnchor.constraint(equalToConstant: popupWidth))

        rows[source] = Row(popup: popup, badge: badge, dot: dot)
        return background
    }

    /// 来源名列宽: 按最长名字实测
    private lazy var nameColumnWidth: CGFloat = {
        let widest = BindingSource.allCases
            .map { ($0.displayName as NSString).size(withAttributes: [.font: Typography.body]).width }
            .max() ?? 100
        return ceil(widest) + 6
    }()

    /// 下拉框宽度: 实测菜单里最长的那个标题
    ///
    /// 不能用写死的候选字符串猜 —— 菜单项一旦增删, 猜短了就会与内容
    /// 所需的固有宽度冲突 (Auto Layout 会悄悄破掉等宽约束, 下拉框随内容变形)。
    /// 所以直接构建一份真实菜单来量。
    ///
    /// 注意要量**所有来源**的菜单: 侧键的菜单比滚轮多出「按住修饰键」那几项,
    /// 只量滚轮那份会量短。
    private lazy var popupWidth: CGFloat = {
        var titles: [String] = []
        for source in BindingSource.allCases {
            let menu = buildMenu(for: source)
            for item in menu.items {
                titles.append(item.title)
                if let submenu = item.submenu {
                    titles.append(contentsOf: submenu.items.map(\.title))
                }
            }
        }
        let widest = titles
            .map { ($0 as NSString).size(withAttributes: [.font: Typography.body]).width }
            .max() ?? 160
        // 留出右侧箭头和左右内边距
        return ceil(widest) + 46
    }()

    private func makeFooter() -> NSView {
        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetToDefault))
        reset.bezelStyle = .rounded
        reset.controlSize = .regular
        reset.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        // 说明文字独占一行、按容器宽度自动折行 —— 以前它和按钮挤在一个
        // 横向 stack 里, 折出来的第二行会被窗口下边缘裁掉。
        let note = NSTextField(wrappingLabelWithString:
            "侧键在系统里上报为 RightCtrl+C / RightCtrl+V，工具会自动识别；"
            + "标准鼠标走 button 3 / 4。绑定滚轮后，触控板的双指滚动也会触发。")
        note.font = Typography.caption
        note.textColor = Palette.secondaryText
        note.alignment = .left
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 让说明文字跟随容器宽度折行
        note.translatesAutoresizingMaskIntoConstraints = false
        let noteRow = NSView()
        noteRow.translatesAutoresizingMaskIntoConstraints = false
        noteRow.addSubview(note)
        NSLayoutConstraint.activate([
            note.leadingAnchor.constraint(equalTo: noteRow.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: noteRow.trailingAnchor),
            note.topAnchor.constraint(equalTo: noteRow.topAnchor),
            note.bottomAnchor.constraint(equalTo: noteRow.bottomAnchor)
        ])

        // 按钮靠右, 与下拉框的右边缘对齐 (下拉框是窗口里最右的元素)
        let buttonRow = NSStackView(views: [reset])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY

        let stack = NSStackView(views: [noteRow, buttonRow])
        stack.orientation = .vertical
        stack.spacing = Space.sm
        stack.alignment = .leading

        // 两行都跟外层同宽, 保证说明文字能用满整个窗口宽度,
        // 并让按钮能贴到右边缘
        noteRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        buttonRow.alignment = .trailing
        return stack
    }

    private func makeInsetSeparator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        return inset(line, top: 0, leading: Space.sm, bottom: 0, trailing: 0)
    }

    /// 给视图套一层内边距
    private func inset(_ view: NSView,
                       top: CGFloat, leading: CGFloat,
                       bottom: CGFloat, trailing: CGFloat) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: top),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leading),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -trailing),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -bottom)
        ])
        return container
    }

    // MARK: - 菜单

    /// 构建动作下拉菜单
    ///
    /// - Parameter source: 该菜单所属的来源。滚轮没有「按住/松开」之分,
    ///   所以不提供「模拟按住修饰键」。
    private func buildMenu(for source: BindingSource) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(sectionHeader("常用快捷键"))
        menu.addItem(actionItem("复制", action: .shortcut(.copy), key: "C"))
        menu.addItem(actionItem("粘贴", action: .shortcut(.paste), key: "V"))
        menu.addItem(actionItem("剪切", action: .shortcut(.cut), key: "X"))
        menu.addItem(actionItem("撤销", action: .shortcut(.undo), key: "Z"))
        menu.addItem(actionItem("重做", action: .shortcut(.redo), key: "Z", shift: true))
        menu.addItem(actionItem("全选", action: .shortcut(.selectAll), key: "A"))
        menu.addItem(actionItem("查找", action: .shortcut(.find), key: "F"))
        menu.addItem(actionItem("关闭窗口", action: .shortcut(.closeWindow), key: "W"))
        menu.addItem(actionItem("隐藏应用", action: .shortcut(.hideApp), key: "H"))
        menu.addItem(actionItem("最小化", action: .shortcut(.minimize), key: "M"))
        menu.addItem(actionItem("切换全屏", action: .shortcut(.fullScreen), key: "F", control: true))
        menu.addItem(actionItem("下一个标签页", action: .shortcut(.nextTab), key: "Tab", control: true))
        menu.addItem(actionItem("上一个标签页", action: .shortcut(.prevTab), key: "Tab", control: true, shift: true))

        menu.addItem(.separator())
        menu.addItem(sectionHeader("其他"))

        let custom = NSMenuItem(title: "自定义快捷键…", action: nil, keyEquivalent: "")
        custom.representedObject = CustomShortcutMarker.shared
        menu.addItem(custom)

        menu.addItem(actionItem("模拟鼠标左键单击", action: .mouseClick(.left)))
        menu.addItem(actionItem("模拟鼠标右键单击", action: .mouseClick(.right)))
        menu.addItem(actionItem("模拟鼠标中键单击", action: .mouseClick(.middle)))

        // 「按住修饰键」需要按下/松开成对, 滚轮给不了
        if source != .scrollUp && source != .scrollDown {
            menu.addItem(.separator())
            menu.addItem(sectionHeader("模拟按住修饰键"))
            for modifier in ModifierKey.allCases {
                menu.addItem(actionItem("按住\(modifier.displayName)",
                                        action: .holdModifier(modifier)))
            }
        }

        menu.addItem(.separator())
        menu.addItem(actionItem("禁用此键", action: .disabled))
        menu.addItem(actionItem("保留系统默认行为", action: .passThrough))

        return menu
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// 动作菜单项
    ///
    /// 顺手把组合键显示在右侧的快捷键列 —— 原生菜单的 keyEquivalent 会
    /// 显示成 ⌘C 这样的等宽小字, 比在标题里拼字符串整齐得多。
    private func actionItem(_ title: String,
                            action: BindingAction,
                            key: String = "",
                            control: Bool = false,
                            shift: Bool = false) -> NSMenuItem {
        var equivalent = ""
        var mask: NSEvent.ModifierFlags = []
        if !key.isEmpty {
            equivalent = key
            mask = [.command]
            if control { mask.insert(.control) }
            if shift { mask.insert(.shift) }
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: equivalent)
        item.keyEquivalentModifierMask = mask
        item.representedObject = action
        return item
    }

    // MARK: - 刷新

    /// 按当前绑定表刷新所有下拉框
    private func refresh() {
        let table = AppState.shared.bindings
        let defaults = BindingTable.default

        for source in BindingSource.allCases {
            guard let row = rows[source] else { continue }
            let action = table[source]

            let menu = buildMenu(for: source)
            row.popup.menu = menu

            // 菜单项全部是扁平的 —— 没有子菜单, 所以这里只需要一层查找。
            // (NSPopUpButton 不支持子菜单: 点父项只会选中父项, 而父项没有
            //  绑定动作, 于是那 7 个「按住修饰键」选项永远选不中。)
            if let index = menu.items.firstIndex(where: { ($0.representedObject as? BindingAction) == action }) {
                row.popup.selectItem(at: index)
            } else if case .shortcut = action {
                // 自定义的组合键: 选中「自定义快捷键…」, 右侧显示真实组合
                row.popup.selectItem(withTitle: "自定义快捷键…")
            } else {
                // 兜底: 宁可显示成「保留系统默认行为」, 也不要乱选到某个
                // 分隔符 / 小标题上
                if let index = menu.items.firstIndex(where: {
                    ($0.representedObject as? BindingAction) == .passThrough
                }) {
                    row.popup.selectItem(at: index)
                }
            }

            // 徽标: 显示当前绑定的实际组合键, 避免和下拉框标题重复
            switch action {
            case .shortcut(let sc):
                row.badge.stringValue = sc.displayString
                row.badge.textColor = Palette.primaryText
            case .holdModifier(let m):
                row.badge.stringValue = m.displayName
                row.badge.textColor = Palette.secondaryText
            case .mouseClick, .disabled, .passThrough:
                // 这三种下拉框标题本身已经说清楚了, 徽标留空
                row.badge.stringValue = ""
            }

            // 「已自定义」指示点: 与默认值不同就点亮
            let customized = action != defaults[source]
            row.dot.isHidden = !customized
            let appearance = window?.effectiveAppearance ?? NSAppearance.currentDrawing()
            appearance.performAsCurrentDrawingAppearance {
                row.dot.layer?.backgroundColor = Palette.accent.cgColor
            }
        }

        updateStatusPill()
    }

    /// 顶部状态胶囊: 反映总开关与监听状态
    private func updateStatusPill() {
        let enabled = AppState.shared.enabled
        statusPill?.update(status: enabled ? "映射运行中" : "映射已暂停", active: enabled)
    }

    @objc private func stateDidChange() {
        // 通知是同步发出来的, 这里推迟一拍再刷新, 避免在菜单回调里改菜单
        DispatchQueue.main.async { [weak self] in
            self?.refresh()
        }
    }

    // MARK: - 动作

    @objc private func actionChanged(_ sender: BindingPopUpButton) {
        guard let source = sender.source,
              let item = sender.selectedItem else { return }

        if item.representedObject is CustomShortcutMarker {
            recordCustomShortcut(for: source, popup: sender)
            return
        }

        guard let action = item.representedObject as? BindingAction else { return }
        var table = AppState.shared.bindings
        table.set(action, for: source)
        AppState.shared.bindings = table
    }

    private func recordCustomShortcut(for source: BindingSource, popup: BindingPopUpButton) {
        guard let shortcut = ShortcutRecorderController.record() else {
            // 取消: 把下拉框恢复成原来的绑定
            refresh()
            return
        }
        var table = AppState.shared.bindings
        table.set(.shortcut(shortcut), for: source)
        AppState.shared.bindings = table
        refresh()
        _ = popup
    }

    @objc private func resetToDefault() {
        AppState.shared.bindings = .default
    }
}

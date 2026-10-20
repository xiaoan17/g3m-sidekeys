//
//  BindingSettingsWindowController.swift — 按键绑定设置窗口
//
//  界面上一行一个物理来源 (侧键1/侧键2/滚轮按下/滚轮上滚/滚轮下滚),
//  每行一个下拉框, 可以为它挑一个预设动作, 或者现场录一条自己的组合键。
//
//  布局原则 (v1.2.1 重做):
//    - 不用写死的像素宽度。以前每行 / 分隔线都写死 130/260/170/600,
//      一旦系统字号变大或换语言就直接错位、被裁掉。
//    - 用 Auto Layout 让内容自然撑开, 窗口尺寸由内容决定。
//    - 分组用「卡片」(圆角 + quaternary 底色) 而不是一堆贯穿全宽的分隔线,
//      视觉上更像 macOS 原生设置面板。
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
        layer?.cornerRadius = 10
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
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.045).cgColor
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
            layer?.borderWidth = 1
        }
    }
}

// MARK: - 窗口控制器

final class BindingSettingsWindowController: NSWindowController {

    /// 每个来源对应的一行控件
    private struct Row {
        let popup: BindingPopUpButton
        let detail: NSTextField
    }

    private var rows: [BindingSource: Row] = [:]

    /// 所有下拉框共用的宽度约束 (统一激活, 保证等宽)
    private var popupWidthConstraints: [NSLayoutConstraint] = []

    init() {
        // 先给一个有内容的估算尺寸, 真正的尺寸在 buildUI 之后由内容决定
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
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

        let header = NSTextField(labelWithString: "按键绑定")
        header.font = .systemFont(ofSize: 15, weight: .semibold)

        let subtitle = NSTextField(labelWithString: "为每个鼠标按键指定动作，改动立即生效，无需重启。")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor

        let titleStack = NSStackView(views: [header, subtitle])
        titleStack.orientation = .vertical
        titleStack.spacing = 3
        titleStack.alignment = .leading

        // 侧键分组
        let sidesCard = makeCard(title: "鼠标侧键",
                                 rows: [.sideForward, .sideBack])

        // 滚轮分组
        let scrollCard = makeCard(title: "滚轮",
                                  rows: [.middleClick, .scrollUp, .scrollDown])

        let root = NSStackView(views: [titleStack, sidesCard, scrollCard, makeFooter()])
        root.orientation = .vertical
        root.spacing = 16
        root.alignment = .leading
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setCustomSpacing(6, after: titleStack)

        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])

        // 卡片和底部说明要跟标题左边缘对齐、并且一样宽;
        // 标题本身保持自然宽度 (不能被拉宽, 否则文字会居中)。
        for view in [sidesCard, scrollCard] {
            view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate(popupWidthConstraints)

        // 窗口尺寸完全由内容决定
        let width = max(520, nameColumnWidth + 12 + popupWidth + 12 + 56 + 40)
        window?.setContentSize(NSSize(width: width, height: 400))
        content.layoutSubtreeIfNeeded()
        let height = root.fittingSize.height + 36
        window?.setContentSize(NSSize(width: width, height: height))
        window?.contentMinSize = NSSize(width: width, height: height)
    }

    /// 一张卡片: 小标题 + 若干行
    private func makeCard(title: String, rows sources: [BindingSource]) -> NSView {
        let card = CardView()
        card.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(inset(label, top: 0, leading: 14, bottom: 6, trailing: 0))

        for (index, source) in sources.enumerated() {
            stack.addArrangedSubview(makeRow(for: source))
            if index < sources.count - 1 {
                stack.addArrangedSubview(makeInsetSeparator())
            }
        }

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
            // 每一行都撑满卡片宽度, 保证分隔线 / 下拉框右边缘对齐
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 480)
        ])

        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        return card
    }

    private func makeRow(for source: BindingSource) -> NSView {
        let name = NSTextField(labelWithString: source.displayName)
        name.font = .systemFont(ofSize: 13)
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
        // NSPopUpButton 默认抗拉伸优先级很低, 在 stack 里会被额外空间撑宽。
        // 这里锁死宽度, 保证所有行下拉框等宽、多余的宽度留给右侧文字。
        popup.setContentHuggingPriority(.required, for: .horizontal)
        popup.setContentCompressionResistancePriority(.required, for: .horizontal)

        let detail = NSTextField(labelWithString: "")
        detail.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .right
        detail.lineBreakMode = .byTruncatingMiddle
        // 把剩余空间全给它, 文字就贴到卡片右边缘了
        detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true

        let row = NSStackView(views: [name, popup, detail])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        row.distribution = .fill
        row.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)

        // 所有行共用同一个宽度值, 保证左侧下拉框严格等宽对齐
        popupWidthConstraints.append(popup.widthAnchor.constraint(equalToConstant: popupWidth))

        rows[source] = Row(popup: popup, detail: detail)
        return row
    }

    /// 来源名列宽: 按最长名字实测
    private lazy var nameColumnWidth: CGFloat = {
        let font = NSFont.systemFont(ofSize: 13)
        let widest = BindingSource.allCases
            .map { ($0.displayName as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 100
        return ceil(widest) + 6
    }()

    /// 下拉框宽度: 实测菜单里最长的那个标题
    ///
    /// 不能用写死的候选字符串猜 —— 菜单项一旦增删, 猜短了就会与内容
    /// 所需的固有宽度冲突 (Auto Layout 会悄悄破掉等宽约束, 下拉框随内容变形)。
    /// 所以直接构建一份真实菜单来量。
    private lazy var popupWidth: CGFloat = {
        let font = NSFont.systemFont(ofSize: 13)
        // 用「滚轮」这一路来量: 它不含「模拟按住修饰键」子菜单,
        // 但所有主菜单项都在, 足够覆盖最长标题。
        let menu = buildMenu(for: .middleClick)
        var titles: [String] = []
        for item in menu.items {
            titles.append(item.title)
            if let submenu = item.submenu {
                titles.append(contentsOf: submenu.items.map(\.title))
            }
        }
        let widest = titles
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 160
        // 留出右侧箭头和左右内边距
        return ceil(widest) + 46
    }()

    private func makeFooter() -> NSView {
        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetToDefault))
        reset.bezelStyle = .rounded
        reset.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        // 说明文字独占一行、按容器宽度自动折行 —— 以前它和按钮挤在一个
        // 横向 stack 里, 折出来的第二行会被窗口下边缘裁掉。
        let note = NSTextField(wrappingLabelWithString:
            "侧键在系统里上报为 RightCtrl+C / RightCtrl+V，工具会自动识别；"
            + "标准鼠标走 button 3 / 4。绑定滚轮后，触控板的双指滚动也会触发。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
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

        let buttonRow = NSStackView(views: [reset])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY

        let stack = NSStackView(views: [noteRow, buttonRow])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .leading

        // 两行都跟外层同宽, 保证说明文字能用满整个窗口宽度
        noteRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func makeInsetSeparator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        return inset(line, top: 0, leading: 14, bottom: 0, trailing: 0)
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

            // 右侧只显示「具体是什么组合键」, 避免和下拉框标题重复
            switch action {
            case .shortcut(let sc):
                // 菜单项里已经是「复制」这种人类可读的名字, 右边补上真实组合键
                row.detail.stringValue = sc.displayString
                row.detail.textColor = .labelColor
            case .holdModifier(let m):
                row.detail.stringValue = m.displayName
                row.detail.textColor = .secondaryLabelColor
            case .mouseClick, .disabled, .passThrough:
                // 这三种下拉框标题本身已经说清楚了, 右侧留空
                row.detail.stringValue = ""
            }
            // 注意: 不要 isHidden。NSStackView 会把隐藏项移出布局,
            // 于是剩余宽度全部落到下拉框上, 下拉框就会被拉宽变形。
            // 留一个空字符串的占位标签, 它照样吸收多余空间。
        }
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

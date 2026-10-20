# Tools

这些不是 App 的一部分，是排查/验证用的独立小程序。构建 App 时**不会**编译进来
（`build.sh` 只收 `Sources/` 下的文件）。

## verify_binding_ui.swift — 验证下拉框真的能选中

```bash
swiftc -O -target arm64-apple-macos13.0 -o /tmp/verify \
  Sources/Core/*.swift Sources/Capture/*.swift Sources/Diagnostics/*.swift Sources/App/*.swift \
  Tools/verify_binding_ui.swift
/tmp/verify
```

它不会去点界面，而是**走和用户点击完全一样的那条代码路径**
（`NSPopUpButton.select` → `NSApp.sendAction`），然后断言
`AppState.shared.bindings` 真的变了。

### 为什么需要它

`NSPopUpButton` **不支持子菜单**。v1.2.0 把 7 个「按住修饰键」选项放在
「模拟按住修饰键」子菜单里，结果：

- 点父项 → 选中父项 → 父项的 `representedObject` 是 `nil` →
  `actionChanged` 里 `guard let action = ... as? BindingAction else { return }`
  直接 return，**什么都没发生**
- 点子项 → AppKit 不更新 `selectedItem` → 同样什么都不发生

于是这 7 个选项全是死路。这个脚本就是防止它再退化：
它会断言每个下拉框里**没有任何子菜单**，且每个「按住修饰键」项都能真正写进绑定表。

## check_modifier_state.swift — 检查修饰键有没有卡住

```bash
swiftc -O Tools/check_modifier_state.swift -o /tmp/state && /tmp/state
```

正常输出 `flags=0 按下=无`。

如果显示 `按下=⌥` 之类且一直不消失，说明有程序注入的修饰键事件没有配上松开，
系统以为你的 Option 一直按着——此时所有键盘输入的字符都会变。可以给
Option/Command/Control/Shift 各补一个空的 `flagsChanged` 事件来复位。

排查过程中我自己踩过这个坑：测试脚本注入带 `maskAlternate` 的按键事件却
没发对应的松开事件，把系统状态搞成了「Option 一直按下」，导致后续所有
按键实验的数据都是错的（每个键都返回 ⌥ 变体字符）。

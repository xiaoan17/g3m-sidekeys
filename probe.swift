//
//  g3m-probe — 直接读取 G3M PRO 的原始 HID 输入, 诊断侧键上报形式
//  匹配 VID=0x320F (Telink) / PID=0x706B, 打印所有非零输入元素的
//  usagePage / usage / value。鼠标移动的 X/Y/滚轮会被过滤以免刷屏。
//

import Foundation
import IOKit.hid

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

let matching: [String: Int] = [
    kIOHIDVendorIDKey: 0x320F,
    kIOHIDProductIDKey: 0x706B,
]
IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

let callback: IOHIDValueCallback = { _, _, _, value in
    let element = IOHIDValueGetElement(value)
    let page = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    let v = IOHIDValueGetIntegerValue(value)
    // 过滤: 指针移动 X(0x30)/Y(0x31)/滚轮(0x38) 和 0 值
    if page == 0x01 && (usage == 0x30 || usage == 0x31 || usage == 0x38) { return }
    if v == 0 { return }
    let name = IOHIDElementGetName(element) as String
    print("page=0x\(String(format: "%02x", page)) usage=0x\(String(format: "%02x", usage)) value=\(v) \(name)")
    fflush(stdout)
}

IOHIDManagerRegisterInputValueCallback(manager, callback, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
let ret = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
guard ret == kIOReturnSuccess else {
    print("IOHIDManagerOpen 失败: \(ret)")
    exit(1)
}
print("probe 运行中 —— 请按侧键 / 左右键观察上报 (Ctrl+C 退出)")
fflush(stdout)
CFRunLoopRun()

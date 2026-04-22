import Cocoa

// 使用传统的 AppKit 入口点
let app = NSApplication.shared
// 设置为常规应用（不是 accessory/agent）
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

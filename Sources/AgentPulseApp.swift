import SwiftUI
import AppKit
import Combine

// 注释掉 SwiftUI App，改用 main.swift 入口
// @main
// struct AgentPulseApp: App {
//     @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
//
//     var body: some Scene {
//         Settings {
//             EmptyView()
//         }
//     }
// }

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var panelWindow: NSPanel!
    var islandWindow: NSPanel!
    var settingsWindow: NSWindow!
    var jsonlWatcher: JSONLWatcher?
    var codexWatcher: CodexWatcher?
    let socketServer = SocketServer(path: "/tmp/agent-pulse.sock")
    let settings = AppSettings.shared
    let islandState = IslandOverlayState()
    private var lastAttentionKey: String?
    private var cancellables: Set<AnyCancellable> = []
    private var settingsWindowObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 启动 Socket 服务器
        socketServer.start()

        // 创建状态栏图标
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "AgentPulse")
            button.action = #selector(togglePanel)
            button.target = self
        }

        // 创建浮动面板窗口
        panelWindow = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panelWindow.title = "AgentPulse"
        panelWindow.level = .floating
        panelWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panelWindow.isMovableByWindowBackground = true
        panelWindow.hidesOnDeactivate = false
        panelWindow.acceptsMouseMovedEvents = true
        panelWindow.ignoresMouseEvents = false
        panelWindow.appearance = NSAppearance(named: .darkAqua)

        let contentView = MonitorView(
            socketServer: socketServer,
            settings: settings,
            onOpenSettings: { [weak self] in self?.showSettings() }
        )
            .environmentObject(SessionMonitor.shared)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 480, height: 500)

        panelWindow.contentView = hostingView
        configureIslandWindow()
        configureSettingsWindow()
        bindIslandState()

        // 监听权限请求变化 + 刷新会话活跃状态
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshUIState()
        }

        // 定期刷新会话活跃状态（每5秒）
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            SessionMonitor.shared.refreshActiveStates()
        }

        // 定期自动清理过期会话（每分钟）
        Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { _ in
            SessionMonitor.shared.autoCleanup()
        }

        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.codexWatcher?.poll()
        }

        // 启动 JSONL 文件监听
        let logPath = NSHomeDirectory() + "/.claude/tool-flow-logs/calls.jsonl"
        jsonlWatcher = JSONLWatcher(path: logPath) { record in
            DispatchQueue.main.async {
                SessionMonitor.shared.handleRecord(record)
            }
        }
        jsonlWatcher?.start()

        codexWatcher = CodexWatcher(monitor: SessionMonitor.shared)
        codexWatcher?.start()

        NSLog("AgentPulse started")
    }

    @objc func togglePanel() {
        if panelWindow.isVisible {
            panelWindow.orderOut(nil)
        } else {
            // 定位到状态栏图标下方
            if let button = statusItem.button, let buttonWindow = button.window {
                let buttonRect = button.convert(button.bounds, to: nil)
                let screenRect = buttonWindow.convertToScreen(buttonRect)
                let x = screenRect.midX - panelWindow.frame.width / 2
                let y = screenRect.minY - panelWindow.frame.height - 5
                panelWindow.setFrameOrigin(NSPoint(x: x, y: y))
            }
            panelWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc func showSettings() {
        // 移除旧的监听器
        if let observer = settingsWindowObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        // 监听设置窗口关闭事件，恢复灵动岛
        settingsWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: settingsWindow,
            queue: .main
        ) { [weak self] _ in
            // 延迟一点恢复灵动岛，避免闪烁
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?.lastIslandExpanded = nil // 重置状态，强制重新计算
                self?.updateIslandPresentation()
            }
        }

        // 临时隐藏灵动岛避免遮挡
        islandWindow.orderOut(nil)

        // 定位到屏幕中央偏上的位置（更自然）
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowFrame = settingsWindow.frame
            let x = screenFrame.midX - windowFrame.width / 2
            let y = screenFrame.midY + screenFrame.height * 0.1 // 稍微偏上
            settingsWindow.setFrameOrigin(NSPoint(x: x, y: y))
        }

        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func updateStatusItemTitle() {
        let count = SessionMonitor.shared.activeCount + socketServer.pendingPermissions.count
        if let button = statusItem.button {
            if count > 0 {
                button.title = " \(count)"
            } else {
                button.title = ""
            }
        }
    }

    func refreshUIState() {
        updateStatusItemTitle()
        updateAttentionSurfaces()
        updateIslandPresentation()
    }

    func updateAttentionSurfaces() {
        let permCount = socketServer.pendingPermissions.count
        let askCount = socketServer.pendingQuestions.count
        let attentionKey = "\(permCount)-\(askCount)-\(socketServer.pendingPermissions.first?.id ?? "")-\(socketServer.pendingQuestions.first?.id ?? "")"

        if permCount > 0 || askCount > 0 {
            if lastAttentionKey != attentionKey {
                if let permission = socketServer.pendingPermissions.first {
                    islandState.showPermission(id: permission.id)
                } else if let question = socketServer.pendingQuestions.first {
                    islandState.showQuestion(id: question.id)
                }
            }

            if !settings.islandEnabled && !panelWindow.isVisible {
                panelWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }

            if settings.islandPlaySound && lastAttentionKey != attentionKey {
                NSSound.beep()
            }
        } else if !islandState.isHovered {
            islandState.showOverview(expanded: false)
        }

        lastAttentionKey = attentionKey
    }

    private func configureIslandWindow() {
        islandWindow = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 16),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        islandWindow.level = .statusBar
        islandWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        islandWindow.isOpaque = false
        islandWindow.backgroundColor = .clear
        islandWindow.hasShadow = false
        islandWindow.hidesOnDeactivate = false
        islandWindow.ignoresMouseEvents = false
        islandWindow.appearance = NSAppearance(named: .darkAqua)

        let islandView = IslandView(
            socketServer: socketServer,
            settings: settings,
            overlayState: islandState,
            onApprove: { [weak self] requestId in
                self?.socketServer.respondPermission(requestId: requestId, approved: true)
            },
            onDeny: { [weak self] requestId in
                self?.socketServer.respondPermission(requestId: requestId, approved: false)
            },
            onAnswer: { [weak self] requestId, answer in
                self?.socketServer.respondQuestion(requestId: requestId, answer: answer)
            },
            onJump: { sessionId, cwd in
                TerminalJumper.jump(to: sessionId, cwd: cwd)
            },
            onOpenPanel: { [weak self] in
                self?.panelWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            },
            onOpenSettings: { [weak self] in
                self?.showSettings()
            }
        )
        .environmentObject(SessionMonitor.shared)
        let hostingView = NSHostingView(rootView: islandView)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = islandWindow.contentView?.bounds ?? .zero
        islandWindow.contentView = hostingView
    }

    private func configureSettingsWindow() {
        settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 260),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = "AgentPulse 设置"
        settingsWindow.center()
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.appearance = NSAppearance(named: .darkAqua)

        // 确保关闭按钮可用
        settingsWindow.standardWindowButton(.closeButton)?.isEnabled = true

        let settingsView = SettingsView(settings: settings).preferredColorScheme(.dark)
        settingsWindow.contentView = NSHostingView(rootView: settingsView)
    }

    private func bindIslandState() {
        islandState.$isHovered
            .sink { [weak self] _ in
                self?.updateIslandPresentation()
            }
            .store(in: &cancellables)
    }

    private var lastIslandExpanded: Bool? = nil

    private func updateIslandPresentation() {
        guard settings.islandEnabled else {
            islandWindow.orderOut(nil)
            return
        }

        guard let screen = preferredScreen(), supportsIsland(on: screen) else {
            islandWindow.orderOut(nil)
            return
        }

        let hasAttention = !socketServer.pendingPermissions.isEmpty || !socketServer.pendingQuestions.isEmpty
        let shouldExpand = islandState.isHovered || islandState.isPinnedExpanded || hasAttention

        // 只在状态变化时调整窗口
        if lastIslandExpanded != shouldExpand {
            lastIslandExpanded = shouldExpand

            let size: NSSize
            let y: CGFloat

            if shouldExpand {
                size = NSSize(width: 520, height: 520)
                y = screen.frame.maxY - size.height - 4
            } else {
                size = NSSize(width: 180, height: 28)
                y = screen.frame.maxY - size.height
            }

            let x = screen.visibleFrame.midX - size.width / 2
            islandWindow.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true, animate: false)
        }

        islandWindow.orderFrontRegardless()
    }

    private func expandedIslandSize(hasAttention: Bool) -> NSSize {
        if hasAttention {
            return NSSize(width: 500, height: 260)
        }
        if islandState.selectedSessionId != nil {
            return NSSize(width: 500, height: 340)
        }
        return NSSize(width: 500, height: 300)
    }

    private func preferredScreen() -> NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }

    private func supportsIsland(on screen: NSScreen) -> Bool {
        if settings.islandShowOnNonNotchedDisplays {
            return true
        }
        return screen.safeAreaInsets.top > 0
    }
}

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
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupKeyboardShortcuts()
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

        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.codexWatcher?.poll()
        }

        // 连接会话中断事件到 SocketServer
        SessionMonitor.shared.onSessionStopped = { [weak self] sessionId in
            self?.socketServer.clearRequestsForSession(sessionId)
        }

        // 连接会话完成事件到灵动岛通知
        SessionMonitor.shared.onSessionCompleted = { [weak self] session, summary in
            guard let self = self, self.settings.notifyOnComplete else { return }
            let name = session.cwd.isEmpty ? String(session.id.prefix(8)) : (session.cwd as NSString).lastPathComponent
            let prompt = session.currentRequest?.prompt ?? ""
            self.islandState.showCompletion(sessionId: session.id, sessionName: name, prompt: prompt, summary: summary)
            if self.settings.islandPlaySound {
                NSSound(named: "Glass")?.play()
            }
        }

        // 连接会话中断事件到灵动岛通知
        SessionMonitor.shared.onSessionInterrupted = { [weak self] session, reason in
            guard let self = self, self.settings.notifyOnComplete else { return }
            let name = session.cwd.isEmpty ? String(session.id.prefix(8)) : (session.cwd as NSString).lastPathComponent
            let prompt = session.currentRequest?.prompt ?? ""
            self.islandState.showInterruption(sessionId: session.id, sessionName: name, prompt: prompt, reason: reason)
            if self.settings.islandPlaySound {
                NSSound(named: "Basso")?.play()  // 中断用不同的声音
            }
        }

        // 检查会话是否有待处理的权限/问题请求（等待审批不算中断）
        SessionMonitor.shared.hasPendingRequestForSession = { [weak self] sessionId in
            guard let self = self else { return false }
            let hasPermission = self.socketServer.pendingPermissions.contains { $0.sessionId == sessionId }
            let hasQuestion = self.socketServer.pendingQuestions.contains { $0.sessionId == sessionId }
            return hasPermission || hasQuestion
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

        // 启动 Token 使用统计服务
        TokenUsageService.shared.start()

        // 恢复持久化的会话
        SessionMonitor.shared.restoreFromPersistence()

        // 定期自动保存会话（每30秒）
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
            SessionMonitor.shared.saveToPersistence()
        }

        NSLog("AgentPulse started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出时保存会话
        SessionMonitor.shared.saveToPersistence()
        NSLog("AgentPulse 会话已保存")
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
                self?.lastIslandMode = nil // 重置状态，强制重新计算
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

        // 只在有新的审批/问题时自动展开一次
        if permCount > 0 || askCount > 0 {
            if lastAttentionKey != attentionKey && settings.islandAutoExpand {
                // 新的审批/问题，自动展开
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
        }
        // 移除强制收起逻辑，让用户控制

        lastAttentionKey = attentionKey
    }

    private func configureIslandWindow() {
        islandWindow = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 50),
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
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 540),
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

        islandState.$completionNotification
            .sink { [weak self] _ in
                self?.lastIslandMode = nil  // 强制重新计算
                self?.updateIslandPresentation()
            }
            .store(in: &cancellables)
    }

    private var lastIslandMode: String? = nil

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
        let hasNotification = islandState.completionNotification != nil
        let shouldExpand = islandState.isHovered || islandState.isPinnedExpanded || hasAttention

        // 计算当前模式
        let currentMode: String
        if hasNotification {
            currentMode = "notification"
        } else if shouldExpand {
            currentMode = "expanded"
        } else {
            currentMode = "collapsed"
        }

        // 只在模式变化时调整窗口
        if lastIslandMode != currentMode {
            let previousMode = lastIslandMode
            lastIslandMode = currentMode

            let size: NSSize
            let y: CGFloat

            switch currentMode {
            case "notification":
                // 通知气泡：显示用户问题和AI总结
                size = NSSize(width: 440, height: 180)
                y = screen.frame.maxY - size.height - 4
            case "expanded":
                // 动态高度：最小400，最大屏幕高度的70%
                let maxHeight = min(screen.visibleFrame.height * 0.7, 700)
                size = NSSize(width: 580, height: maxHeight)
                y = screen.frame.maxY - size.height - 4
            default:
                size = NSSize(width: 280, height: 50)
                y = screen.frame.maxY - size.height
            }

            let x = screen.visibleFrame.midX - size.width / 2
            let newFrame = NSRect(origin: NSPoint(x: x, y: y), size: size)

            // 使用 NSAnimationContext 实现平滑窗口动画
            let shouldAnimate = previousMode != nil  // 首次显示不动画

            // 收起时稍微延迟窗口动画，让内容先开始淡出
            let isCollapsing = currentMode == "collapsed" && previousMode != nil
            let delay: TimeInterval = isCollapsing ? 0.08 : 0

            if shouldAnimate {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let islandWindow = self?.islandWindow else { return }
                    NSAnimationContext.runAnimationGroup { context in
                        // 与 SwiftUI spring 动画同步
                        context.duration = isCollapsing ? 0.28 : 0.35
                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        islandWindow.animator().setFrame(newFrame, display: true)
                    }
                }
            } else {
                islandWindow.setFrame(newFrame, display: true, animate: false)
            }
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

    // MARK: - Keyboard Shortcuts

    private func setupKeyboardShortcuts() {
        // 本地快捷键（应用激活时）
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleKeyEvent(event) == true {
                return nil  // 消费事件
            }
            return event
        }

        // 全局快捷键（应用未激活时）
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }
    }

    @discardableResult
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // ⌘B: 批量批准所有权限
        if flags == .command && event.keyCode == 11 { // B
            approveAllPermissions()
            return true
        }

        // ⌘⇧B: 批量拒绝所有权限
        if flags == [.command, .shift] && event.keyCode == 11 { // B
            denyAllPermissions()
            return true
        }

        // ⌘K: 清理非活跃会话
        if flags == .command && event.keyCode == 40 { // K
            SessionMonitor.shared.clearInactiveSessions()
            return true
        }

        // ⌘⇧A: 切换灵动岛显示
        if flags == [.command, .shift] && event.keyCode == 0 { // A
            settings.islandEnabled.toggle()
            return true
        }

        return false
    }

    private func approveAllPermissions() {
        let permissions = socketServer.pendingPermissions
        for permission in permissions {
            socketServer.respondPermission(requestId: permission.id, approved: true)
        }
        if !permissions.isEmpty {
            NSLog("⌘B: 批量批准 \(permissions.count) 个权限请求")
        }
    }

    private func denyAllPermissions() {
        let permissions = socketServer.pendingPermissions
        for permission in permissions {
            socketServer.respondPermission(requestId: permission.id, approved: false)
        }
        if !permissions.isEmpty {
            NSLog("⌘⇧B: 批量拒绝 \(permissions.count) 个权限请求")
        }
    }
}

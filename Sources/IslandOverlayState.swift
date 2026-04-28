import Foundation

/// 会话完成通知
struct CompletionNotification: Identifiable {
    let id = UUID()
    let sessionId: String
    let sessionName: String
    let prompt: String      // 用户问题
    let summary: String     // AI 总结
    let timestamp: Date
}

final class IslandOverlayState: ObservableObject {
    @Published var isHovered: Bool = false
    @Published var isPinnedExpanded: Bool = false
    @Published var selectedSessionId: String?
    @Published var focusedPermissionId: String?
    @Published var focusedQuestionId: String?
    @Published var completionNotification: CompletionNotification?

    // 通知队列
    @Published var notificationQueue: [CompletionNotification] = []
    @Published var notificationHistory: [CompletionNotification] = []
    private let maxHistory = 20

    private var notificationTimer: Timer?

    func showOverview(expanded: Bool = true) {
        selectedSessionId = nil
        focusedPermissionId = nil
        focusedQuestionId = nil
        isPinnedExpanded = expanded
    }

    func showSession(id: String) {
        selectedSessionId = id
        focusedPermissionId = nil
        focusedQuestionId = nil
        isPinnedExpanded = true
    }

    func showPermission(id: String) {
        focusedPermissionId = id
        focusedQuestionId = nil
        selectedSessionId = nil
        isPinnedExpanded = true
    }

    func showQuestion(id: String) {
        focusedQuestionId = id
        focusedPermissionId = nil
        selectedSessionId = nil
        isPinnedExpanded = true
    }

    func showCompletion(sessionId: String, sessionName: String, prompt: String, summary: String) {
        let notification = CompletionNotification(
            sessionId: sessionId,
            sessionName: sessionName,
            prompt: prompt,
            summary: summary,
            timestamp: Date()
        )

        // 添加到历史记录
        notificationHistory.insert(notification, at: 0)
        if notificationHistory.count > maxHistory {
            notificationHistory.removeLast()
        }

        // 如果当前没有显示通知，直接显示
        if completionNotification == nil {
            showNextNotification(notification)
        } else {
            // 否则添加到队列
            notificationQueue.append(notification)
        }
    }

    private func showNextNotification(_ notification: CompletionNotification) {
        notificationTimer?.invalidate()
        completionNotification = notification
        isPinnedExpanded = true

        // 5秒后自动切换到下一个或隐藏
        notificationTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            self?.dismissCompletion()
        }
    }

    func dismissCompletion() {
        notificationTimer?.invalidate()
        notificationTimer = nil
        completionNotification = nil

        // 显示队列中的下一个通知
        if !notificationQueue.isEmpty {
            let next = notificationQueue.removeFirst()
            showNextNotification(next)
        } else if !isHovered {
            isPinnedExpanded = false
        }
    }

    var pendingNotificationCount: Int {
        notificationQueue.count
    }

    func collapse() {
        isPinnedExpanded = false
        selectedSessionId = nil
        focusedPermissionId = nil
        focusedQuestionId = nil
        completionNotification = nil
        notificationTimer?.invalidate()
    }
}

import Foundation

/// 通知类型
enum NotificationType {
    case completion  // 会话完成
    case interrupted // 会话被中断
}

/// 会话通知
struct CompletionNotification: Identifiable {
    let id = UUID()
    let sessionId: String
    let sessionName: String
    let prompt: String      // 用户问题
    let summary: String     // AI 总结 / 中断原因
    let timestamp: Date
    var type: NotificationType = .completion
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
    private let notificationDedupeWindow: TimeInterval = 60
    private var recentNotificationKeys: [String: Date] = [:]

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
        showNotification(sessionId: sessionId, sessionName: sessionName, prompt: prompt, summary: summary, type: .completion)
    }

    func showInterruption(sessionId: String, sessionName: String, prompt: String, reason: String) {
        showNotification(sessionId: sessionId, sessionName: sessionName, prompt: prompt, summary: reason, type: .interrupted)
    }

    private func showNotification(sessionId: String, sessionName: String, prompt: String, summary: String, type: NotificationType) {
        let now = Date()
        cleanupRecentNotifications(before: now.addingTimeInterval(-notificationDedupeWindow))
        let notificationKey = completionKey(sessionId: sessionId, prompt: prompt, summary: summary)
        guard recentNotificationKeys[notificationKey] == nil else { return }
        recentNotificationKeys[notificationKey] = now

        var notification = CompletionNotification(
            sessionId: sessionId,
            sessionName: sessionName,
            prompt: prompt,
            summary: summary,
            timestamp: now
        )
        notification.type = type

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

        scheduleNotificationDismiss()
    }

    func setNotificationHovered(_ hovering: Bool) {
        isHovered = hovering

        if hovering {
            notificationTimer?.invalidate()
            notificationTimer = nil
            return
        }

        if completionNotification != nil {
            scheduleNotificationDismiss()
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

    private func scheduleNotificationDismiss() {
        notificationTimer?.invalidate()
        let timer = Timer(timeInterval: 5.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.dismissCompletion()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        notificationTimer = timer
    }

    private func completionKey(sessionId: String, prompt: String, summary: String) -> String {
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(sessionId)|\(normalizedPrompt)|\(normalizedSummary)"
    }

    private func cleanupRecentNotifications(before cutoff: Date) {
        recentNotificationKeys = recentNotificationKeys.filter { $0.value >= cutoff }
    }
}

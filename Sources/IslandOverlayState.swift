import Foundation

/// 会话完成通知
struct CompletionNotification: Identifiable {
    let id = UUID()
    let sessionId: String
    let sessionName: String
    let summary: String
    let timestamp: Date
}

final class IslandOverlayState: ObservableObject {
    @Published var isHovered: Bool = false
    @Published var isPinnedExpanded: Bool = false
    @Published var selectedSessionId: String?
    @Published var focusedPermissionId: String?
    @Published var focusedQuestionId: String?
    @Published var completionNotification: CompletionNotification?

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

    func showCompletion(sessionId: String, sessionName: String, summary: String) {
        // 取消之前的定时器
        notificationTimer?.invalidate()

        completionNotification = CompletionNotification(
            sessionId: sessionId,
            sessionName: sessionName,
            summary: summary,
            timestamp: Date()
        )
        isPinnedExpanded = true

        // 5秒后自动隐藏通知
        notificationTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            self?.dismissCompletion()
        }
    }

    func dismissCompletion() {
        notificationTimer?.invalidate()
        notificationTimer = nil
        completionNotification = nil
        if !isHovered {
            isPinnedExpanded = false
        }
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

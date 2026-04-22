import Foundation

final class IslandOverlayState: ObservableObject {
    @Published var isHovered: Bool = false
    @Published var isPinnedExpanded: Bool = false
    @Published var selectedSessionId: String?
    @Published var focusedPermissionId: String?
    @Published var focusedQuestionId: String?

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

    func collapse() {
        isPinnedExpanded = false
        selectedSessionId = nil
        focusedPermissionId = nil
        focusedQuestionId = nil
    }
}

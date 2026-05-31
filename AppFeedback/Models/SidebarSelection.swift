import Foundation

enum SidebarSelection: Hashable, Sendable {
    case allIssues(repoId: UUID)

    var repoId: UUID {
        switch self {
        case .allIssues(let id): return id
        }
    }
}

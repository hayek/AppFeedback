import Foundation

enum SidebarSelection: Hashable, Sendable {
    case allIssues(repoId: UUID)
    case app(repoId: UUID, appName: String)

    var repoId: UUID {
        switch self {
        case .allIssues(let id): return id
        case .app(let id, _):   return id
        }
    }
}

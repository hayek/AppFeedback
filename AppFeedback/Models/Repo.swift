import Foundation
import SwiftData

@Model
final class Repo {
    var id: UUID = UUID()
    var displayName: String = ""
    var owner: String = ""
    var repo: String = ""
    var hiddenAppNames: [String] = []
    var appColors: [String: String] = [:]
    var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        displayName: String,
        owner: String,
        repo: String,
        hiddenAppNames: [String] = [],
        appColors: [String: String] = [:],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.owner = owner
        self.repo = repo
        self.hiddenAppNames = hiddenAppNames
        self.appColors = appColors
        self.createdAt = createdAt
    }
}

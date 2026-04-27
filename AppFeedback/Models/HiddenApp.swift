import Foundation
import SwiftData

@Model
final class HiddenApp {
    var repoOwner: String = ""
    var repoName: String = ""
    var appName: String = ""
    var hiddenAt: Date = Date()

    init(repoOwner: String, repoName: String, appName: String, hiddenAt: Date = Date()) {
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.appName = appName
        self.hiddenAt = hiddenAt
    }
}

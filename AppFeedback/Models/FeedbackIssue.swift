import Foundation

struct FeedbackIssue: Identifiable, Codable, Sendable {
    let number: Int
    let title: String
    let createdAt: Date
    let rawBody: String
    let appName: String?
    let appVersion: String?
    let device: String?
    let osVersion: String?
    let email: String?
    let description: String

    var id: Int { number }
}

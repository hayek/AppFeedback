#if os(macOS)
import Foundation

// MARK: - Products

struct VersionSummary: Codable, Equatable {
    let name: String
    let milestoneNumber: Int?
    let released: Bool
}

struct SourceFlags: Codable, Equatable {
    let sdk: Bool
    let appStore: Bool
    let email: Bool
}

struct ProductSummary: Codable, Equatable {
    let id: String
    let displayName: String
    let repo: String
    let connectedRepo: String?
    let versions: [VersionSummary]
    let sources: SourceFlags
    let feedbackCount: Int
    let taskCount: Int
    let lastFetchedAt: Date?
}

/// Compact product identity echoed in every envelope.
struct ProductRef: Codable, Equatable {
    let id: String
    let displayName: String
    let repo: String
}

// MARK: - Envelope

struct PageInfo: Codable, Equatable {
    let limit: Int
    let offset: Int
    let total: Int
    let hasMore: Bool
}

/// Every successful response. `items` is generic so one envelope serves every command.
/// Defaults on every optional so call sites pass only what they have — nil optionals are
/// omitted from the JSON rather than encoded as null.
struct CLIEnvelope<Item: Codable>: Codable {
    var asOf: Date? = nil
    var stale: Bool = false
    var refreshTimedOut: Bool? = nil
    var closedDataIncomplete: Bool? = nil
    var product: ProductRef? = nil
    var filters: [String: String]? = nil
    var page: PageInfo? = nil
    var warnings: [String]? = nil
    var items: [Item]
}

// MARK: - Feedback

struct TaskRef: Codable, Equatable {
    let number: Int
    let title: String
    let status: String
    let priority: String
    let isClosed: Bool
}

struct TriageInfo: Codable, Equatable {
    let state: String
    let kind: String?
    let signal: String?
    let suggestedTaskNumber: Int?
    let createdTaskNumber: Int?
}

struct FeedbackItem: Codable, Equatable {
    let number: Int
    let title: String
    let app: String?
    let appVersion: String?
    let source: String
    let type: String?
    let rating: Int?
    let state: String
    let createdAt: Date
    let updatedAt: Date
    let device: String?
    let os: String?
    let email: String?
    let description: String
    let truncated: Bool
    let labels: [String]
    let tasks: [TaskRef]
    let triage: TriageInfo?
    let url: String
}

struct AttachmentDTO: Codable, Equatable {
    let filename: String
    let mimeType: String
    let url: String
    let localPath: String?
}

struct ThreadSummary: Codable, Equatable {
    let messageCount: Int
    let lastMessageAt: Date?
    let lastDirection: String?      // "inbound" | "outbound"
}

struct FeedbackDetail: Codable, Equatable {
    let number: Int
    let title: String
    let app: String?
    let appVersion: String?
    let source: String
    let type: String?
    let rating: Int?
    let state: String
    let createdAt: Date
    let updatedAt: Date
    let device: String?
    let os: String?
    let email: String?
    let description: String
    let rawBody: String?
    let labels: [String]
    let milestone: String?
    let attachments: [AttachmentDTO]
    let translatedTitle: String?
    let translatedBody: String?
    let thread: ThreadSummary?
    let tasks: [TaskRef]
    let triage: TriageInfo?
    let url: String
}

// MARK: - Tasks

struct TaskItemDTO: Codable, Equatable {
    let number: Int
    let title: String
    let status: String
    let priority: String
    let isClosed: Bool
    let milestone: String?
    let feedback: [Int]
    let url: String
}

struct LinkedFeedback: Codable, Equatable {
    let number: Int
    let title: String
    let state: String
}

struct TaskDetail: Codable, Equatable {
    let number: Int
    let title: String
    let status: String
    let priority: String
    let isClosed: Bool
    let milestone: String?
    let notes: String
    let feedback: [LinkedFeedback]
    let url: String
}
#endif

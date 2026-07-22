import Foundation
@testable import AppFeedback

@MainActor
final class MockTriageApplier: TriageTaskApplying {
    private(set) var assigns: [(feedback: Int, task: Int)] = []
    private(set) var creates: [(title: String, summary: String, feedback: Int)] = []
    var errorToThrow: Error?
    var assignErrorToThrow: Error?
    var nextCreatedNumber = 900

    func assign(feedbackNumber: Int, to task: TaskItem, in repo: ProductConfig) async throws {
        if let assignErrorToThrow { throw assignErrorToThrow }
        if let errorToThrow { throw errorToThrow }
        assigns.append((feedbackNumber, task.number))
    }

    func createTask(in repo: ProductConfig, title: String, summary: String,
                    feedbackNumber: Int) async throws -> Int {
        if let errorToThrow { throw errorToThrow }
        creates.append((title, summary, feedbackNumber))
        nextCreatedNumber += 1
        return nextCreatedNumber
    }
}

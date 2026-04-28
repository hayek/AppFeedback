import Foundation
import UserNotifications
@testable import AppFeedback

final class MockUserNotificationCenter: UserNotificationCenterProtocol {
    var addedRequests: [UNNotificationRequest] = []
    var authorizationGranted: Bool = true
    var requestedOptions: UNAuthorizationOptions?

    func add(_ request: UNNotificationRequest) async throws {
        addedRequests.append(request)
    }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestedOptions = options
        return authorizationGranted
    }
    func notificationSettings() async -> UNNotificationSettings {
        // Not used by current tests; would need a stub via NSCoder if needed later.
        fatalError("not implemented for tests that need it")
    }
}

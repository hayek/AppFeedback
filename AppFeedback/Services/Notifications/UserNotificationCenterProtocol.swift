import Foundation
import UserNotifications

protocol UserNotificationCenterProtocol: AnyObject {
    func add(_ request: UNNotificationRequest) async throws
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func notificationSettings() async -> UNNotificationSettings
}

extension UNUserNotificationCenter: UserNotificationCenterProtocol {}

import SwiftUI
import UserNotifications
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct NotificationsSettingsView: View {
    @Bindable var settings: NotificationSettings
    let service: NotificationService
    @State private var systemDenied: Bool = false

    var body: some View {
        Form {
            Section {
                Toggle("Notify me about new feedback", isOn: $settings.isEnabled)
                    .onChange(of: settings.isEnabled) { _, newValue in
                        if newValue {
                            Task { await ensureAuthorization() }
                        }
                    }
                if settings.isEnabled && systemDenied {
                    Text("Notifications are disabled in system settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open System Settings") { openSystemSettings() }
                }
            } footer: {
                Text("Checks for new GitHub issues in the background and posts a local notification when new ones arrive.")
            }
        }
        .task { await refreshSystemStatus() }
    }

    private func ensureAuthorization() async {
        await service.requestAuthorizationIfNeeded()
        await refreshSystemStatus()
    }

    private func refreshSystemStatus() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        systemDenied = (status == .denied)
    }

    private func openSystemSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #elseif canImport(AppKit)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}

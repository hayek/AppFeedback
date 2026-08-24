// AppFeedbackTests/ComposeFormCoreSmokeTests.swift
import XCTest
import SwiftUI
import SwiftData
@testable import AppFeedback

#if canImport(SwiftMail)
import SwiftMail

/// The compose form's attachment control is platform-forked: a Files-only button on macOS,
/// a Photo Library / Files menu plus a `.photosPicker` on iOS. This forces the view builder
/// to evaluate so the fork can't rot on the platform we aren't currently building.
/// Compile + render only — ingestion behavior lives in `ComposeMailViewModelTests`.
final class ComposeFormCoreSmokeTests: XCTestCase {

    @MainActor
    func test_composeForm_rendersWithAttachmentControl() throws {
        let accountConfig = ModelConfiguration(isStoredInMemoryOnly: true)
        let accountContainer = try ModelContainer(for: MailAccount.self, configurations: accountConfig)
        let store = MailAccountStore(context: ModelContext(accountContainer))
        let account = store.add { acc in
            acc.presetRaw = SMTPCredentials.Preset.gmail.rawValue
            acc.smtpHost = "smtp.gmail.com"
            acc.smtpPort = 587
            acc.smtpUsername = "alice@gmail.com"
            acc.senderName = "Alice"
        }
        let settingsConfig = ModelConfiguration(isStoredInMemoryOnly: true)
        let settingsContainer = try ModelContainer(for: MailSettings.self, configurations: settingsConfig)

        let vm = ComposeMailViewModel(
            recipient: "bob@example.com",
            issue: FeedbackIssue(
                number: 7, title: "Crash", createdAt: Date(),
                rawBody: "", appName: "MyApp", appVersion: "1.0",
                device: "iPhone", osVersion: "18.6", email: "bob@example.com",
                description: "Crash on launch", labels: []
            ),
            repoOwner: "o", repoName: "r",
            store: store,
            settingsStore: MailSettingsStore(context: ModelContext(settingsContainer)),
            sender: NoopSender(),
            activityLog: ActivityLog(persistenceURL: nil),
            senderAccountID: account.id,
            passwordLoader: { _ in nil }
        )

        let form = ComposeFormCore(vm: vm, headerPreview: "", footerPreview: "", onSend: {})
            .environment(store)
            .environment(SettingsNavigation())

        #if os(macOS)
        let host = NSHostingView(rootView: form)
        host.layout()
        XCTAssertNotNil(host)
        #else
        let host = UIHostingController(rootView: form)
        host.loadViewIfNeeded()
        host.view.layoutIfNeeded()
        XCTAssertNotNil(host.view)
        #endif
    }

    private actor NoopSender: MailSending {
        func send(_ email: SwiftMail.Email, using credentials: SMTPCredentials, password: String) async throws {}
        func testConnection(_ credentials: SMTPCredentials, password: String) async throws {}
    }
}
#endif

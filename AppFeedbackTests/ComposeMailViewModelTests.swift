import XCTest
import SwiftData
import ImageIO
import UniformTypeIdentifiers
@testable import AppFeedback

#if canImport(SwiftMail)
import SwiftMail

@MainActor
final class ComposeMailViewModelTests: XCTestCase {

    actor FakeSender: MailSending {
        var sent: [(SwiftMail.Email, SMTPCredentials, String)] = []
        var shouldThrow: Error?

        func send(_ email: SwiftMail.Email, using credentials: SMTPCredentials, password: String) async throws {
            if let shouldThrow { throw shouldThrow }
            sent.append((email, credentials, password))
        }
        func testConnection(_ credentials: SMTPCredentials, password: String) async throws {}
        func setShouldThrow(_ error: Error?) { shouldThrow = error }
        func snapshot() -> [(SwiftMail.Email, SMTPCredentials, String)] { sent }
    }

    private func makeSettingsStore() throws -> MailSettingsStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: MailSettings.self, configurations: config)
        return MailSettingsStore(context: ModelContext(container))
    }

    private func makeStore(configured: Bool = true, preset: SMTPCredentials.Preset = .gmail) throws -> MailAccountStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: MailAccount.self, configurations: config)
        let store = MailAccountStore(context: ModelContext(container))
        if configured {
            _ = store.add { acc in
                acc.presetRaw = preset.rawValue
                acc.smtpHost = "smtp.gmail.com"
                acc.smtpPort = 587
                acc.smtpUsername = "alice@gmail.com"
                acc.senderName = "Alice"
            }
        }
        return store
    }

    /// Records how many times the injected Sent-appender was invoked.
    actor AppendRecorder {
        private(set) var count = 0
        func record() { count += 1 }
    }

    private func makeIssue() -> FeedbackIssue {
        FeedbackIssue(
            number: 7, title: "Crash", createdAt: Date(),
            rawBody: "", appName: "MyApp", appVersion: "1.0",
            device: "Mac", osVersion: "14.0", email: "bob@example.com",
            description: "Crash on launch", labels: []
        )
    }

    func test_send_callsSenderAndLogsSuccess() async throws {
        let store = try makeStore()
        let acc = store.defaultSender
        XCTAssertNotNil(acc)
        let sender = FakeSender()
        let log = ActivityLog(persistenceURL: nil)
        let vm = ComposeMailViewModel(
            recipient: "bob@example.com",
            issue: makeIssue(),
            repoOwner: "o", repoName: "r",
            store: store,
            settingsStore: try makeSettingsStore(),
            sender: sender,
            activityLog: log,
            senderAccountID: acc!.id,
            passwordLoader: { _ in "test-secret" }
        )
        vm.subject = "Hello"
        vm.body = NSAttributedString(string: "Hi Bob")

        await vm.send()

        let sent = await sender.snapshot()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].0.recipients.first?.address, "bob@example.com")
        XCTAssertEqual(sent[0].0.subject, "Hello")
        XCTAssertEqual(sent[0].2, "test-secret")
        XCTAssertNotNil(sent[0].0.messageID, "outbound mail must have a stamped Message-ID")
        XCTAssertEqual(log.entries.first?.status, .success)
    }

    // MARK: - Save-to-Sent (IMAP APPEND)

    func test_autosavesSentMail_perPreset() {
        XCTAssertTrue(SMTPCredentials.Preset.gmail.autosavesSentMail)
        XCTAssertTrue(SMTPCredentials.Preset.outlook.autosavesSentMail)
        XCTAssertFalse(SMTPCredentials.Preset.icloud.autosavesSentMail)
        XCTAssertFalse(SMTPCredentials.Preset.custom.autosavesSentMail)
    }

    func test_send_appendsToSent_forICloud() async throws {
        let store = try makeStore(preset: .icloud)
        let acc = try XCTUnwrap(store.defaultSender)
        let recorder = AppendRecorder()
        let vm = ComposeMailViewModel(
            recipient: "bob@example.com", issue: makeIssue(),
            repoOwner: "o", repoName: "r",
            store: store, settingsStore: try makeSettingsStore(),
            sender: FakeSender(), activityLog: ActivityLog(persistenceURL: nil),
            senderAccountID: acc.id,
            passwordLoader: { _ in "secret" },
            sentAppender: { @Sendable _ in await recorder.record() }
        )
        vm.subject = "Hi"; vm.body = NSAttributedString(string: "Body")

        await vm.send()

        let count = await recorder.count
        XCTAssertEqual(count, 1, "iCloud (no server auto-save) should append a copy to the Sent folder")
    }

    func test_send_skipsAppendToSent_forGmail() async throws {
        let store = try makeStore(preset: .gmail)
        let acc = try XCTUnwrap(store.defaultSender)
        let recorder = AppendRecorder()
        let vm = ComposeMailViewModel(
            recipient: "bob@example.com", issue: makeIssue(),
            repoOwner: "o", repoName: "r",
            store: store, settingsStore: try makeSettingsStore(),
            sender: FakeSender(), activityLog: ActivityLog(persistenceURL: nil),
            senderAccountID: acc.id,
            passwordLoader: { _ in "secret" },
            sentAppender: { @Sendable _ in await recorder.record() }
        )
        vm.subject = "Hi"; vm.body = NSAttributedString(string: "Body")

        await vm.send()

        let count = await recorder.count
        XCTAssertEqual(count, 0, "Gmail auto-saves SMTP sends, so the app must not append (would duplicate)")
    }

    func test_send_failureLogsFailureWithDetail() async throws {
        let store = try makeStore()
        let acc = store.defaultSender
        XCTAssertNotNil(acc)
        let sender = FakeSender()
        await sender.setShouldThrow(NSError(domain: "Test", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "boom"]))
        let log = ActivityLog(persistenceURL: nil)
        let vm = ComposeMailViewModel(
            recipient: "bob@example.com",
            issue: makeIssue(),
            repoOwner: "o", repoName: "r",
            store: store,
            settingsStore: try makeSettingsStore(),
            sender: sender,
            activityLog: log,
            senderAccountID: acc!.id,
            passwordLoader: { _ in "test-secret" }
        )
        vm.subject = "x"
        vm.body = NSAttributedString(string: "x")

        await vm.send()

        XCTAssertEqual(log.entries.first?.status, .failure)
        XCTAssertEqual(log.entries.first?.detail, "boom")
    }

    func test_send_withoutCredentials_doesNothing() async throws {
        let sender = FakeSender()
        let log = ActivityLog(persistenceURL: nil)
        let vm = ComposeMailViewModel(
            recipient: "bob@example.com",
            issue: makeIssue(),
            repoOwner: "o", repoName: "r",
            store: try makeStore(configured: false),
            settingsStore: try makeSettingsStore(),
            sender: sender,
            activityLog: log,
            senderAccountID: UUID(),
            passwordLoader: { _ in "test-secret" }
        )
        vm.subject = "x"
        vm.body = NSAttributedString(string: "x")

        await vm.send()

        let sent = await sender.snapshot()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(log.entries.isEmpty)
    }

    func test_send_withoutKeychainPassword_logsFailure() async throws {
        let store = try makeStore()
        let acc = store.defaultSender
        XCTAssertNotNil(acc)
        let sender = FakeSender()
        let log = ActivityLog(persistenceURL: nil)
        let vm = ComposeMailViewModel(
            recipient: "bob@example.com",
            issue: makeIssue(),
            repoOwner: "o", repoName: "r",
            store: store,
            settingsStore: try makeSettingsStore(),
            sender: sender,
            activityLog: log,
            senderAccountID: acc!.id,
            passwordLoader: { _ in nil }
        )
        vm.subject = "x"
        vm.body = NSAttributedString(string: "x")

        await vm.send()

        let sent = await sender.snapshot()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(log.entries.first?.status, .failure)
        XCTAssertEqual(log.entries.first?.detail, "No SMTP password configured.")
    }

    func test_send_withInReplyTo_writesReplyHeaders() async throws {
        let store = try makeStore()
        let acc = store.defaultSender
        XCTAssertNotNil(acc)
        let sender = FakeSender()
        let log = ActivityLog(persistenceURL: nil)
        let parent = MailMessageHeaders(
            messageID: "<parent@x>",
            inReplyTo: nil,
            references: ["<root@x>"]
        )
        let vm = ComposeMailViewModel(
            recipient: "bob@example.com",
            issue: makeIssue(),
            repoOwner: "o", repoName: "r",
            store: store,
            settingsStore: try makeSettingsStore(),
            sender: sender,
            activityLog: log,
            inReplyTo: parent,
            senderAccountID: acc!.id,
            passwordLoader: { _ in "pw" }
        )
        vm.subject = "Re: Crash"
        vm.body = NSAttributedString(string: "ack")

        await vm.send()

        let sent = await sender.snapshot()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].0.additionalHeaders?["In-Reply-To"], "<parent@x>")
        XCTAssertEqual(sent[0].0.additionalHeaders?["References"], "<root@x> <parent@x>")
    }

    func test_sendUsesCredentialsAndPasswordForRequestedAccount() async throws {
        let store = try makeStore(configured: false)
        let a = store.add { acc in
            acc.smtpUsername = "alice@x"
            acc.senderName = "Alice"
            acc.smtpHost = "smtp.x"
            acc.smtpPort = 587
        }
        let b = store.add { acc in
            acc.smtpUsername = "bob@x"
            acc.senderName = "Bob"
            acc.smtpHost = "smtp.x"
            acc.smtpPort = 587
        }

        let sender = FakeSender()
        let log = ActivityLog(persistenceURL: nil)

        let vm = ComposeMailViewModel(
            recipient: "user@example.com",
            issue: makeIssue(),
            repoOwner: "o", repoName: "r",
            store: store,
            settingsStore: try makeSettingsStore(),
            sender: sender,
            activityLog: log,
            senderAccountID: b.id,
            passwordLoader: { @Sendable id in
                XCTAssertEqual(id, b.id)
                return "bob-password"
            }
        )
        vm.subject = "Test"
        vm.body = NSAttributedString(string: "hello")
        await vm.send()

        let sent = await sender.snapshot()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].1.username, "bob@x")
        XCTAssertEqual(sent[0].2, "bob-password")
        _ = a
    }

    // MARK: - Failure text

    /// The badge and the Activity log show `localizedDescription`, so the wrapper has to carry the
    /// whole story — NIO's bridged text ("NIOCore.ChannelError error 0") names nothing.
    func test_transportError_namesServerStageAndCause() {
        let nio = SMTPTransportError(
            host: "smtp.mail.me.com", port: 587, stage: .connect,
            underlying: SMTPError.connectionFailed("refused")
        )
        XCTAssertEqual(nio.localizedDescription,
                       "Couldn't connect to smtp.mail.me.com:587 — SMTP connection failed: refused")

        struct Bare: Error, CustomStringConvertible { var description: String { "connectTimeout" } }
        let bare = SMTPTransportError(host: "smtp.x", port: 465, stage: .login, underlying: Bare())
        XCTAssertEqual(bare.localizedDescription, "Couldn't sign in to smtp.x:465 — connectTimeout")
    }

    // MARK: - Retry (resend of a failed message)

    private func makeThreadContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: MailThread.self, MailMessage.self, MailAttachment.self,
                MailAttachmentLocal.self, MailAccountLocalState.self,
            configurations: config
        )
        return ModelContext(container)
    }

    /// The retry path the "Failed" badge menu drives: same Message-Id, same row, failure cleared.
    func test_resend_reusesMessageIDAndClearsFailure() async throws {
        let accounts = try makeStore()
        let acc = try XCTUnwrap(accounts.defaultSender)
        let ctx = try makeThreadContext()
        let threadStore = MailThreadStore(context: ctx)
        let tracker = OutboundSendTracker()
        let failures = OutboundFailureStore(persistenceURL: nil)
        let sender = FakeSender()
        await sender.setShouldThrow(NSError(domain: "Test", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "smtp down"]))

        func makeVM(subject: String, body: String) throws -> ComposeMailViewModel {
            let vm = ComposeMailViewModel(
                recipient: "bob@example.com", issue: makeIssue(),
                repoOwner: "o", repoName: "r",
                store: accounts, settingsStore: try makeSettingsStore(),
                threadStore: threadStore, tracker: tracker, failureStore: failures,
                sender: sender, activityLog: ActivityLog(persistenceURL: nil),
                initialSubject: subject,
                senderAccountID: acc.id,
                passwordLoader: { _ in "pw" }
            )
            vm.subject = subject
            vm.body = NSAttributedString(string: body)
            return vm
        }

        let first = try makeVM(subject: "Re: Crash", body: "Thanks for the update.")
        let firstOK = await first.send()
        XCTAssertFalse(firstOK, "the first attempt fails at the SMTP hop")

        let recorded = try XCTUnwrap(threadStore.threads(forIssue: (owner: "o", repo: "r", number: 7,
                                                                   title: "Crash"))
            .flatMap(\.sortedDedupedMessages).first)
        let originalID = recorded.messageID
        XCTAssertEqual(failures.reason(for: originalID), "smtp down")
        XCTAssertNil(recorded.sentAt)

        // Retry: same message, this time the SMTP hop succeeds.
        await sender.setShouldThrow(nil)
        let retry = try makeVM(subject: recorded.subject, body: recorded.bodyPlain)
        let retryOK = await retry.send(resending: .init(message: recorded))
        XCTAssertTrue(retryOK, "the retry goes out")

        let sent = await sender.snapshot()
        XCTAssertEqual(sent.count, 1, "only the successful attempt reaches the sender")
        XCTAssertEqual(sent[0].0.messageID?.description, originalID,
                       "a retry must reuse the original Message-Id so the thread doesn't fork")

        let rows = try ctx.fetch(FetchDescriptor<MailMessage>())
        XCTAssertEqual(rows.count, 1, "the retry updates the existing row, it doesn't add one")
        XCTAssertNotNil(recorded.sentAt, "a successful retry marks the message sent")
        XCTAssertNil(failures.reason(for: originalID), "the recorded failure is cleared")
    }

    /// A retry of a threaded reply keeps the headers of the original attempt rather than
    /// re-deriving them (which would thread the message under itself).
    func test_resend_keepsOriginalReplyHeaders() async throws {
        let accounts = try makeStore()
        let acc = try XCTUnwrap(accounts.defaultSender)
        let ctx = try makeThreadContext()
        let threadStore = MailThreadStore(context: ctx)
        let sender = FakeSender()
        let parent = MailMessageHeaders(messageID: "<parent@x>", inReplyTo: nil,
                                        references: ["<root@x>"])
        let vm = ComposeMailViewModel(
            recipient: "bob@example.com", issue: makeIssue(),
            repoOwner: "o", repoName: "r",
            store: accounts, settingsStore: try makeSettingsStore(),
            threadStore: threadStore, sender: sender,
            activityLog: ActivityLog(persistenceURL: nil),
            inReplyTo: parent, senderAccountID: acc.id,
            passwordLoader: { _ in "pw" }
        )
        vm.subject = "Re: Crash"
        vm.body = NSAttributedString(string: "ack")
        await vm.send()

        let recorded = try XCTUnwrap(ctx.fetch(FetchDescriptor<MailMessage>()).first)
        await vm.send(resending: .init(message: recorded))

        let sent = await sender.snapshot()
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[1].0.messageID?.description, recorded.messageID)
        XCTAssertEqual(sent[1].0.additionalHeaders?["In-Reply-To"], "<parent@x>")
        XCTAssertEqual(sent[1].0.additionalHeaders?["References"], "<root@x> <parent@x>")
    }
    // MARK: - Raw attachment ingestion (shared by Files + Photo Library picks)

    /// A real 2×2 PNG: `ImagePreprocessor` runs picked bytes through ImageIO, so a
    /// synthetic `Data([1,2,3])` would be rejected before it ever reaches the strip.
    private func tinyPNG() throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try XCTUnwrap(ctx.makeImage())
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func makeComposeVM() throws -> ComposeMailViewModel {
        let store = try makeStore()
        let acc = try XCTUnwrap(store.defaultSender)
        return ComposeMailViewModel(
            recipient: "bob@example.com",
            issue: makeIssue(),
            repoOwner: "o", repoName: "r",
            store: store,
            settingsStore: try makeSettingsStore(),
            sender: FakeSender(),
            activityLog: ActivityLog(persistenceURL: nil),
            senderAccountID: acc.id,
            passwordLoader: { _ in "pw" }
        )
    }

    func test_ingest_appendsPickedImages() throws {
        let vm = try makeComposeVM()
        let png = try tinyPNG()

        vm.ingest([RawAttachmentInput(filename: "Photo.png", mimeType: "image/png", data: png)])

        XCTAssertEqual(vm.pendingAttachments.count, 1)
        XCTAssertEqual(vm.pendingAttachments[0].filename, "Photo.png")
        XCTAssertEqual(vm.pendingAttachments[0].mimeType, "image/png")
        XCTAssertNil(vm.attachmentError)
    }

    func test_ingest_stopsAtTheThreeAttachmentLimit() throws {
        let vm = try makeComposeVM()
        let png = try tinyPNG()
        let picks = (1...4).map {
            RawAttachmentInput(filename: "Photo-\($0).png", mimeType: "image/png", data: png)
        }

        vm.ingest(picks)

        XCTAssertEqual(vm.pendingAttachments.count, 3, "SDK caps a report at 3 attachments")
        XCTAssertNil(vm.attachmentError)
    }

    /// A tapped photo that can't be decoded used to vanish silently, which reads as a
    /// broken button. It has to say something instead.
    func test_ingest_reportsUnreadableImageInsteadOfSkippingIt() throws {
        let vm = try makeComposeVM()

        vm.ingest([RawAttachmentInput(filename: "Photo.png", mimeType: "image/png", data: Data([1, 2, 3]))])

        XCTAssertTrue(vm.pendingAttachments.isEmpty)
        let message = try XCTUnwrap(vm.attachmentError)
        XCTAssertTrue(message.contains("Photo.png"), "error should name the failed pick, got: \(message)")
    }

    func test_ingest_flagsAPickTheValidatorRejects() throws {
        let vm = try makeComposeVM()

        vm.ingest([RawAttachmentInput(filename: "Photo.webp", mimeType: "image/webp", data: Data([1, 2, 3]))])

        XCTAssertEqual(vm.attachmentError, "Photo.webp: unsupported type.")
    }
}
#endif

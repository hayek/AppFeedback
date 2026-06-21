import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class MailSyncCoordinatorRoleTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(
            for: MailThread.self, MailMessage.self, MailAttachment.self,
                MailAttachmentLocal.self, MailAccountLocalState.self, MailAccount.self,
                MailSettings.self,
            configurations: config
        )
    }

    func test_feedbackInbox_usesListAllInbox_andFiltersNoiseBeforeStore() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let threadStore = MailThreadStore(context: ctx)
        let accountStore = MailAccountStore(context: ctx)
        let settingsStore = MailSettingsStore(context: ctx)
        let localState = MailAccountLocalStateStore(context: ctx)
        let log = ActivityLog(persistenceURL: nil)

        let productID = UUID()
        let account = accountStore.add { acc in
            acc.imapHost = "imap.example.com"; acc.imapUsername = "feedback@dev.com"
            acc.smtpUsername = "feedback@dev.com"
            acc.backfillCompleted = true            // skip backfill path
            acc.feedbackProductID = productID       // ⇒ feedback-inbox role
        }

        let mock = MockIMAPClient()
        let clean = ParsedInboundMessage(
            uid: 5, folder: "INBOX", uidValidity: 1, messageID: "<c@x>",
            inReplyTo: nil, references: [], fromAddress: "user@somewhere.com", fromName: "U",
            toAddresses: ["feedback@dev.com"], ccAddresses: [], date: Date(),
            subject: "Love it", bodyPlain: "great app", bodyHTML: nil, attachments: [])
        let bounce = ParsedInboundMessage(
            uid: 6, folder: "INBOX", uidValidity: 1, messageID: "<b@x>",
            inReplyTo: nil, references: [], fromAddress: "mailer-daemon@x.com", fromName: nil,
            toAddresses: ["feedback@dev.com"], ccAddresses: [], date: Date(),
            subject: "failure", bodyPlain: "", bodyHTML: nil, attachments: [], returnPath: "<>")
        // The vacation auto-reply is the case the mirror could NEVER catch (its rebuilt view has
        // autoSubmitted == nil), so the coordinator MUST filter it pre-store on the full message.
        let vacation = ParsedInboundMessage(
            uid: 7, folder: "INBOX", uidValidity: 1, messageID: "<ooo@x>",
            inReplyTo: nil, references: [], fromAddress: "ceo@example.com", fromName: "CEO",
            toAddresses: ["feedback@dev.com"], ccAddresses: [], date: Date(),
            subject: "Out of office", bodyPlain: "Away until Monday", bodyHTML: nil,
            attachments: [], autoSubmitted: "auto-replied")
        mock.allInboxResponses = [.success([clean, bounce, vacation])]

        let coord = MailSyncCoordinator(
            client: mock, accountID: account.id,
            threadStore: threadStore, accountStore: accountStore,
            settingsStore: settingsStore, localState: localState, activityLog: log,
            mirror: nil, feedbackMirror: nil, notificationService: nil,
            knownIssueTitlesProvider: { [] }
        )
        await coord.pollNow()

        XCTAssertEqual(mock.allInboxCallCount, 1, "feedback inbox must use listAllInbox")
        XCTAssertEqual(mock.inboxCallCount, 0, "must NOT use the FROM-filtered listInbox")

        // Sync store-level assertion: only the clean message became a thread; the bounce AND the
        // vacation auto-reply were filtered pre-store by the coordinator (never recorded).
        let threads = try ctx.fetch(FetchDescriptor<MailThread>())
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads.first?.messageIDRoot, "<c@x>")
    }

    func test_replyMirrorAccount_stillUsesListInbox() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let accountStore = MailAccountStore(context: ctx)
        let account = accountStore.add { acc in
            acc.imapHost = "imap.example.com"; acc.imapUsername = "me@dev.com"
            acc.smtpUsername = "me@dev.com"; acc.backfillCompleted = true
            // feedbackProductID stays nil ⇒ legacy reply-mirror role
        }
        let mock = MockIMAPClient()
        mock.inboxResponses = [.success([])]
        let coord = MailSyncCoordinator(
            client: mock, accountID: account.id,
            threadStore: MailThreadStore(context: ctx), accountStore: accountStore,
            settingsStore: MailSettingsStore(context: ctx),
            localState: MailAccountLocalStateStore(context: ctx),
            activityLog: ActivityLog(persistenceURL: nil),
            mirror: nil, feedbackMirror: nil, notificationService: nil,
            knownIssueTitlesProvider: { [] }
        )
        await coord.pollNow()
        XCTAssertEqual(mock.inboxCallCount, 1)
        XCTAssertEqual(mock.allInboxCallCount, 0)
    }
}

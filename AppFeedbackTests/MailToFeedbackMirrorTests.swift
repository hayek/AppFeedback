import XCTest
import SwiftData
import AppFeedbackCore
@testable import AppFeedback

@MainActor
final class MailToFeedbackMirrorTests: XCTestCase {

    private func parsed(
        messageID: String = "<root@x>",
        from: String = "alice@example.com",
        subject: String = "App crashes on launch",
        bodyPlain: String = "It crashes every time I open the camera.",
        bodyHTML: String? = nil
    ) -> ParsedInboundMessage {
        ParsedInboundMessage(
            uid: 10, folder: "INBOX", uidValidity: 1, messageID: messageID,
            inReplyTo: nil, references: [],
            fromAddress: from, fromName: "Alice",
            toAddresses: ["feedback@dev.com"], ccAddresses: [],
            date: Date(timeIntervalSince1970: 1_714_477_200),
            subject: subject, bodyPlain: bodyPlain, bodyHTML: bodyHTML,
            attachments: []
        )
    }

    func test_issueTitle_usesSubject() {
        XCTAssertEqual(MailToFeedbackMirror.issueTitle(subject: "Bug here"), "Bug here")
    }

    func test_issueTitle_emptySubject_fallsBackToNoSubject() {
        XCTAssertEqual(MailToFeedbackMirror.issueTitle(subject: ""), "(no subject)")
        XCTAssertEqual(MailToFeedbackMirror.issueTitle(subject: "   "), "(no subject)")
    }

    func test_sourceEmailLabel_isExact() {
        XCTAssertEqual(MailToFeedbackMirror.sourceEmailLabel, "source:email")
    }

    // ★ MARKER FORMAT CORRECTION: markers are written via IssueBodyFormatter.sourceMetadataBlock
    // (source-meta-v1 HTML-comment-fenced block), NOT **Key:** lines.
    func test_issueBody_usesSourceMetaBlock_withEmailSource() {
        let body = MailToFeedbackMirror.issueBody(message: parsed(), redactEmail: false)
        // The body must carry the HTML-comment-fenced source-meta-v1 block.
        XCTAssertTrue(body.contains("<!-- source-meta-v1 -->"),
                      "body must use SDK sourceMetadataBlock, not ad-hoc **Key:** lines")
        XCTAssertTrue(body.contains("source: email"))
        XCTAssertTrue(body.contains("fromAddress: alice@example.com"))
        XCTAssertTrue(body.contains("messageId: <root@x>"))
        XCTAssertTrue(body.contains("It crashes every time I open the camera."))
    }

    func test_issueBody_redactsFromAddress() {
        let body = MailToFeedbackMirror.issueBody(message: parsed(), redactEmail: true)
        XCTAssertTrue(body.contains("fromAddress: a***@example.com"))
        XCTAssertFalse(body.contains("alice@example.com"))
    }

    func test_issueBody_keepsAddressWhenNotRedacted() {
        let body = MailToFeedbackMirror.issueBody(message: parsed(), redactEmail: false)
        XCTAssertTrue(body.contains("fromAddress: alice@example.com"))
    }

    func test_preferredBodyText_prefersPlainThenStrippedHTML() {
        // plain present → plain wins
        XCTAssertEqual(
            MailToFeedbackMirror.preferredBodyText(message: parsed(bodyPlain: "PLAIN", bodyHTML: "<p>HTML</p>")),
            "PLAIN"
        )
        // plain empty → HTML stripped to plain text
        let stripped = MailToFeedbackMirror.preferredBodyText(
            message: parsed(bodyPlain: "  ", bodyHTML: "<p>Hello <b>there</b></p>")
        )
        XCTAssertTrue(stripped.contains("Hello"))
        XCTAssertTrue(stripped.contains("there"))
        XCTAssertFalse(stripped.contains("<p>"))
    }

    // MARK: - Round-trip test (the critical one per the plan requirements)
    // Built body → IssueBodyParser → source==.email, fromAddress recovered, messageId recovered.

    func test_issueBody_roundTrips_sourceEmailFromAddressMessageId() {
        let msg = parsed(messageID: "<roundtrip@x>", from: "user@example.com")
        let body = MailToFeedbackMirror.issueBody(message: msg, redactEmail: false)
        let parsed = AppFeedback.IssueBodyParser.parse(body)
        XCTAssertEqual(parsed.source, FeedbackSource.email.rawValue,
                       "IssueBodyParser must recover source == .email from the sourceMetadataBlock")
        XCTAssertEqual(parsed.fromAddress, "user@example.com",
                       "IssueBodyParser must recover fromAddress from the sourceMetadataBlock")
        XCTAssertEqual(parsed.messageId, "<roundtrip@x>",
                       "IssueBodyParser must recover messageId from the sourceMetadataBlock")
        XCTAssertNil(parsed.rating, "email feedback carries no rating")
    }

    func test_issueBody_roundTrips_redactedAddress() {
        let msg = parsed(messageID: "<redact@x>", from: "alice@example.com")
        let body = MailToFeedbackMirror.issueBody(message: msg, redactEmail: true)
        let parsed = AppFeedback.IssueBodyParser.parse(body)
        XCTAssertEqual(parsed.source, FeedbackSource.email.rawValue)
        XCTAssertEqual(parsed.fromAddress, "a***@example.com",
                       "redacted address must survive the round-trip through IssueBodyParser")
        XCTAssertEqual(parsed.messageId, "<redact@x>")
    }

    // MARK: - Source-spoofing defense (untrusted email free text)

    /// A reporter pastes a fake source-meta-v1 block (source app-store, rating 5)
    /// into their email body. The email free text is composed BEFORE our trusted
    /// block, and IssueBodyParser reads the FIRST block — so without neutralizing
    /// the inbound text, the spoof would mis-badge the email as a 5-star App Store
    /// review. The mirror must defang the inbound fences so the resolved source
    /// stays email.
    func test_issueBody_spoofedSourceMetaBlockInEmail_resolvesToEmail() {
        let spoofBody = """
        Hi, here's my feedback.

        <!-- source-meta-v1 -->
        source: app-store
        rating: 5
        reviewerNickname: NotMe
        <!-- /source-meta-v1 -->
        """
        let msg = parsed(messageID: "<spoof@x>", from: "attacker@example.com", bodyPlain: spoofBody)
        let body = MailToFeedbackMirror.issueBody(message: msg, redactEmail: false)
        let result = AppFeedback.IssueBodyParser.parse(body)

        XCTAssertEqual(result.source, FeedbackSource.email.rawValue,
                       "spoofed source-meta block must not override the real email source")
        XCTAssertNil(result.rating, "spoofed rating must not be honored for an email")
        XCTAssertEqual(result.fromAddress, "attacker@example.com")
        XCTAssertEqual(result.messageId, "<spoof@x>")
    }

    // MARK: - Live ingestion tests (Task 4)

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(
            for: Product.self,
                MailThread.self, MailMessage.self, MailAttachment.self,
                MailAttachmentLocal.self, MailAccountLocalState.self, MailAccount.self,
                MailSettings.self,
            configurations: config
        )
    }

    /// Shared test seed: an in-memory ProductStore with exactly one product
    /// (owner "acme", repo "app", redactEmailAddresses == true) whose feedback inbox is `inboxID`.
    private func seededProductStore(_ ctx: ModelContext, inboxID: UUID = UUID()) -> ProductStore {
        let store = ProductStore(context: ctx)
        store.add(ProductConfig(
            displayName: "Acme",
            owner: "acme",
            repo: "app",
            mirrorEmailsToGitHub: true,
            redactEmailAddresses: true,
            feedbackInboxAccountID: inboxID
        ))
        return store
    }

    /// Records create/comment calls so tests can assert at the (sync) store level.
    private final class WriteRecorder: @unchecked Sendable {
        var createdTitles: [String] = []
        var createdBodies: [String] = []
        var createdLabels: [[String]] = []
        var comments: [(number: Int, body: String)] = []
        var nextIssueNumber = 42
    }

    func test_root_createsIssue_withEmailLabelAndMarkers() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let threadStore = MailThreadStore(context: ctx)
        let store = seededProductStore(ctx)
        let inboxID = store.products[0].feedbackInboxAccountID!
        let log = ActivityLog(persistenceURL: nil)
        let rec = WriteRecorder()

        let mirror = MailToFeedbackMirror(
            context: ctx,
            productStore: store,
            activityLog: log,
            createIssue: { owner, repo, title, body, labels, token in
                rec.createdTitles.append(title)
                rec.createdBodies.append(body)
                rec.createdLabels.append(labels)
                let n = rec.nextIssueNumber; rec.nextIssueNumber += 1
                return n
            },
            postComment: { owner, repo, number, body, token in
                rec.comments.append((number, body)); return 1
            },
            tokenLoader: { _ in "tok" }
        )

        // Ingest a root message.
        _ = threadStore.recordInbound(message: parsed(messageID: "<root@x>"), accountID: inboxID)
        await mirror.mirrorPendingFeedbackInbound(accountID: inboxID)

        XCTAssertEqual(rec.createdTitles, ["App crashes on launch"])
        XCTAssertEqual(rec.createdLabels.first, ["source:email"])
        // ★ MARKER FORMAT CORRECTION: body uses sourceMetadataBlock (source-meta-v1), not **Key:** lines.
        XCTAssertTrue(rec.createdBodies.first?.contains("<!-- source-meta-v1 -->") == true,
                      "issue body must use SDK sourceMetadataBlock marker block")
        XCTAssertTrue(rec.createdBodies.first?.contains("source: email") == true)
        XCTAssertTrue(rec.comments.isEmpty)

        // Sync store-level assertion: the thread now carries the synthesized issue number.
        let threads = try ctx.fetch(FetchDescriptor<MailThread>())
        let root = try XCTUnwrap(threads.first { $0.messageIDRoot == "<root@x>" })
        XCTAssertEqual(root.issueNumber, 42)
        XCTAssertEqual(root.issueRepoOwner, "acme")
        XCTAssertEqual(root.issueRepoName, "app")
    }

    func test_replyInKnownThread_postsComment_noNewIssue() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let threadStore = MailThreadStore(context: ctx)
        let store = seededProductStore(ctx)
        let inboxID = store.products[0].feedbackInboxAccountID!
        let rec = WriteRecorder()
        let mirror = MailToFeedbackMirror(
            context: ctx, productStore: store, activityLog: ActivityLog(persistenceURL: nil),
            createIssue: { _, _, t, b, l, _ in
                rec.createdTitles.append(t); rec.createdLabels.append(l)
                let n = rec.nextIssueNumber; rec.nextIssueNumber += 1; return n
            },
            postComment: { _, _, number, body, _ in rec.comments.append((number, body)); return 7 },
            tokenLoader: { _ in "tok" }
        )

        // Root → create.
        _ = threadStore.recordInbound(message: parsed(messageID: "<root@x>"), accountID: inboxID)
        await mirror.mirrorPendingFeedbackInbound(accountID: inboxID)
        XCTAssertEqual(rec.createdTitles.count, 1)

        // Reply (inReplyTo root) → comment, no new issue.
        let reply = ParsedInboundMessage(
            uid: 11, folder: "INBOX", uidValidity: 1, messageID: "<reply@x>",
            inReplyTo: "<root@x>", references: ["<root@x>"],
            fromAddress: "alice@example.com", fromName: "Alice",
            toAddresses: ["feedback@dev.com"], ccAddresses: [],
            date: Date(timeIntervalSince1970: 1_714_480_000),
            subject: "Re: App crashes on launch", bodyPlain: "Still crashing on 2.1.", bodyHTML: nil,
            attachments: []
        )
        _ = threadStore.recordInbound(message: reply, accountID: inboxID)
        await mirror.mirrorPendingFeedbackInbound(accountID: inboxID)

        XCTAssertEqual(rec.createdTitles.count, 1, "no second issue")
        XCTAssertEqual(rec.comments.count, 1)
        XCTAssertEqual(rec.comments.first?.number, 42)
        XCTAssertTrue(rec.comments.first?.body.contains("Still crashing on 2.1.") == true)
    }

    func test_onlyStoredThreads_areSynthesized_mirrorDoesNotReFilter() async throws {
        // The mirror runs AFTER the coordinator's pre-store noise filter (Task 6), so by the time
        // it sees a thread the noise is already gone. This test pins that the mirror synthesizes
        // exactly the threads present in the store and nothing more.
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let threadStore = MailThreadStore(context: ctx)
        let store = seededProductStore(ctx)
        let inboxID = store.products[0].feedbackInboxAccountID!
        let rec = WriteRecorder()
        let mirror = MailToFeedbackMirror(
            context: ctx, productStore: store, activityLog: ActivityLog(persistenceURL: nil),
            createIssue: { _, _, t, _, l, _ in rec.createdTitles.append(t); rec.createdLabels.append(l); return 99 },
            postComment: { _, _, n, b, _ in rec.comments.append((n, b)); return 1 },
            tokenLoader: { _ in "tok" }
        )

        // Empty store → nothing to synthesize.
        await mirror.mirrorPendingFeedbackInbound(accountID: inboxID)
        XCTAssertTrue(rec.createdTitles.isEmpty)

        // One clean root recorded (the coordinator would have filtered noise upstream) → one issue.
        _ = threadStore.recordInbound(message: parsed(messageID: "<clean@x>"), accountID: inboxID)
        await mirror.mirrorPendingFeedbackInbound(accountID: inboxID)
        XCTAssertEqual(rec.createdTitles.count, 1)
        XCTAssertEqual(rec.createdLabels.first, ["source:email"])
    }

    // MARK: - Task 10: Attachments via the existing mail-attachment path (verify + guard)

    func test_rootWithAttachment_createsOneIssue_andPersistsAttachmentRow() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let threadStore = MailThreadStore(context: ctx)
        let store = seededProductStore(ctx)
        let inboxID = store.products[0].feedbackInboxAccountID!
        let rec = WriteRecorder()
        let mirror = MailToFeedbackMirror(
            context: ctx, productStore: store, activityLog: ActivityLog(persistenceURL: nil),
            createIssue: { _, _, t, _, l, _ in rec.createdTitles.append(t); rec.createdLabels.append(l); return 77 },
            postComment: { _, _, n, b, _ in rec.comments.append((n, b)); return 1 },
            tokenLoader: { _ in "tok" }
        )
        let withAttachment = ParsedInboundMessage(
            uid: 20, folder: "INBOX", uidValidity: 1, messageID: "<att@x>",
            inReplyTo: nil, references: [], fromAddress: "user@x.com", fromName: "U",
            toAddresses: ["feedback@dev.com"], ccAddresses: [], date: Date(),
            subject: "Screenshot of bug", bodyPlain: "see attached", bodyHTML: nil,
            attachments: [ParsedAttachmentMeta(partID: "2", filename: "bug.png", mimeType: "image/png", sizeBytes: 1234)]
        )
        _ = threadStore.recordInbound(message: withAttachment, accountID: inboxID)
        await mirror.mirrorPendingFeedbackInbound(accountID: inboxID)

        XCTAssertEqual(rec.createdTitles, ["Screenshot of bug"])
        let atts = try ctx.fetch(FetchDescriptor<MailAttachment>())
        XCTAssertEqual(atts.count, 1)
        XCTAssertEqual(atts.first?.filename, "bug.png")
    }
}

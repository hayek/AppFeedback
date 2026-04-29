import XCTest
@testable import AppFeedback

final class ThreadMatcherTests: XCTestCase {

    // MARK: - Helpers

    private func makeParsed(
        uid: UInt32 = 1,
        folder: String = "INBOX",
        uidValidity: UInt32 = 100,
        messageID: String = "<msg@example.com>",
        inReplyTo: String? = nil,
        references: [String] = [],
        from: String = "sender@example.com",
        to: [String] = ["recipient@example.com"],
        cc: [String] = [],
        subject: String = "Test Subject",
        date: Date = Date()
    ) -> ParsedInboundMessage {
        ParsedInboundMessage(
            uid: uid,
            folder: folder,
            uidValidity: uidValidity,
            messageID: messageID,
            inReplyTo: inReplyTo,
            references: references,
            fromAddress: from,
            fromName: nil,
            toAddresses: to,
            ccAddresses: cc,
            date: date,
            subject: subject,
            bodyPlain: "Body",
            bodyHTML: nil,
            attachments: []
        )
    }

    private func makeCandidate(
        messageID: String,
        subject: String = "Test Subject",
        participants: [String] = ["sender@example.com", "recipient@example.com"],
        lastMessageAt: Date = Date()
    ) -> ThreadMatcher.Candidate {
        ThreadMatcher.Candidate(
            messageID: messageID,
            subject: subject,
            participants: participants,
            lastMessageAt: lastMessageAt
        )
    }

    // MARK: - attach tests

    // 1. In-Reply-To header matches a candidate → .header
    func test_attach_inReplyToMatchesCandidate_returnsHeader() {
        let candidate = makeCandidate(messageID: "<original@example.com>")
        let message = makeParsed(
            messageID: "<reply@example.com>",
            inReplyTo: "<original@example.com>"
        )

        let result = ThreadMatcher.attach(message: message, existing: [candidate])

        XCTAssertEqual(result, .header(threadIndex: 0))
    }

    // 2. References chain matches a candidate (no inReplyTo) → .header
    func test_attach_referencesChainMatches_returnsHeader() {
        let candidate = makeCandidate(messageID: "<old@example.com>")
        let message = makeParsed(
            messageID: "<new@example.com>",
            inReplyTo: nil,
            references: ["<earlier@example.com>", "<old@example.com>"]
        )

        let result = ThreadMatcher.attach(message: message, existing: [candidate])

        XCTAssertEqual(result, .header(threadIndex: 0))
    }

    // 3. No header match, stripped subject matches and recipients overlap → .subject
    func test_attach_noHeaderMatch_subjectMatchesAndRecipientsOverlap_returnsSubject() {
        let candidate = makeCandidate(
            messageID: "<thread-root@example.com>",
            subject: "Hello World",
            participants: ["alice@example.com", "bob@example.com"]
        )
        let message = makeParsed(
            messageID: "<reply2@example.com>",
            from: "alice@example.com",
            subject: "Re: Hello World"
        )

        let result = ThreadMatcher.attach(message: message, existing: [candidate])

        XCTAssertEqual(result, .subject(threadIndex: 0))
    }

    // 4. Subject matches but all addresses are disjoint → .newThread
    func test_attach_subjectMatchesButRecipientsDisjoint_returnsNewThread() {
        let candidate = makeCandidate(
            messageID: "<thread-root@example.com>",
            subject: "Hello World",
            participants: ["charlie@example.com", "dave@example.com"]
        )
        let message = makeParsed(
            messageID: "<unrelated@example.com>",
            from: "alice@example.com",
            to: ["bob@example.com"],
            cc: [],
            subject: "Re: Hello World"
        )

        let result = ThreadMatcher.attach(message: message, existing: [candidate])

        XCTAssertEqual(result, .newThread)
    }

    // 5. Multiple candidates match on subject; newest lastMessageAt wins
    func test_attach_multipleSubjectCandidates_newestWins() {
        let now = Date()
        let earlier = now.addingTimeInterval(-3600)

        let candidateOld = makeCandidate(
            messageID: "<old-thread@example.com>",
            subject: "Status Update",
            participants: ["alice@example.com"],
            lastMessageAt: earlier
        )
        let candidateNew = makeCandidate(
            messageID: "<new-thread@example.com>",
            subject: "Status Update",
            participants: ["alice@example.com"],
            lastMessageAt: now
        )

        let message = makeParsed(
            messageID: "<msg@example.com>",
            from: "alice@example.com",
            subject: "Re: Status Update"
        )

        let result = ThreadMatcher.attach(message: message, existing: [candidateOld, candidateNew])

        // Index 1 is the newer candidate
        XCTAssertEqual(result, .subject(threadIndex: 1))
    }

    // 6. No match at all → .newThread
    func test_attach_noMatchAtAll_returnsNewThread() {
        let candidate = makeCandidate(
            messageID: "<unrelated@example.com>",
            subject: "Something Else",
            participants: ["other@example.com"]
        )
        let message = makeParsed(
            messageID: "<fresh@example.com>",
            from: "alice@example.com",
            subject: "Brand New Topic"
        )

        let result = ThreadMatcher.attach(message: message, existing: [candidate])

        XCTAssertEqual(result, .newThread)
    }

    // MARK: - matchToIssue tests

    // 7. Case-insensitive substring match returns the issue
    func test_matchToIssue_substringMatch_returnsIssue() {
        let issues: [(owner: String, repo: String, number: Int, title: String)] = [
            (owner: "myorg", repo: "myrepo", number: 42, title: "Login button broken")
        ]

        let result = ThreadMatcher.matchToIssue(
            threadSubject: "Re: Login Button Broken on mobile",
            knownIssueTitles: issues
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.owner, "myorg")
        XCTAssertEqual(result?.repo, "myrepo")
        XCTAssertEqual(result?.number, 42)
    }

    // 8. No match returns nil
    func test_matchToIssue_noMatch_returnsNil() {
        let issues: [(owner: String, repo: String, number: Int, title: String)] = [
            (owner: "myorg", repo: "myrepo", number: 10, title: "Dark mode crash")
        ]

        let result = ThreadMatcher.matchToIssue(
            threadSubject: "Completely unrelated subject",
            knownIssueTitles: issues
        )

        XCTAssertNil(result)
    }

    // 9. Multiple matches → highest number wins
    func test_matchToIssue_multipleMatches_highestNumberWins() {
        let issues: [(owner: String, repo: String, number: Int, title: String)] = [
            (owner: "org", repo: "repo", number: 5,  title: "crash on launch"),
            (owner: "org", repo: "repo", number: 12, title: "crash"),
            (owner: "org", repo: "repo", number: 7,  title: "on launch")
        ]

        // Subject contains all three titles
        let result = ThreadMatcher.matchToIssue(
            threadSubject: "crash on launch fix",
            knownIssueTitles: issues
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.number, 12)
    }

    // 10. Titles shorter than the minimum length (4 chars) are skipped
    func test_matchToIssue_skipsVeryShortTitles() {
        let issues: [(owner: String, repo: String, number: Int, title: String)] = [
            (owner: "org", repo: "repo", number: 1, title: "1"),    // too short (1 char)
            (owner: "org", repo: "repo", number: 2, title: "bug"),  // too short (3 chars)
            (owner: "org", repo: "repo", number: 3, title: "ok"),   // too short (2 chars)
        ]

        // Would match "1", "bug", "ok" if length guard weren't present
        let result = ThreadMatcher.matchToIssue(
            threadSubject: "1 bug ok in login",
            knownIssueTitles: issues
        )

        XCTAssertNil(result, "Short titles should be skipped; nothing with length >= 4 matches")
    }

    // MARK: - stripReplyPrefixes tests

    // 11. Chained prefixes are fully stripped
    func test_stripReplyPrefixes_collapsesChainedPrefixes() {
        XCTAssertEqual(ThreadMatcher.stripReplyPrefixes("Re: Re: Fwd: foo"), "foo")
        XCTAssertEqual(ThreadMatcher.stripReplyPrefixes("RE: FWD: bar"), "bar")
        XCTAssertEqual(ThreadMatcher.stripReplyPrefixes("re:fwd:baz"), "baz")
        XCTAssertEqual(ThreadMatcher.stripReplyPrefixes("Fw: hello"), "hello")
        XCTAssertEqual(ThreadMatcher.stripReplyPrefixes("Re:Fwd:qux"), "qux")
        XCTAssertEqual(ThreadMatcher.stripReplyPrefixes("plain subject"), "plain subject")
        XCTAssertEqual(ThreadMatcher.stripReplyPrefixes("Re: Re: Re: deep"), "deep")
    }
}

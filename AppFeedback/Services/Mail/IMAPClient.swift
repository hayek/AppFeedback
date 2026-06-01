import Foundation
#if canImport(SwiftMail)
import SwiftMail

// MARK: - Pre-flight API notes (recorded 2026-04-29)
//
// SwiftMail IMAP capabilities verified in:
//   .../SwiftMail/Sources/SwiftMail/IMAP/IMAPServer.swift
//   .../SwiftMail/Sources/SwiftMail/IMAP/Models/
//
// (1) Connect + authenticate
//     let server = IMAPServer(host: String, port: Int)
//     try await server.connect()
//     try await server.login(username: String, password: String)
//
// (2) Select mailbox / list mailboxes
//     let selection: Mailbox.Selection = try await server.selectMailbox("INBOX")
//     // selection.uidValidity: UIDValidity   ← covers requirement (6) — exposed!
//     let mailboxes: [Mailbox.Info] = try await server.listMailboxes()
//     // [Mailbox.Info] has computed .inbox and .sent that resolve special-use attributes
//     // and fall back to common names ("[Gmail]/Sent Mail", "Sent Messages", etc.)
//
// (3) UID-range search (UID > N)
//     let infos: [MessageInfo] = try await server.fetchMessageInfos(uidRange: UID(n+1)...UID.latest)
//     // MessageInfo carries .uid, .messageId, .inReplyTo, .references, .date, .from, .to, .cc
//
// (4) Fetch full message (headers + body parts)
//     let msg: Message = try await server.fetchMessage(from: MessageInfo)
//     // msg.textBody: String?   msg.htmlBody: String?   msg.attachments: [MessagePart]
//
// (5) Fetch specific body part bytes by section
//     let data: Data = try await server.fetchPart(section: Section(partID), of: UID(uid))
//     // Section("1.2") wraps a dot-separated part number string
//
// (6) UIDValidity — Mailbox.Selection.uidValidity is UIDValidity (value: UInt32). Fully exposed.
//
// (7) Structure-only fetch (no bytes downloaded)
//     let parts: [MessagePart] = try await server.fetchStructure(UID(uid))
//     // Returns [MessagePart] with data == nil.  Used in listInbox/listSent to avoid
//     // pulling attachment bytes eagerly.  Text/HTML parts are fetched individually.

private let imapInboxName = "INBOX"

// MARK: - Actor

actor IMAPClient: IMAPClientProtocol {
    /// Hard ceiling on Sent-folder messages processed in one backfill pass.
    private static let sentBackfillUIDLimit = 200

    private let host: String
    private let port: Int
    private let username: String
    private let password: String

    init(host: String, port: Int, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    // MARK: - IMAPClientProtocol

    func listInbox(sinceUID: UInt32, expectedUIDValidity: UInt32, fromAddresses: [String]) async throws -> InboxPollResult {
        let tag = "[IMAPClient \(username)]"
        // No recipients yet → no replies to look for. Skip the IMAP round-trip entirely.
        // uidValidity=0 means "unknown" — the caller's next poll will discover the real
        // value once it has recipients to search for.
        if fromAddresses.isEmpty {
            print("\(tag) listInbox: skipped — fromAddresses empty (sinceUID=\(sinceUID))")
            return InboxPollResult(messages: [], uidValidity: 0)
        }

        let server = IMAPServer(host: host, port: port)
        try await connectAndLogin(server)
        defer { Task.detached { try? await server.disconnect() } }

        let selection = try await mapped { try await server.selectMailbox(imapInboxName) }
        let folder = imapInboxName
        let uidValidity = selection.uidValidity.value

        // Decide whether the stored `sinceUID` is trustworthy. Two cases force a reset:
        //   1. expectedUIDValidity != 0 and != observed → server reassigned UID space
        //      (mailbox recreated, restored from backup).
        //   2. expectedUIDValidity == 0 but sinceUID > 0 → we have a watermark with no
        //      validity anchor, so we can't tell which UID space it came from. This is
        //      the contamination case left by the old shared-`state` bug. Healing in one
        //      poll (instead of two) avoids a follow-up cycle of redundant SEARCHes.
        let effectiveSinceUID: UInt32
        if expectedUIDValidity != 0 && expectedUIDValidity != uidValidity {
            print("\(tag) listInbox: UIDVALIDITY changed \(expectedUIDValidity) → \(uidValidity), resetting sinceUID from \(sinceUID) to 0")
            effectiveSinceUID = 0
        } else if expectedUIDValidity == 0 && sinceUID > 0 {
            print("\(tag) listInbox: no stored UIDVALIDITY but sinceUID=\(sinceUID); resetting to 0 to anchor against observed UIDVALIDITY=\(uidValidity)")
            effectiveSinceUID = 0
        } else {
            effectiveSinceUID = sinceUID
        }

        // Server-side filter: replies come from people we wrote to. Gmail indexes FROM
        // efficiently. Run one SEARCH per recipient and union locally — chained ORs and
        // non-ASCII quoted strings both produce `BAD Could not parse command` on Gmail,
        // so we avoid both: bare ASCII addr@domain, one SEARCH per recipient.
        let cleanedAddresses = Array(Set(fromAddresses.compactMap(MailAddress.bare)))
        print("\(tag) listInbox: INBOX selected uidValidity=\(uidValidity), effectiveSinceUID=\(effectiveSinceUID), fromAddresses=\(fromAddresses.count), cleaned=\(cleanedAddresses)")
        // Mirror the `fromAddresses.isEmpty` branch: we did no real search, so leave
        // `uidValidity=0` to avoid committing a watermark we never anchored.
        if cleanedAddresses.isEmpty { return InboxPollResult(messages: [], uidValidity: 0) }
        let infos: [MessageInfo] = try await mapped {
            // SwiftMail serializes commands per IMAPServer connection, so issuing the
            // SEARCHes in parallel from a task group still walks the wire one-at-a-time
            // — but it overlaps SwiftMail's per-command processing with the next
            // network round-trip and removes the await-chain stalls between them.
            let unionUIDs: Set<UInt32> = try await withThrowingTaskGroup(
                of: (String, [UInt32]).self,
                returning: Set<UInt32>.self
            ) { group in
                for addr in cleanedAddresses {
                    group.addTask {
                        let hits: MessageIdentifierSet<UID> = try await server.search(criteria: [.from(addr)])
                        return (addr, hits.toArray().map(\.value))
                    }
                }
                var union: Set<UInt32> = []
                for try await (addr, batch) in group {
                    print("\(tag)   SEARCH FROM \(addr) → \(batch.count) UID(s): \(batch.sorted())")
                    union.formUnion(batch)
                }
                return union
            }
            let unseen = unionUIDs.filter { $0 > effectiveSinceUID }
            print("\(tag) listInbox: union=\(unionUIDs.count), unseen(>\(effectiveSinceUID))=\(unseen.count): \(unseen.sorted())")
            if unseen.isEmpty { return [] }
            let fetched = try await server.fetchMessageInfosBulk(using: MessageIdentifierSet(unseen.map { UID($0) }))
            print("\(tag) listInbox: fetchMessageInfosBulk returned \(fetched.count) info(s)")
            return fetched
        }

        var results: [ParsedInboundMessage] = []
        for info in infos {
            do {
                let parsed = try await fetchAndParse(server: server, info: info, folder: folder, uidValidity: uidValidity)
                results.append(parsed)
            } catch is CancellationError {
                throw IMAPClientError.cancelled
            } catch {
                print("\(tag) Skipping message uid=\(info.uid?.value ?? 0): \(error)")
            }
        }
        print("\(tag) listInbox: returning \(results.count) parsed message(s), uidValidity=\(uidValidity)")
        return InboxPollResult(messages: results, uidValidity: uidValidity)
    }

    func listSent(sinceDate: Date) async throws -> [ParsedInboundMessage] {
        let server = IMAPServer(host: host, port: port)
        try await connectAndLogin(server)
        defer { Task.detached { try? await server.disconnect() } }

        // Discover the sent folder via SwiftMail's special-use + name fallback logic
        let mailboxes = try await mapped { try await server.listMailboxes() }
        guard let sentMailbox = mailboxes.sent else {
            throw IMAPClientError.malformed(detail: "No Sent folder found on server")
        }
        let folder = sentMailbox.name

        let selection = try await mapped { try await server.selectMailbox(folder) }
        let uidValidity = selection.uidValidity.value

        // IMAP SINCE is date-granular; we use sentSince (Date: header) as a best-effort filter.
        let matchingUIDs: MessageIdentifierSet<UID> = try await mapped {
            try await server.search(criteria: [.sentSince(sinceDate)])
        }

        if matchingUIDs.isEmpty { return [] }

        // Cap to the most recent UIDs. Without this, a busy account's Sent folder can
        // produce hundreds of structure-fetch round-trips that overrun command timeouts.
        let cappedUIDs = matchingUIDs.toArray().sorted(by: { $0.value > $1.value }).prefix(Self.sentBackfillUIDLimit)
        let cappedSet = MessageIdentifierSet<UID>(Array(cappedUIDs))

        let infos: [MessageInfo] = try await mapped {
            try await server.fetchMessageInfosBulk(using: cappedSet)
        }

        // Backfill only needs Message-Id, subject, recipients, and date — all already in
        // MessageInfo. Skipping per-message body/structure fetches (the slow part) means
        // backfill finishes with a single bulk call instead of N+1 round-trips.
        return infos.map { info in
            Self.parse(
                info: info,
                folder: folder,
                uidValidity: uidValidity,
                bodyPlain: "",
                bodyHTML: nil,
                attachments: []
            )
        }
    }

    func listSentForEnrichment(sinceDate: Date, messageIDs: Set<String>) async throws -> [ParsedInboundMessage] {
        guard !messageIDs.isEmpty else { return [] }
        let tag = "[IMAPClient \(username)]"
        let server = IMAPServer(host: host, port: port)
        try await connectAndLogin(server)
        defer { Task.detached { try? await server.disconnect() } }

        // Discover + select the Sent folder (same special-use + name fallback as listSent).
        let mailboxes = try await mapped { try await server.listMailboxes() }
        guard let sentMailbox = mailboxes.sent else {
            throw IMAPClientError.malformed(detail: "No Sent folder found on server")
        }
        let folder = sentMailbox.name
        let selection = try await mapped { try await server.selectMailbox(folder) }
        let uidValidity = selection.uidValidity.value

        // Find each needed reply by its exact Message-Id. There is no UID watermark to advance and
        // nothing to strand: a message not yet filed (or transiently failing) is simply retried on
        // the next pass while it remains in the gate. AND with sentSince so the server scopes the
        // HEADER search to recent mail instead of the whole Sent folder.
        var enriched: [ParsedInboundMessage] = []
        for messageID in messageIDs {
            // HEADER search is a substring match; the bare addr-spec (no angle brackets) is unique
            // and sidesteps bracket-encoding quirks across servers.
            let needle = messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            do {
                let hits: MessageIdentifierSet<UID> = try await mapped {
                    try await server.search(criteria: [.sentSince(sinceDate), .header("Message-ID", needle)])
                }
                guard let uid = hits.toArray().max(by: { $0.value < $1.value }) else { continue }
                let infos = try await mapped {
                    try await server.fetchMessageInfosBulk(using: MessageIdentifierSet<UID>([uid]))
                }
                guard let info = infos.first else { continue }
                enriched.append(try await fetchStructureOnly(server: server, info: info, folder: folder, uidValidity: uidValidity))
            } catch is CancellationError {
                throw IMAPClientError.cancelled
            } catch IMAPClientError.cancelled {
                // `mapped` converts a CancellationError from search/fetch into this; propagate it so
                // a cancelled poll stops issuing round-trips for the remaining Message-Ids.
                throw IMAPClientError.cancelled
            } catch {
                print("\(tag) Sent enrich skip \(messageID): \(error)")
            }
        }
        print("\(tag) listSentForEnrichment: requested \(messageIDs.count), enriched \(enriched.count)")
        return enriched
    }

    /// Appends an already-sent message to the Sent folder (IMAP APPEND), flagged `\Seen`. Used for
    /// providers whose SMTP submission does NOT auto-file a copy (iCloud, generic IMAP) so the reply
    /// appears in the user's real Sent mailbox AND its Message-Id can later be found by Sent
    /// enrichment to surface attachments.
    func appendToSent(_ email: SwiftMail.Email) async throws {
        let server = IMAPServer(host: host, port: port)
        try await connectAndLogin(server)
        defer { Task.detached { try? await server.disconnect() } }

        let mailboxes = try await mapped { try await server.listMailboxes() }
        guard let sentMailbox = mailboxes.sent else {
            throw IMAPClientError.malformed(detail: "No Sent folder found on server")
        }
        _ = try await mapped { try await server.append(email: email, to: sentMailbox.name, flags: [.seen]) }
    }

    func fetchAttachmentBytes(uid: UInt32, folder: String, partID: String, expectedUIDValidity: UInt32) async throws -> Data {
        let server = IMAPServer(host: host, port: port)
        try await connectAndLogin(server)
        defer { Task.detached { try? await server.disconnect() } }

        let selection = try await mapped { try await server.selectMailbox(folder) }
        // Reject a stale uid: if the folder's UID space was reassigned since this message was
        // recorded, `uid` now points at a different (or no) message — fetching would return the
        // wrong bytes silently. 0 means "unknown", so we skip the check (legacy/local rows).
        if expectedUIDValidity != 0 && selection.uidValidity.value != expectedUIDValidity {
            throw IMAPClientError.malformed(
                detail: "UIDVALIDITY changed for \(folder) (\(expectedUIDValidity) → \(selection.uidValidity.value)); uid \(uid) is stale"
            )
        }

        // BODYSTRUCTURE first so we know the part's Content-Transfer-Encoding. Without
        // this, base64-encoded binary parts (the common case for images) get written to
        // disk as base64 text and never render. SwiftMail's `fetchPart` returns raw
        // post-transfer-encoding bytes; the decode step is `.decoded(for: part)`.
        let section = Section(partID)
        let structure = try await mapped { try await server.fetchStructure(UID(uid)) }
        guard let part = structure.first(where: { $0.section.description == partID }) else {
            throw IMAPClientError.malformed(detail: "part \(partID) not in BODYSTRUCTURE for uid=\(uid)")
        }
        let raw = try await mapped { try await server.fetchPart(section: section, of: UID(uid)) }
        return raw.decoded(for: part)
    }

    func testConnection() async throws {
        let server = IMAPServer(host: host, port: port)
        try await connectAndLogin(server)
        try? await server.disconnect()
    }

    // MARK: - Private helpers

    /// Connects and authenticates.  Auth errors are mapped to `IMAPClientError.authFailed`;
    /// all other failures map to `IMAPClientError.transport`.
    ///
    /// The heuristic below (string-matching on known auth-failure phrases) is a placeholder
    /// until SwiftMail exposes typed auth-error cases.  When that API ships, switch to
    /// matching on those concrete types instead of inspecting the error description.
    private func connectAndLogin(_ server: IMAPServer) async throws {
        do {
            try await server.connect()
            try await server.login(username: username, password: password)
        } catch is CancellationError {
            throw IMAPClientError.cancelled
        } catch {
            let desc = String(describing: error)
            let lower = desc.lowercased()
            let looksTransient = Self.transientPhrases.contains { lower.contains($0) }
            let looksAuth = Self.authFailurePhrases.contains { lower.contains($0) }
            if looksAuth && !looksTransient {
                throw IMAPClientError.authFailed
            }
            throw IMAPClientError.transport(underlying: desc)
        }
    }

    /// Phrases that indicate a network-level failure rather than rejected credentials.
    /// Excluded so a momentary disconnect mid-LOGIN isn't misreported as `.authFailed`.
    private static let transientPhrases: [String] = [
        "timed out", "timeout", "connection", "reset", "refused"
    ]

    /// Substrings (lowercased) that map an underlying server-error description to
    /// `IMAPClientError.authFailed`. Until SwiftMail exposes typed auth-error cases this
    /// is best-effort; covers Gmail, iCloud, Outlook, Yahoo and the Dovecot defaults.
    private static let authFailurePhrases: [String] = [
        "authentication failed", "authenticationfailed", "auth failed",
        "login failed", "invalid credentials", "bad credentials",
        "application-specific password", "web login required",
        "username and password not accepted",
        "empty username", "empty password"
    ]

    /// Maps any non-`IMAPClientError`, non-`CancellationError` thrown by `work` into
    /// `IMAPClientError.transport`.  Already-mapped `IMAPClientError` values pass through
    /// unchanged; `CancellationError` becomes `IMAPClientError.cancelled`.
    private func mapped<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let e as IMAPClientError {
            throw e
        } catch is CancellationError {
            throw IMAPClientError.cancelled
        } catch {
            throw IMAPClientError.transport(underlying: String(describing: error))
        }
    }

    /// Fetches message structure (metadata only, no attachment bytes) then pulls only
    /// the text/plain and text/html parts individually.
    ///
    /// Important-1 choice: **option (b)** — use `fetchStructure` for the list paths.
    /// SwiftMail exposes `fetchStructure(_ identifier:) -> [MessagePart]` which returns
    /// the full BODYSTRUCTURE with `data == nil` (no bytes are downloaded).  Text/HTML
    /// body parts are then fetched individually via `fetchPart(section:of:)`.  Attachment
    /// parts contribute only metadata (`partID`, `filename`, `mimeType`, `sizeBytes` from
    /// the `octets` field on the BODYSTRUCTURE leaf) — their bytes are never pulled here.
    /// Bytes are only downloaded lazily through `fetchAttachmentBytes(uid:folder:partID:)`.
    private func fetchAndParse(
        server: IMAPServer,
        info: MessageInfo,
        folder: String,
        uidValidity: UInt32
    ) async throws -> ParsedInboundMessage {
        guard let uid = info.uid else {
            // Fallback: no UID available; this message cannot be addressed stably.
            throw IMAPClientError.malformed(detail: "MessageInfo has no UID")
        }

        // 1. Fetch structure only (zero bytes downloaded for attachments).
        let structure = try await server.fetchStructure(uid)

        // 2. Collect text/plain and text/html body parts (typically <10 KB each).
        let bodyParts = structure.filter { part in
            let ct = part.contentType.lowercased()
            let disp = part.disposition?.lowercased()
            return (ct.hasPrefix("text/plain") || ct.hasPrefix("text/html"))
                && disp != "attachment"
        }

        // 3. Fetch bytes for body parts only.
        var populatedBodyParts: [MessagePart] = []
        for var part in bodyParts {
            part.data = try? await server.fetchPart(section: part.section, of: uid)
            populatedBodyParts.append(part)
        }

        // 4. Derive body strings from the populated parts.
        let plainPart = populatedBodyParts.first { $0.contentType.lowercased().hasPrefix("text/plain") }
        let htmlPart  = populatedBodyParts.first { $0.contentType.lowercased().hasPrefix("text/html") }
        var bodyPlain = plainPart?.textContent ?? ""
        let rawHTML   = htmlPart?.textContent
        let bodyHTML  = rawHTML.map { HTMLSanitizer.sanitize($0) }

        // If there's no plain-text body but HTML is available, generate a plain-text fallback
        // by stripping HTML tags. This ensures bodyPlain is never empty for HTML-only messages.
        if bodyPlain.isEmpty, let html = rawHTML {
            bodyPlain = HTMLSanitizer.plainText(from: html)
        }

        // 5. Build attachment metadata from the structure (no bytes).
        let attachments = Self.classifyAttachments(in: structure)

        return Self.parse(
            info: info,
            folder: folder,
            uidValidity: uidValidity,
            bodyPlain: bodyPlain,
            bodyHTML: bodyHTML,
            attachments: attachments
        )
    }

    /// Like `fetchAndParse` but fetches ONLY the BODYSTRUCTURE (no text-body part fetches) — used
    /// by Sent enrichment, which needs attachment metadata + uid/folder but not the body (the
    /// locally-composed outbound row already has it). Saves the N per-message text-part round-trips.
    private func fetchStructureOnly(
        server: IMAPServer,
        info: MessageInfo,
        folder: String,
        uidValidity: UInt32
    ) async throws -> ParsedInboundMessage {
        guard let uid = info.uid else {
            throw IMAPClientError.malformed(detail: "MessageInfo has no UID")
        }
        let structure = try await server.fetchStructure(uid)
        let attachments = Self.classifyAttachments(in: structure)
        return Self.parse(
            info: info,
            folder: folder,
            uidValidity: uidValidity,
            bodyPlain: "",
            bodyHTML: nil,
            attachments: attachments
        )
    }

    // MARK: - Static attachment classifier
    //
    // Promoted to a named static function so it can be exercised directly in unit tests
    // without a live IMAP connection.  Four predicates are evaluated per part:
    //   1. isExplicitAttachment — Content-Disposition: attachment
    //   2. hasFileNotInline     — has a filename and disposition != inline
    //   3. isCalendar           — text/calendar (Outlook invites often lack a filename)
    //   4. isInlineImage        — Content-Disposition: inline (or absent) + Content-ID + image/* MIME
    //
    // The fourth predicate is new (Task 2 of the inline-mail-images plan).

    static func classifyAttachments(in structure: [MessagePart]) -> [ParsedAttachmentMeta] {
        structure.compactMap { part -> ParsedAttachmentMeta? in
            let ct = part.contentType.lowercased()
            let disp = part.disposition?.lowercased()
            // The message's own text body part(s) are not attachments. Outlook/Exchange stamp the
            // HTML body with a Content-ID and a `name` and omit an "inline" disposition, which would
            // otherwise trip `hasFileNotInline` below and surface the body itself as a bogus chip.
            // Mirror `fetchAndParse`'s body selection: a text/plain or text/html part is the body
            // unless it is explicitly Content-Disposition: attachment.
            if (ct.hasPrefix("text/plain") || ct.hasPrefix("text/html")) && disp != "attachment" {
                return nil
            }
            let hasFilename = !(part.filename?.isEmpty ?? true)
            let isExplicitAttachment = disp == "attachment"
            let hasFileNotInline = hasFilename && disp != "inline"
            let isCalendar = ct.hasPrefix("text/calendar")
            // Treat empty string as nil for defensive symmetry (SwiftMail strips angle brackets
            // but may still produce an empty string for malformed Content-ID headers).
            let contentID = part.contentId.flatMap { $0.isEmpty ? nil : $0 }
            let isInlineImage = (disp == "inline" || disp == nil)
                && contentID != nil
                && ct.hasPrefix("image/")
            guard isExplicitAttachment || hasFileNotInline || isCalendar || isInlineImage else { return nil }
            return ParsedAttachmentMeta(
                partID: part.section.description,
                filename: part.suggestedFilename,
                mimeType: String(part.contentType.split(separator: ";").first ?? "application/octet-stream"),
                // data is nil here (structure-only); sizeBytes will be 0 until we add
                // BODYSTRUCTURE octet-count exposure in SwiftMail.
                sizeBytes: part.data?.count ?? 0,
                contentID: contentID
            )
        }
    }

    // MARK: - Static parsing helper
    //
    // Kept `static` so that it CAN be called with synthetic SwiftMail values in future unit tests
    // without needing a live actor / live network connection.

    /// Derives a message's stable Message-ID — server value verbatim, or a synthetic UID-based
    /// ID when the server omits one. Extracted so callers that match against locally-stored
    /// Message-IDs (the Sent enrichment gate) use byte-for-byte identical logic to `parse`.
    static func messageID(for info: MessageInfo, uidValidity: UInt32) -> String {
        if let mid = info.messageId { return mid.description }
        return MessageIDGenerator.synthesize(uid: info.uid?.value ?? 0, uidValidity: uidValidity)
    }

    static func parse(
        info: MessageInfo,
        folder: String,
        uidValidity: UInt32,
        bodyPlain: String,
        bodyHTML: String?,
        attachments: [ParsedAttachmentMeta]
    ) -> ParsedInboundMessage {
        let uid = info.uid?.value ?? 0
        let messageID = Self.messageID(for: info, uidValidity: uidValidity)

        let inReplyTo = info.inReplyTo.map { $0.description }
        let references = info.references?.map { $0.description } ?? []

        let date = info.date ?? info.internalDate ?? Date()

        return ParsedInboundMessage(
            uid: uid,
            folder: folder,
            uidValidity: uidValidity,
            messageID: messageID,
            inReplyTo: inReplyTo,
            references: references,
            fromAddress: info.from ?? "",
            // SwiftMail's MessageInfo.from is a pre-formatted address string; it does not
            // parse display names separately from the addr-spec.  fromName is always nil here.
            fromName: nil,
            toAddresses: info.to,
            ccAddresses: info.cc,
            date: date,
            subject: info.subject ?? "",
            bodyPlain: bodyPlain,
            bodyHTML: bodyHTML,
            attachments: attachments
        )
    }
}
#endif

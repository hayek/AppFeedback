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

    func listInbox(sinceUID: UInt32, fromAddresses: [String]) async throws -> [ParsedInboundMessage] {
        // No recipients yet → no replies to look for. Skip the IMAP round-trip entirely.
        if fromAddresses.isEmpty { return [] }

        let server = IMAPServer(host: host, port: port)
        try await connectAndLogin(server)
        defer { Task.detached { try? await server.disconnect() } }

        let selection = try await mapped { try await server.selectMailbox(imapInboxName) }
        let folder = imapInboxName
        let uidValidity = selection.uidValidity.value

        // Server-side filter: replies come from people we wrote to. Gmail indexes FROM
        // efficiently. Run one SEARCH per recipient and union locally — chained ORs and
        // non-ASCII quoted strings both produce `BAD Could not parse command` on Gmail,
        // so we avoid both: bare ASCII addr@domain, one SEARCH per recipient.
        let cleanedAddresses = Array(Set(fromAddresses.compactMap(MailAddress.bare)))
        if cleanedAddresses.isEmpty { return [] }
        let infos: [MessageInfo] = try await mapped {
            // SwiftMail serializes commands per IMAPServer connection, so issuing the
            // SEARCHes in parallel from a task group still walks the wire one-at-a-time
            // — but it overlaps SwiftMail's per-command processing with the next
            // network round-trip and removes the await-chain stalls between them.
            let unionUIDs: Set<UInt32> = try await withThrowingTaskGroup(
                of: [UInt32].self,
                returning: Set<UInt32>.self
            ) { group in
                for addr in cleanedAddresses {
                    group.addTask {
                        let hits: MessageIdentifierSet<UID> = try await server.search(criteria: [.from(addr)])
                        return hits.toArray().map(\.value)
                    }
                }
                var union: Set<UInt32> = []
                for try await batch in group { union.formUnion(batch) }
                return union
            }
            let unseen = unionUIDs.filter { $0 > sinceUID }
            if unseen.isEmpty { return [] }
            return try await server.fetchMessageInfosBulk(using: MessageIdentifierSet(unseen.map { UID($0) }))
        }

        var results: [ParsedInboundMessage] = []
        for info in infos {
            do {
                let parsed = try await fetchAndParse(server: server, info: info, folder: folder, uidValidity: uidValidity)
                results.append(parsed)
            } catch is CancellationError {
                throw IMAPClientError.cancelled
            } catch {
                print("[IMAPClient] Skipping message uid=\(info.uid?.value ?? 0): \(error)")
            }
        }
        return results
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

    func fetchAttachmentBytes(uid: UInt32, folder: String, partID: String) async throws -> Data {
        let server = IMAPServer(host: host, port: port)
        try await connectAndLogin(server)
        defer { Task.detached { try? await server.disconnect() } }

        try await mapped { _ = try await server.selectMailbox(folder) }

        let section = Section(partID)
        return try await mapped { try await server.fetchPart(section: section, of: UID(uid)) }
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
        let attachments: [ParsedAttachmentMeta] = structure.compactMap { part -> ParsedAttachmentMeta? in
            let ct = part.contentType.lowercased()
            let disp = part.disposition?.lowercased()
            let hasFilename = !(part.filename?.isEmpty ?? true)
            let isExplicitAttachment = disp == "attachment"
            let hasFileNotInline = hasFilename && disp != "inline"
            let isCalendar = ct.hasPrefix("text/calendar")
            guard isExplicitAttachment || hasFileNotInline || isCalendar else { return nil }
            return ParsedAttachmentMeta(
                partID: part.section.description,
                filename: part.suggestedFilename,
                mimeType: String(part.contentType.split(separator: ";").first ?? "application/octet-stream"),
                // data is nil here (structure-only); sizeBytes will be 0 until we add
                // BODYSTRUCTURE octet-count exposure in SwiftMail.
                sizeBytes: part.data?.count ?? 0
            )
        }

        return Self.parse(
            info: info,
            folder: folder,
            uidValidity: uidValidity,
            bodyPlain: bodyPlain,
            bodyHTML: bodyHTML,
            attachments: attachments
        )
    }

    // MARK: - Static parsing helper
    //
    // Kept `static` so that it CAN be called with synthetic SwiftMail values in future unit tests
    // without needing a live actor / live network connection.

    static func parse(
        info: MessageInfo,
        folder: String,
        uidValidity: UInt32,
        bodyPlain: String,
        bodyHTML: String?,
        attachments: [ParsedAttachmentMeta]
    ) -> ParsedInboundMessage {
        let uid = info.uid?.value ?? 0

        // Synthesise a Message-ID when the server didn't provide one
        let messageID: String
        if let mid = info.messageId {
            messageID = mid.description
        } else {
            messageID = MessageIDGenerator.synthesize(uid: uid, uidValidity: uidValidity)
        }

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

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

// MARK: - Actor

actor IMAPClient: IMAPClientProtocol {

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

    func listInbox(sinceUID: UInt32) async throws -> [ParsedInboundMessage] {
        let server = IMAPServer(host: host, port: port)
        try await connectAndLogin(server)
        defer { Task.detached { try? await server.disconnect() } }

        let selection = try await mapped { try await server.selectMailbox("INBOX") }
        let folder = "INBOX"
        let uidValidity = selection.uidValidity.value

        // Always use UID-based fetching: UIDs are stable across sessions whereas
        // sequence numbers are session-relative and must not be stored or compared.
        let infos: [MessageInfo] = try await mapped {
            if sinceUID == 0 {
                // "All messages" — UID 1 through the highest assigned UID.
                return try await server.fetchMessageInfos(uidRange: UID(1)...UID.latest)
            } else {
                // Strict UID > sinceUID
                let fromUID = UID(sinceUID + 1)
                return try await server.fetchMessageInfos(uidRange: fromUID...UID.latest)
            }
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

        let infos: [MessageInfo] = try await mapped {
            try await server.fetchMessageInfosBulk(using: matchingUIDs)
        }

        var results: [ParsedInboundMessage] = []
        for info in infos {
            do {
                let parsed = try await fetchAndParse(server: server, info: info, folder: folder, uidValidity: uidValidity)
                results.append(parsed)
            } catch is CancellationError {
                throw IMAPClientError.cancelled
            } catch {
                print("[IMAPClient] Skipping sent message uid=\(info.uid?.value ?? 0): \(error)")
            }
        }
        return results
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
            // Exclude transient transport phrases so we don't misclassify network blips as auth errors.
            let looksTransient = lower.contains("timed out") || lower.contains("timeout")
                || lower.contains("connection") || lower.contains("reset") || lower.contains("refused")
            let looksAuth = lower.contains("authentication failed") || lower.contains("auth failed")
                || lower.contains("login failed") || lower.contains("invalid credentials")
                || lower.contains("bad credentials")
            if looksAuth && !looksTransient {
                throw IMAPClientError.authFailed
            }
            // Fall through: classified as .transport (catches network-level errors)
            throw IMAPClientError.transport(underlying: desc)
        }
    }

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

        // I10: If there's no plain-text body but HTML is available, generate a plain-text fallback
        // by stripping HTML tags. This ensures bodyPlain is never empty for HTML-only messages.
        if bodyPlain.isEmpty, let html = rawHTML {
            let reOpts: String.CompareOptions = [.regularExpression, .caseInsensitive]
            bodyPlain = html
                .replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: " ", options: reOpts)
                .replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: " ", options: reOpts)
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: reOpts)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .trimmingCharacters(in: .whitespacesAndNewlines)
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

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

// MARK: - Protocol

/// Protocol so Task 5's MailSyncCoordinator can swap in a mock.
protocol IMAPClientProtocol: Sendable {
    /// Returns messages from INBOX whose UID is strictly greater than `sinceUID`.
    /// Pass 0 to fetch everything.
    func listInbox(sinceUID: UInt32) async throws -> [ParsedInboundMessage]

    /// Returns messages from the Sent folder with an internal date on or after `sinceDate`.
    func listSent(sinceDate: Date) async throws -> [ParsedInboundMessage]

    /// Lazily fetches raw bytes for a single attachment part.
    func fetchAttachmentBytes(uid: UInt32, folder: String, partID: String) async throws -> Data

    /// Opens, authenticates, and immediately disconnects — useful for the "Test Connection" button.
    func testConnection() async throws
}

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
        defer { Task { try? await server.disconnect() } }

        let selection = try await server.selectMailbox("INBOX")
        let folder = "INBOX"
        let uidValidity = selection.uidValidity.value

        let infos: [MessageInfo]
        if sinceUID == 0 {
            // Fetch all: use a broad sequence range
            infos = try await server.fetchMessageInfos(sequenceRange: SequenceNumber(1)...SequenceNumber.latest)
        } else {
            // UID strictly greater than sinceUID
            let fromUID = UID(sinceUID + 1)
            infos = try await server.fetchMessageInfos(uidRange: fromUID...UID.latest)
        }

        var results: [ParsedInboundMessage] = []
        for info in infos {
            do {
                let msg = try await server.fetchMessage(from: info)
                let parsed = Self.parse(message: msg, info: info, folder: folder, uidValidity: uidValidity)
                results.append(parsed)
            } catch {
                print("[IMAPClient] Skipping message uid=\(info.uid?.value ?? 0): \(error)")
            }
        }
        return results
    }

    func listSent(sinceDate: Date) async throws -> [ParsedInboundMessage] {
        let server = IMAPServer(host: host, port: port)
        try await connectAndLogin(server)
        defer { Task { try? await server.disconnect() } }

        // Discover the sent folder via SwiftMail's special-use + name fallback logic
        let mailboxes = try await server.listMailboxes()
        guard let sentMailbox = mailboxes.sent else {
            throw IMAPClientError.malformed(detail: "No Sent folder found on server")
        }
        let folder = sentMailbox.name

        let selection = try await server.selectMailbox(folder)
        let uidValidity = selection.uidValidity.value

        // IMAP SINCE is date-granular; we use sentSince (Date: header) as a best-effort filter.
        let matchingUIDs: MessageIdentifierSet<UID> = try await server.search(
            criteria: [.sentSince(sinceDate)]
        )

        if matchingUIDs.isEmpty { return [] }

        let infos: [MessageInfo] = try await server.fetchMessageInfosBulk(using: matchingUIDs)

        var results: [ParsedInboundMessage] = []
        for info in infos {
            do {
                let msg = try await server.fetchMessage(from: info)
                let parsed = Self.parse(message: msg, info: info, folder: folder, uidValidity: uidValidity)
                results.append(parsed)
            } catch {
                print("[IMAPClient] Skipping sent message uid=\(info.uid?.value ?? 0): \(error)")
            }
        }
        return results
    }

    func fetchAttachmentBytes(uid: UInt32, folder: String, partID: String) async throws -> Data {
        let server = IMAPServer(host: host, port: port)
        try await connectAndLogin(server)
        defer { Task { try? await server.disconnect() } }

        _ = try await server.selectMailbox(folder)

        let section = Section(partID)
        let data = try await server.fetchPart(section: section, of: UID(uid))
        return data
    }

    func testConnection() async throws {
        let server = IMAPServer(host: host, port: port)
        try await connectAndLogin(server)
        try? await server.disconnect()
    }

    // MARK: - Private helpers

    private func connectAndLogin(_ server: IMAPServer) async throws {
        do {
            try await server.connect()
            try await server.login(username: username, password: password)
        } catch {
            let desc = String(describing: error)
            if desc.lowercased().contains("auth") || desc.lowercased().contains("login") {
                throw IMAPClientError.authFailed
            }
            throw IMAPClientError.transport(underlying: desc)
        }
    }

    // MARK: - Static parsing helper
    //
    // Kept `static` so that it CAN be called with synthetic SwiftMail values in future unit tests
    // without needing a live actor / live network connection.

    static func parse(
        message: Message,
        info: MessageInfo,
        folder: String,
        uidValidity: UInt32
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

        // Sanitise HTML before returning — callers must not have to remember this.
        let rawHTML = message.htmlBody
        let bodyHTML = rawHTML.map { HTMLSanitizer.sanitize($0) }

        let attachments: [ParsedAttachmentMeta] = message.attachments.map { part in
            ParsedAttachmentMeta(
                partID: part.section.description,
                filename: part.suggestedFilename,
                mimeType: String(part.contentType.split(separator: ";").first ?? "application/octet-stream"),
                sizeBytes: part.data?.count ?? 0
            )
        }

        return ParsedInboundMessage(
            uid: uid,
            folder: folder,
            uidValidity: uidValidity,
            messageID: messageID,
            inReplyTo: inReplyTo,
            references: references,
            fromAddress: info.from ?? "",
            fromName: nil,
            toAddresses: info.to,
            ccAddresses: info.cc,
            date: date,
            subject: info.subject ?? "(no subject)",
            bodyPlain: message.textBody ?? "",
            bodyHTML: bodyHTML,
            attachments: attachments
        )
    }
}
#endif

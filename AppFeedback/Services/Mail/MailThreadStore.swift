import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class MailThreadStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Resolution enum

    private enum Resolution {
        case existingHeader(MailThread)
        case existingReferences(MailThread)
        case new(MailThread)
    }

    // MARK: - recordOutbound

    @discardableResult
    func recordOutbound(
        messageID: String,
        repoOwner: String, repoName: String, issueNumber: Int,
        from: String, fromName: String?,
        to: [String], cc: [String],
        subject: String, bodyPlain: String, bodyHTML: String?,
        date: Date,
        replyHeaders: ReplyHeaderBuilder.Output?
    ) -> MailMessage {
        // Dedupe: return existing message if messageID already stored
        if let existing = findMessage(byMessageID: messageID) {
            return existing
        }

        // Determine which thread to append to (header-based lookup)
        let resolution = resolveThread(
            inReplyTo: replyHeaders?.inReplyTo,
            references: replyHeaders?.references ?? [],
            fallback: {
                // Create new thread
                let newThread = MailThread(
                    messageIDRoot: messageID,
                    subject: subject,
                    lastMessageAt: date,
                    issueRepoOwner: issueNumber > 0 ? repoOwner : "",
                    issueRepoName: issueNumber > 0 ? repoName : "",
                    issueNumber: issueNumber > 0 ? issueNumber : 0,
                    matchSourceRaw: MailThread.MatchSource.direct.rawValue
                )
                self.context.insert(newThread)
                return newThread
            }
        )

        let thread: MailThread
        switch resolution {
        case .existingHeader(let t):
            // Matched via inReplyTo — leave matchSource as previously set
            thread = t
        case .existingReferences(let t):
            // Matched via references chain — upgrade matchSource to .header if currently .direct
            if t.matchSource == .direct {
                t.matchSource = .header
            }
            thread = t
        case .new(let t):
            // New thread created in fallback — matchSource already set to .direct
            thread = t
        }

        // Update thread metadata
        thread.lastMessageAt = max(thread.lastMessageAt, date)
        let newParticipants = ([from] + to + cc).filter { !$0.isEmpty }
        thread.participants = unionPreservingOrder(thread.participants, newParticipants)

        // Build the new message
        let msg = MailMessage(
            messageID: messageID,
            inReplyTo: replyHeaders?.inReplyTo,
            references: replyHeaders?.references.joined(separator: "\n") ?? "",
            fromAddress: from,
            fromName: fromName,
            toAddresses: to,
            ccAddresses: cc,
            date: date,
            subject: subject,
            bodyPlain: bodyPlain,
            bodyHTML: bodyHTML,
            directionRaw: MailMessage.Direction.outbound.rawValue,
            thread: thread
        )
        context.insert(msg)

        do {
            try context.save()
        } catch {
            assertionFailure("MailThreadStore save failed: \(error)")
        }
        return msg
    }

    // MARK: - recordInbound

    @discardableResult
    func recordInbound(message: ParsedInboundMessage) -> MailMessage? {
        // Dedupe: skip if messageID already exists
        if findMessage(byMessageID: message.messageID) != nil {
            return nil
        }

        // Determine thread via direct header lookup first, then subject fallback via ThreadMatcher.
        var headerResolution: Resolution? = nil
        let resolution = resolveThread(
            inReplyTo: message.inReplyTo,
            references: message.references,
            fallback: {
                // Header-based lookup found nothing — attempt subject fallback using ThreadMatcher.
                // Only try fallback when the message looks like a reply (Re:/Fwd: prefix).
                let looksLikeReply = message.subject.range(
                    of: #"^\s*(?:Re|Fwd|Fw)\s*:"#,
                    options: [.regularExpression, .caseInsensitive]
                ) != nil

                if looksLikeReply {
                    let recentThreads = self.recentThreadsForFallback(limit: 200)
                    let candidates: [ThreadMatcher.Candidate] = recentThreads.map { thread in
                        ThreadMatcher.Candidate(
                            messageID: thread.messageIDRoot,
                            subject: thread.subject,
                            participants: thread.participants,
                            lastMessageAt: thread.lastMessageAt
                        )
                    }
                    let result = ThreadMatcher.attach(message: message, existing: candidates)
                    switch result {
                    case .header(let i):
                        let matched = recentThreads[i]
                        matched.matchSource = .header
                        headerResolution = .existingHeader(matched)
                        return matched
                    case .subject(let i):
                        let matched = recentThreads[i]
                        matched.matchSource = .subjectFallback
                        headerResolution = .existingHeader(matched)
                        return matched
                    case .newThread:
                        break
                    }
                }

                // Create orphan thread — issueNumber = 0, matchSource = .direct (placeholder)
                let newThread = MailThread(
                    messageIDRoot: message.messageID,
                    subject: message.subject,
                    lastMessageAt: message.date,
                    issueRepoOwner: "",
                    issueRepoName: "",
                    issueNumber: 0,
                    matchSourceRaw: MailThread.MatchSource.direct.rawValue
                )
                self.context.insert(newThread)
                return newThread
            }
        )

        // If ThreadMatcher already set the resolution inside the fallback, use it directly.
        let finalResolution = headerResolution ?? resolution

        let thread: MailThread
        switch finalResolution {
        case .existingHeader(let t):
            // Matched via inReplyTo or subject fallback — matchSource already set above.
            thread = t
        case .existingReferences(let t):
            // Matched via references chain — set matchSource to .header
            t.matchSource = .header
            thread = t
        case .new(let t):
            // New orphan thread — matchSource already .direct (placeholder)
            thread = t
        }

        // Update thread metadata
        thread.lastMessageAt = max(thread.lastMessageAt, message.date)
        let newParticipants = ([message.fromAddress] + message.toAddresses + message.ccAddresses)
            .filter { !$0.isEmpty }
        thread.participants = unionPreservingOrder(thread.participants, newParticipants)

        // Build message
        let msg = MailMessage(
            messageID: message.messageID,
            inReplyTo: message.inReplyTo,
            references: message.references.joined(separator: "\n"),
            fromAddress: message.fromAddress,
            fromName: message.fromName,
            toAddresses: message.toAddresses,
            ccAddresses: message.ccAddresses,
            date: message.date,
            subject: message.subject,
            bodyPlain: message.bodyPlain,
            bodyHTML: message.bodyHTML,
            directionRaw: MailMessage.Direction.inbound.rawValue,
            uid: Int(message.uid),
            folder: message.folder,
            thread: thread
        )
        context.insert(msg)

        // Create MailAttachment rows for each parsed attachment
        for meta in message.attachments {
            let attachment = MailAttachment(
                messageID: message.messageID,
                partID: meta.partID,
                filename: meta.filename,
                mimeType: meta.mimeType,
                sizeBytes: meta.sizeBytes,
                message: msg
            )
            context.insert(attachment)
        }

        do {
            try context.save()
        } catch {
            assertionFailure("MailThreadStore save failed: \(error)")
        }
        return msg
    }

    // MARK: - threads(forIssue:)

    func threads(forIssue issue: (owner: String, repo: String, number: Int)) -> [MailThread] {
        let owner = issue.owner
        let repo = issue.repo
        let number = issue.number
        let descriptor = FetchDescriptor<MailThread>(
            predicate: #Predicate {
                $0.issueRepoOwner == owner &&
                $0.issueRepoName == repo &&
                $0.issueNumber == number
            },
            sortBy: [SortDescriptor(\.lastMessageAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Private helpers

    /// Returns up to `limit` threads sorted by lastMessageAt descending, used for subject fallback.
    private func recentThreadsForFallback(limit: Int) -> [MailThread] {
        var descriptor = FetchDescriptor<MailThread>(
            sortBy: [SortDescriptor(\.lastMessageAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    private func findMessage(byMessageID messageID: String) -> MailMessage? {
        var descriptor = FetchDescriptor<MailMessage>(
            predicate: #Predicate { $0.messageID == messageID }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Resolve a thread from inReplyTo / references headers, or call `fallback` to create a new one.
    private func resolveThread(
        inReplyTo: String?,
        references: [String],
        fallback: () -> MailThread
    ) -> Resolution {
        // 1. Check inReplyTo against any stored MailMessage.messageID
        if let inReplyTo, !inReplyTo.isEmpty,
           let parent = findMessage(byMessageID: inReplyTo),
           let parentThread = parent.thread {
            return .existingHeader(parentThread)
        }

        // 2. Walk references chain — one predicated fetch per reference ID, early-return on first hit
        //    Pick the thread of the newest matching message across all references.
        if !references.isEmpty {
            let candidates = references.compactMap { findMessage(byMessageID: $0) }
            if let newest = candidates.max(by: { $0.date < $1.date }),
               let thread = newest.thread {
                return .existingReferences(thread)
            }
        }

        // 3. No match — invoke fallback to create a new thread
        return .new(fallback())
    }

    /// Merge `additions` into `base`, preserving insertion order and skipping duplicates.
    private func unionPreservingOrder(_ base: [String], _ additions: [String]) -> [String] {
        var seen = Set(base)
        var result = base
        for item in additions {
            if seen.insert(item).inserted {
                result.append(item)
            }
        }
        return result
    }
}

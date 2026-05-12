import Foundation
import SwiftData
import Observation

// MARK: - MailAttachmentLocalStore

/// @MainActor wrapper that owns all SwiftData reads/writes for MailAttachmentLocal.
/// Mirrors the pattern used by MailAccountLocalStateStore so the actor-isolated
/// AttachmentDownloader can hop to MainActor for persistence without Sendable issues.
@MainActor
@Observable
final class MailAttachmentLocalStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func fetchLocalPath(messageID: String, partID: String) -> String? {
        var descriptor = FetchDescriptor<MailAttachmentLocal>(
            predicate: #Predicate { $0.messageID == messageID && $0.partID == partID }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).first)?.localPath
    }

    /// Upsert: replace any existing row with the same (messageID, partID), insert fresh.
    func record(messageID: String, partID: String, localPath: String) {
        if let existing = try? context.fetch(
            FetchDescriptor<MailAttachmentLocal>(
                predicate: #Predicate { $0.messageID == messageID && $0.partID == partID }
            )
        ).first {
            context.delete(existing)
        }
        let row = MailAttachmentLocal(
            messageID: messageID,
            partID: partID,
            localPath: localPath,
            downloadedAt: Date()
        )
        context.insert(row)
        do {
            try context.save()
        } catch {
            assertionFailure("MailAttachmentLocalStore save failed: \(error)")
        }
    }
}

// MARK: - AttachmentDownloaderHolder

/// Observable wrapper so SwiftUI can inject AttachmentDownloader via @Environment.
/// Actors don't conform to Observable, so we wrap the reference here.
/// Task 12 will replace the nil placeholder with a real downloader once IMAPClient is wired.
@Observable
final class AttachmentDownloaderHolder {
    let downloader: AttachmentDownloader?
    init(_ downloader: AttachmentDownloader?) { self.downloader = downloader }
}

// MARK: - AttachmentDownloader

actor AttachmentDownloader {
    private let client: IMAPClientProtocol
    private let localStore: MailAttachmentLocalStore

    init(client: IMAPClientProtocol, localStore: MailAttachmentLocalStore) {
        self.client = client
        self.localStore = localStore
    }

    enum DownloadError: Error, Equatable {
        case writeFailed
        case folderUnavailable
    }

    /// Returns the URL to the downloaded file. Idempotent — repeat calls with the same
    /// (messageID, partID) return the existing local path if the file still exists on disk.
    func download(
        messageID: String,
        uid: UInt32,
        folder: String,
        partID: String,
        filename: String,
        folderBookmark: Data?
    ) async throws -> URL {
        // 1. Check for an existing local record.
        let existingPath = await MainActor.run { localStore.fetchLocalPath(messageID: messageID, partID: partID) }
        if let path = existingPath {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            // File gone from disk — fall through to re-download.
        }

        // 2. Resolve destination directory.
        let (dir, scoped) = AttachmentFolder.resolveDestination(bookmarkData: folderBookmark)
        defer { if scoped { dir.stopAccessingSecurityScopedResource() } }

        guard AttachmentFolder.ensureExists(dir) else {
            throw DownloadError.folderUnavailable
        }

        // 3. Fetch bytes via IMAP.
        let bytes = try await client.fetchAttachmentBytes(uid: uid, folder: folder, partID: partID)

        // 4. Write atomically; handle filename collisions.
        let destURL = uniqueURL(in: dir, preferredFilename: filename)
        do {
            try bytes.write(to: destURL, options: .atomic)
        } catch {
            throw DownloadError.writeFailed
        }

        // 5. Record MailAttachmentLocal.
        await MainActor.run {
            localStore.record(messageID: messageID, partID: partID, localPath: destURL.path)
        }
        return destURL
    }

    nonisolated private func uniqueURL(in dir: URL, preferredFilename: String) -> URL {
        let base = dir.appendingPathComponent(preferredFilename)
        if !FileManager.default.fileExists(atPath: base.path) { return base }
        let ext = base.pathExtension
        let stem = base.deletingPathExtension().lastPathComponent
        var n = 1
        while true {
            // Avoid trailing dot when there is no extension.
            let candidate: URL
            if ext.isEmpty {
                candidate = dir.appendingPathComponent("\(stem) (\(n))")
            } else {
                candidate = dir.appendingPathComponent("\(stem) (\(n))").appendingPathExtension(ext)
            }
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}

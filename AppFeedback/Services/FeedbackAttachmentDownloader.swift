import Foundation
import SwiftData
import Observation
import CryptoKit

@MainActor
@Observable
final class FeedbackAttachmentLocalStore {
    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    func fetchLocalPath(url: String) -> String? {
        var d = FetchDescriptor<FeedbackAttachmentLocal>(predicate: #Predicate { $0.url == url })
        d.fetchLimit = 1
        return (try? context.fetch(d).first)?.localPath
    }

    func record(url: String, localPath: String) {
        if let existing = try? context.fetch(
            FetchDescriptor<FeedbackAttachmentLocal>(predicate: #Predicate { $0.url == url })
        ).first {
            context.delete(existing)
        }
        context.insert(FeedbackAttachmentLocal(url: url, localPath: localPath, downloadedAt: Date()))
        do { try context.save() } catch {
            assertionFailure("FeedbackAttachmentLocalStore save failed: \(error)")
        }
    }
}

@Observable
final class FeedbackAttachmentDownloaderHolder {
    let downloader: FeedbackAttachmentDownloader?
    init(_ downloader: FeedbackAttachmentDownloader?) { self.downloader = downloader }
}

actor FeedbackAttachmentDownloader {

    private let session: URLSession
    private let localStore: FeedbackAttachmentLocalStore
    private let tokenProvider: @Sendable () -> String?

    init(session: URLSession, localStore: FeedbackAttachmentLocalStore, tokenProvider: @escaping @Sendable () -> String?) {
        self.session = session
        self.localStore = localStore
        self.tokenProvider = tokenProvider
    }

    enum DownloadError: Error, Equatable {
        case writeFailed
        case unsupportedURL
        case httpStatus(Int)
    }

    func download(url: URL, filename: String) async throws -> URL {
        let key = url.absoluteString

        // 1. Cache hit?
        if let path = await MainActor.run(body: { localStore.fetchLocalPath(url: key) }) {
            let onDisk = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: onDisk.path) {
                return onDisk
            }
        }

        // 2. Decide fetch endpoint.
        let request = try buildRequest(for: url)

        // 3. Fetch
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.httpStatus(0)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DownloadError.httpStatus(http.statusCode)
        }

        // 4. Write to cache dir under url-sha256/filename
        let dir = try resolveCacheDir(for: url)
        let dest = dir.appendingPathComponent(filename)
        do {
            try data.write(to: dest, options: .atomic)
        } catch {
            throw DownloadError.writeFailed
        }

        // 5. Record
        await MainActor.run { localStore.record(url: key, localPath: dest.path) }
        return dest
    }

    private func buildRequest(for url: URL) throws -> URLRequest {
        if url.host == "raw.githubusercontent.com", let parsed = parseRawGitHubURL(url) {
            // Re-route through the Contents API so private repos work.
            let path = "/repos/\(parsed.owner)/\(parsed.repo)/contents/\(parsed.path)"
            guard var comps = URLComponents(string: "https://api.github.com\(path)") else { throw DownloadError.unsupportedURL }
            comps.queryItems = [URLQueryItem(name: "ref", value: parsed.branch)]
            guard let apiURL = comps.url else { throw DownloadError.unsupportedURL }
            var req = URLRequest(url: apiURL)
            req.httpMethod = "GET"
            req.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
            if let token = tokenProvider() {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            return req
        }
        // External URL — fetch directly.
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        return req
    }

    private struct RawGitHubURLParts { let owner: String; let repo: String; let branch: String; let path: String }
    private func parseRawGitHubURL(_ url: URL) -> RawGitHubURLParts? {
        // /<owner>/<repo>/<branch>/<...path>
        let parts = url.path.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4 else { return nil }
        return RawGitHubURLParts(
            owner: String(parts[0]),
            repo: String(parts[1]),
            branch: String(parts[2]),
            path: String(parts[3])
        )
    }

    private func resolveCacheDir(for url: URL) throws -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("FeedbackAttachments/\(hex)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

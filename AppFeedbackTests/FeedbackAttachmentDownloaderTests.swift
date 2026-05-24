import XCTest
import SwiftData
@testable import AppFeedback

final class FeedbackAttachmentDownloaderTests: XCTestCase {

    override func setUp() { super.setUp(); FeedbackURLProtocolStub.reset() }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FeedbackURLProtocolStub.self]
        return URLSession(configuration: config)
    }

    @MainActor
    private func makeStore() -> FeedbackAttachmentLocalStore {
        let schema = Schema([FeedbackAttachmentLocal.self])
        let container = try! ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        return FeedbackAttachmentLocalStore(context: ModelContext(container))
    }

    @MainActor
    func test_first_download_writes_file_and_records_path() async throws {
        let bytes = Data("hello".utf8)
        FeedbackURLProtocolStub.respond { req in
            // Inbox downloader routes raw.githubusercontent.com via the Contents API.
            XCTAssertEqual(req.url?.host, "api.github.com")
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                bytes
            )
        }
        let store = makeStore()
        let downloader = FeedbackAttachmentDownloader(
            session: makeSession(),
            localStore: store,
            tokenProvider: { "test-token" }
        )
        let raw = URL(string: "https://raw.githubusercontent.com/o/r/feedback-attachments/attachments/abc/shot.png")!
        let path = try await downloader.download(url: raw, filename: "shot.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(try Data(contentsOf: path), bytes)
        XCTAssertNotNil(store.fetchLocalPath(url: raw.absoluteString))
    }

    @MainActor
    func test_second_call_returns_cached_path_without_hitting_network() async throws {
        FeedbackURLProtocolStub.enqueue([
            { req in
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                 Data("hello".utf8))
            },
            { _ in XCTFail("should not be called twice"); return (HTTPURLResponse(), Data()) }
        ])
        let store = makeStore()
        let downloader = FeedbackAttachmentDownloader(
            session: makeSession(),
            localStore: store,
            tokenProvider: { "t" }
        )
        let raw = URL(string: "https://raw.githubusercontent.com/o/r/feedback-attachments/attachments/abc/shot.png")!
        _ = try await downloader.download(url: raw, filename: "shot.png")
        _ = try await downloader.download(url: raw, filename: "shot.png")
    }
}

// Lightweight URL stub local to this test target. See SDK's URLProtocolStub for the
// reference implementation; we duplicate (small) instead of vending across packages.
final class FeedbackURLProtocolStub: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) -> (HTTPURLResponse, Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var single: Handler?
    nonisolated(unsafe) private static var queue: [Handler] = []
    static func respond(_ h: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }; single = h; queue = []
    }
    static func enqueue(_ hs: [Handler]) {
        lock.lock(); defer { lock.unlock() }; single = nil; queue = hs
    }
    static func reset() { lock.lock(); defer { lock.unlock() }; single = nil; queue = [] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let h = Self.single ?? (Self.queue.isEmpty ? nil : Self.queue.removeFirst())
        Self.lock.unlock()
        guard let h else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        let (r, d) = h(request)
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: d)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

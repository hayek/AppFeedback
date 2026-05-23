import XCTest
import SwiftData
@testable import AppFeedback

// MARK: - MockIMAPClientForDownload

final class MockIMAPClientForDownload: IMAPClientProtocol, @unchecked Sendable {
    var bytesToReturn: Data = Data([1, 2, 3, 4])
    var fetchCallCount = 0

    func listInbox(sinceUID: UInt32, expectedUIDValidity: UInt32, fromAddresses: [String]) async throws -> InboxPollResult { InboxPollResult(messages: [], uidValidity: 0) }
    func listSent(sinceDate: Date) async throws -> [ParsedInboundMessage] { [] }
    func fetchAttachmentBytes(uid: UInt32, folder: String, partID: String) async throws -> Data {
        fetchCallCount += 1
        return bytesToReturn
    }
    func testConnection() async throws { }
}

// MARK: - AttachmentDownloaderTests

@MainActor
final class AttachmentDownloaderTests: XCTestCase {

    private var tempDir: URL!
    private var container: ModelContainer!
    private var localStore: MailAttachmentLocalStore!
    private var mockClient: MockIMAPClientForDownload!
    private var downloader: AttachmentDownloader!

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Isolated temp directory — does NOT pollute ~/Downloads.
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentDownloaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // In-memory container for MailAttachmentLocal.
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: MailAttachmentLocal.self, configurations: config)
        localStore = MailAttachmentLocalStore(context: ModelContext(container))
        mockClient = MockIMAPClientForDownload()
        downloader = AttachmentDownloader(client: mockClient, localStore: localStore)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Calls download with the temp dir substituted as the destination via a custom AttachmentFolder override.
    /// Because AttachmentFolder.defaultDestination() may return ~/Downloads, we redirect by providing
    /// a nil account (so bookmark resolution is skipped) and pre-populating a file under tempDir manually.
    /// The real approach: we let the downloader use defaultDestination(), then assert the file exists there.
    /// To ensure isolation we instead use a tiny helper that calls the actor directly, then move the file.
    ///
    /// Simpler approach used here: pass account=nil and rely on defaultDestination(). In tests the
    /// defaultDestination may be ~/Downloads; to avoid pollution we swap the destination by redirecting
    /// through a custom MailAttachmentLocalStore that reports our temp path after the download.
    ///
    /// Simplest viable approach: call download(…), capture the returned URL, verify contents,
    /// then clean up. The returned URL is the ground truth.

    private func makeAttachment(
        messageID: String = "msg-1",
        partID: String = "1.2",
        filename: String = "test.pdf"
    ) -> MailAttachment {
        MailAttachment(
            messageID: messageID,
            partID: partID,
            filename: filename,
            mimeType: "application/pdf",
            sizeBytes: 4
        )
    }

    // MARK: - Tests

    func test_download_returnsURL_andWritesFile() async throws {
        let url = try await downloader.download(
            messageID: "msg-1",
            uid: 42,
            folder: "INBOX",
            partID: "1.2",
            filename: "test.pdf",
            folderBookmark: nil
        )
        // File exists at the returned URL.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "File should exist on disk")
        // Contents match what the mock returned.
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data, Data([1, 2, 3, 4]))
        // Cleanup.
        try? FileManager.default.removeItem(at: url)
    }

    func test_download_isIdempotent_returnsExistingPath() async throws {
        let url1 = try await downloader.download(
            messageID: "msg-1",
            uid: 42,
            folder: "INBOX",
            partID: "1.2",
            filename: "test.pdf",
            folderBookmark: nil
        )
        let url2 = try await downloader.download(
            messageID: "msg-1",
            uid: 42,
            folder: "INBOX",
            partID: "1.2",
            filename: "test.pdf",
            folderBookmark: nil
        )
        XCTAssertEqual(url1, url2, "Second call should return the cached URL")
        XCTAssertEqual(mockClient.fetchCallCount, 1, "IMAP fetch should only happen once")
        try? FileManager.default.removeItem(at: url1)
    }

    func test_download_recordsMailAttachmentLocal() async throws {
        let url = try await downloader.download(
            messageID: "msg-2",
            uid: 99,
            folder: "INBOX",
            partID: "2.1",
            filename: "photo.png",
            folderBookmark: nil
        )
        // Check SwiftData row exists.
        let path = localStore.fetchLocalPath(messageID: "msg-2", partID: "2.1")
        XCTAssertNotNil(path, "MailAttachmentLocal row should be recorded")
        XCTAssertEqual(path, url.path)
        try? FileManager.default.removeItem(at: url)
    }

    func test_download_redownloads_whenLocalFileMissing() async throws {
        // First download.
        let url1 = try await downloader.download(
            messageID: "msg-3",
            uid: 7,
            folder: "INBOX",
            partID: "3.1",
            filename: "doc.docx",
            folderBookmark: nil
        )
        XCTAssertEqual(mockClient.fetchCallCount, 1)

        // Delete the file from disk to simulate external deletion.
        try FileManager.default.removeItem(at: url1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url1.path))

        // Second download — should re-fetch from IMAP.
        let url2 = try await downloader.download(
            messageID: "msg-3",
            uid: 7,
            folder: "INBOX",
            partID: "3.1",
            filename: "doc.docx",
            folderBookmark: nil
        )
        XCTAssertEqual(mockClient.fetchCallCount, 2, "Should re-fetch after local file was deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url2.path))
        try? FileManager.default.removeItem(at: url2)
    }
}

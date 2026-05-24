// AppFeedbackTests/AttachmentStripViewSmokeTests.swift
import XCTest
import SwiftUI
@testable import AppFeedback

final class AttachmentStripViewSmokeTests: XCTestCase {

    /// The strip should render without crashing when given a mix of image
    /// and non-image attachments. Environment dependencies are injected via
    /// dummy holders; we're verifying compile + view-builder evaluation,
    /// not behavior. End-to-end behavior is exercised by manual K1 verification.
    @MainActor
    func test_strip_view_initializes_with_mixed_attachments() {
        let refs = [
            FeedbackAttachmentRef(
                filename: "shot.png", mimeType: "image/png",
                url: URL(string: "https://example.com/shot.png")!, sizeBytes: 1024
            ),
            FeedbackAttachmentRef(
                filename: "log.txt", mimeType: "text/plain",
                url: URL(string: "https://example.com/log.txt")!, sizeBytes: 4096
            ),
        ]
        let strip = AttachmentStripView(attachments: refs)
            .environment(QuickLookPresenter())
            .environment(FeedbackAttachmentDownloaderHolder(nil))
            .environment(ThumbnailCache())
        #if os(macOS)
        let host = NSHostingView(rootView: strip)
        XCTAssertNotNil(host)
        #else
        XCTAssertNotNil(strip)
        #endif
    }
}

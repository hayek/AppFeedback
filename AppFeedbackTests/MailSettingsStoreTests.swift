import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class MailSettingsStoreTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([MailSettings.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    func test_emptyStoreReturnsSettingsWithDefaults() throws {
        let ctx = try makeContext()
        let store = MailSettingsStore(context: ctx)
        XCTAssertEqual(store.settings.templateHeaderHTML, "")
        XCTAssertEqual(store.settings.templateFooterHTML, "")
        XCTAssertEqual(store.settings.pollIntervalSeconds, 300)
        XCTAssertNil(store.settings.attachmentFolderBookmark)
    }

    func test_updatePersistsAcrossStoreInstances() throws {
        let ctx = try makeContext()
        let store = MailSettingsStore(context: ctx)
        store.update { s in
            s.templateHeaderHTML = "<p>Hi</p>"
            s.pollIntervalSeconds = 600
        }
        let reload = MailSettingsStore(context: ctx)
        XCTAssertEqual(reload.settings.templateHeaderHTML, "<p>Hi</p>")
        XCTAssertEqual(reload.settings.pollIntervalSeconds, 600)
    }

    func test_singletonInvariantIfMultipleRowsExist() throws {
        let ctx = try makeContext()
        ctx.insert(MailSettings(templateHeaderHTML: "old", createdAt: Date(timeIntervalSince1970: 1)))
        ctx.insert(MailSettings(templateHeaderHTML: "new", createdAt: Date(timeIntervalSince1970: 2)))
        try ctx.save()
        let store = MailSettingsStore(context: ctx)
        // Coalesces to oldest by createdAt.
        XCTAssertEqual(store.settings.templateHeaderHTML, "old")
        // Other rows are deleted.
        let count = try ctx.fetch(FetchDescriptor<MailSettings>()).count
        XCTAssertEqual(count, 1)
    }
}

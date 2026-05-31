import XCTest
import SwiftUI
import SwiftData
@testable import AppFeedback

@MainActor
final class VersionsSectionSmokeTests: XCTestCase {
    private func makeStore() throws -> VersionStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ProjectVersion.self, SentReleaseNotification.self, configurations: config)
        return VersionStore(context: ModelContext(container))
    }
    func testRendersWithoutCrash() throws {
        let store = try makeStore()
        store.create(repoOwner: "o", repoName: "r", name: "1.0.0", changelog: "x")
        let view = VersionsSectionView(repo: RepoConfig(displayName: "P", owner: "o", repo: "r"),
            inspector: ProjectInspectorModel(), versionStore: store,
            onCreateVersion: {}, onOpenVersion: { _ in })
        #if os(macOS)
        let host = NSHostingView(rootView: view)
        XCTAssertNotNil(host)
        #else
        XCTAssertNotNil(view)
        #endif
    }
}

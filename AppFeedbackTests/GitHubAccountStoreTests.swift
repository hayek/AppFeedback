import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class GitHubAccountStoreTests: XCTestCase {

    private func makeStore() throws -> GitHubAccountStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: GitHubAccount.self, configurations: config)
        return GitHubAccountStore(context: ModelContext(container))
    }

    func test_emptyOnInit() throws {
        let store = try makeStore()
        XCTAssertTrue(store.accounts.isEmpty)
    }

    func test_addInsertsRowAndPersistsToken() async throws {
        let store = try makeStore()
        let acc = await store.add(login: "octocat", avatarURL: "https://a/x.png", token: "gho_1")
        defer { Task { await KeychainService.deleteGitHubToken(for: acc.id) } }
        XCTAssertEqual(store.accounts.map(\.login), ["octocat"])
        XCTAssertEqual(store.token(for: acc), "gho_1")
    }

    func test_addExistingLoginUpsertsAndRefreshesToken() async throws {
        let store = try makeStore()
        let first = await store.add(login: "octocat", avatarURL: nil, token: "gho_old")
        let second = await store.add(login: "OctoCat", avatarURL: "https://a/y.png", token: "gho_new")
        defer { Task { await KeychainService.deleteGitHubToken(for: first.id) } }
        XCTAssertEqual(store.accounts.count, 1, "case-insensitive login should upsert, not duplicate")
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.token(for: second), "gho_new")
        XCTAssertEqual(store.accounts.first?.avatarURL, "https://a/y.png")
    }

    func test_deleteWithCredentialsRemovesRowAndToken() async throws {
        let store = try makeStore()
        let acc = await store.add(login: "octocat", avatarURL: nil, token: "gho_1")
        await store.deleteWithCredentials(acc)
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertNil(KeychainService.loadGitHubTokenSync(for: acc.id))
    }

    func test_coalesceCollapsesDuplicateLoginsFromSync() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: GitHubAccount.self, configurations: config)
        let context = ModelContext(container)
        // Two rows, same login, as if synced from two devices. Oldest wins.
        let older = GitHubAccount(login: "octocat", createdAt: Date(timeIntervalSince1970: 1))
        let newer = GitHubAccount(login: "octocat", createdAt: Date(timeIntervalSince1970: 2))
        context.insert(older)
        context.insert(newer)
        try context.save()
        let store = GitHubAccountStore(context: context)
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.accounts.first?.id, older.id)
    }
}

import XCTest
@testable import AppFeedback

final class KeychainServicePerAccountTests: XCTestCase {
    func test_smtpRoundTripIsAccountScoped() async throws {
        let a = UUID()
        let b = UUID()
        defer {
            Task { await KeychainService.deleteSMTPPassword(for: a) }
            Task { await KeychainService.deleteSMTPPassword(for: b) }
        }
        _ = await KeychainService.saveSMTPPassword("aaaa", for: a)
        _ = await KeychainService.saveSMTPPassword("bbbb", for: b)
        let loadedA = await KeychainService.loadSMTPPassword(for: a)
        let loadedB = await KeychainService.loadSMTPPassword(for: b)
        XCTAssertEqual(loadedA, "aaaa")
        XCTAssertEqual(loadedB, "bbbb")
    }

    func test_imapRoundTripIsAccountScoped() async throws {
        let a = UUID()
        let b = UUID()
        defer {
            Task { await KeychainService.deleteIMAPPassword(for: a) }
            Task { await KeychainService.deleteIMAPPassword(for: b) }
        }
        _ = await KeychainService.saveIMAPPassword("aaaa", for: a)
        _ = await KeychainService.saveIMAPPassword("bbbb", for: b)
        let loadedA = await KeychainService.loadIMAPPassword(for: a)
        let loadedB = await KeychainService.loadIMAPPassword(for: b)
        XCTAssertEqual(loadedA, "aaaa")
        XCTAssertEqual(loadedB, "bbbb")
    }

    func test_deleteForOneAccountLeavesOthers() async throws {
        let a = UUID()
        let b = UUID()
        defer {
            Task { await KeychainService.deleteSMTPPassword(for: a) }
            Task { await KeychainService.deleteSMTPPassword(for: b) }
        }
        _ = await KeychainService.saveSMTPPassword("a", for: a)
        _ = await KeychainService.saveSMTPPassword("b", for: b)
        await KeychainService.deleteSMTPPassword(for: a)
        let afterDeleteA = await KeychainService.loadSMTPPassword(for: a)
        let afterDeleteB = await KeychainService.loadSMTPPassword(for: b)
        XCTAssertNil(afterDeleteA)
        XCTAssertEqual(afterDeleteB, "b")
    }

    func test_gitHubTokenRoundTripIsAccountScoped() async throws {
        let a = UUID()
        let b = UUID()
        defer {
            Task { await KeychainService.deleteGitHubToken(for: a) }
            Task { await KeychainService.deleteGitHubToken(for: b) }
        }
        _ = await KeychainService.saveGitHubToken("tok-a", for: a)
        _ = await KeychainService.saveGitHubToken("tok-b", for: b)
        let loadedA = await KeychainService.loadGitHubToken(for: a)
        let loadedB = await KeychainService.loadGitHubToken(for: b)
        XCTAssertEqual(loadedA, "tok-a")
        XCTAssertEqual(loadedB, "tok-b")
        XCTAssertEqual(KeychainService.loadGitHubTokenSync(for: a), "tok-a")
    }

    func test_deleteGitHubTokenLeavesOthers() async throws {
        let a = UUID()
        let b = UUID()
        defer {
            Task { await KeychainService.deleteGitHubToken(for: a) }
            Task { await KeychainService.deleteGitHubToken(for: b) }
        }
        _ = await KeychainService.saveGitHubToken("a", for: a)
        _ = await KeychainService.saveGitHubToken("b", for: b)
        await KeychainService.deleteGitHubToken(for: a)
        let afterDeleteA = await KeychainService.loadGitHubToken(for: a)
        let afterDeleteB = await KeychainService.loadGitHubToken(for: b)
        XCTAssertNil(afterDeleteA)
        XCTAssertEqual(afterDeleteB, "b")
    }
}

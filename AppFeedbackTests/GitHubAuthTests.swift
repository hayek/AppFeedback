import XCTest
@testable import AppFeedback

final class GitHubAuthModelsTests: XCTestCase {

    func test_deviceCodeResponse_decodesFromGitHubJSON() throws {
        let json = """
        {
          "device_code": "abc123",
          "user_code": "WDJB-MJHT",
          "verification_uri": "https://github.com/login/device",
          "expires_in": 900,
          "interval": 5
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(DeviceCodeResponse.self, from: json)
        XCTAssertEqual(response.deviceCode, "abc123")
        XCTAssertEqual(response.userCode, "WDJB-MJHT")
        XCTAssertEqual(response.verificationUri, "https://github.com/login/device")
        XCTAssertEqual(response.expiresIn, 900)
        XCTAssertEqual(response.interval, 5)
    }

    func test_gitHubRepo_decodesFromGitHubJSON() throws {
        let json = """
        {
          "id": 42,
          "name": "feedback",
          "full_name": "acme/feedback",
          "private": true,
          "owner": { "login": "acme" }
        }
        """.data(using: .utf8)!
        let repo = try JSONDecoder().decode(GitHubRepo.self, from: json)
        XCTAssertEqual(repo.id, 42)
        XCTAssertEqual(repo.name, "feedback")
        XCTAssertEqual(repo.fullName, "acme/feedback")
        XCTAssertTrue(repo.isPrivate)
        XCTAssertEqual(repo.owner.login, "acme")
    }
}

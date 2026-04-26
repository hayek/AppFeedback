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

final class GitHubAuthServiceTests: XCTestCase {

    private func ok(_ req: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    private func tokenJSON(_ token: String) -> Data {
        """
        { "access_token": "\(token)", "token_type": "bearer", "scope": "repo" }
        """.data(using: .utf8)!
    }

    private func errorJSON(_ code: String) -> Data {
        """
        { "error": "\(code)", "error_description": "" }
        """.data(using: .utf8)!
    }

    // MARK: requestDeviceCode

    func test_requestDeviceCode_decodesResponse() async throws {
        let responseJSON = """
        {
          "device_code": "devcode",
          "user_code": "ABCD-1234",
          "verification_uri": "https://github.com/login/device",
          "expires_in": 900,
          "interval": 5
        }
        """.data(using: .utf8)!
        MockURLProtocol.requestHandler = { req in (self.ok(req), responseJSON) }
        let service = GitHubAuthService(session: .mock)
        let result = try await service.requestDeviceCode()
        XCTAssertEqual(result.userCode, "ABCD-1234")
        XCTAssertEqual(result.deviceCode, "devcode")
    }

    func test_requestDeviceCode_throwsOnNon200() async throws {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        let service = GitHubAuthService(session: .mock)
        do {
            _ = try await service.requestDeviceCode()
            XCTFail("Expected throw")
        } catch GitHubAuthService.AuthError.apiError(let code) {
            XCTAssertEqual(code, 500)
        }
    }

    // MARK: pollForToken

    func test_pollForToken_returnsToken_whenImmediatelyAuthorized() async throws {
        MockURLProtocol.requestHandler = { req in (self.ok(req), self.tokenJSON("gho_test")) }
        let service = GitHubAuthService(session: .mock)
        let token = try await service.pollForToken(deviceCode: "devcode", interval: 0)
        XCTAssertEqual(token, "gho_test")
    }

    func test_pollForToken_retriesOnAuthorizationPending() async throws {
        var callCount = 0
        MockURLProtocol.requestHandler = { req in
            callCount += 1
            let data = callCount < 3 ? self.errorJSON("authorization_pending") : self.tokenJSON("gho_retry")
            return (self.ok(req), data)
        }
        let service = GitHubAuthService(session: .mock)
        let token = try await service.pollForToken(deviceCode: "devcode", interval: 0)
        XCTAssertEqual(token, "gho_retry")
        XCTAssertEqual(callCount, 3)
    }

    func test_pollForToken_throwsAccessDenied() async throws {
        MockURLProtocol.requestHandler = { req in (self.ok(req), self.errorJSON("access_denied")) }
        let service = GitHubAuthService(session: .mock)
        do {
            _ = try await service.pollForToken(deviceCode: "devcode", interval: 0)
            XCTFail("Expected throw")
        } catch GitHubAuthService.AuthError.accessDenied {
            // pass
        }
    }

    func test_pollForToken_throwsExpiredToken() async throws {
        MockURLProtocol.requestHandler = { req in (self.ok(req), self.errorJSON("expired_token")) }
        let service = GitHubAuthService(session: .mock)
        do {
            _ = try await service.pollForToken(deviceCode: "devcode", interval: 0)
            XCTFail("Expected throw")
        } catch GitHubAuthService.AuthError.expiredToken {
            // pass
        }
    }

    // MARK: listRepos

    func test_listRepos_returnsDecodedRepos() async throws {
        let reposJSON = """
        [
          { "id": 1, "name": "alpha", "full_name": "org/alpha", "private": false, "owner": { "login": "org" } },
          { "id": 2, "name": "beta",  "full_name": "org/beta",  "private": true,  "owner": { "login": "org" } }
        ]
        """.data(using: .utf8)!
        MockURLProtocol.requestHandler = { req in (self.ok(req), reposJSON) }
        let service = GitHubAuthService(session: .mock)
        let repos = try await service.listRepos(token: "tok")
        XCTAssertEqual(repos.count, 2)
        XCTAssertEqual(repos[0].name, "alpha")
        XCTAssertTrue(repos[1].isPrivate)
    }

    func test_pollForToken_incrementsIntervalOnSlowDown() async throws {
        var callCount = 0
        MockURLProtocol.requestHandler = { req in
            callCount += 1
            let data = callCount == 1 ? self.errorJSON("slow_down") : self.tokenJSON("gho_slow")
            return (self.ok(req), data)
        }
        let service = GitHubAuthService(session: .mock)
        let token = try await service.pollForToken(deviceCode: "devcode", interval: 0)
        XCTAssertEqual(token, "gho_slow")
        XCTAssertEqual(callCount, 2)
    }

    func test_listRepos_paginatesUntilPageBelowHundred() async throws {
        let makeRepos: (Int, Int) -> Data = { startId, count in
            let items = (startId..<(startId + count)).map { n in
                """
                { "id": \(n), "name": "repo\(n)", "full_name": "org/repo\(n)", "private": false, "owner": { "login": "org" } }
                """
            }
            return ("[\(items.joined(separator: ","))]").data(using: .utf8)!
        }
        var pageRequests = 0
        MockURLProtocol.requestHandler = { req in
            pageRequests += 1
            let data = pageRequests == 1 ? makeRepos(1, 100) : makeRepos(101, 1)
            return (self.ok(req), data)
        }
        let service = GitHubAuthService(session: .mock)
        let repos = try await service.listRepos(token: "tok")
        XCTAssertEqual(repos.count, 101)
        XCTAssertEqual(pageRequests, 2)
    }

    func test_requestDeviceCode_postsToCorrectURL() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { req in
            capturedRequest = req
            let responseJSON = """
            { "device_code": "d", "user_code": "U-CODE", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 5 }
            """.data(using: .utf8)!
            return (self.ok(req), responseJSON)
        }
        let service = GitHubAuthService(session: .mock)
        _ = try await service.requestDeviceCode()
        XCTAssertEqual(capturedRequest?.url?.absoluteString, "https://github.com/login/device/code")
        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Accept"), "application/json")
    }
}

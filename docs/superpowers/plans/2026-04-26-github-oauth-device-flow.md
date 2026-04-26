# GitHub OAuth Device Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users log in with GitHub via Device Flow and pick a repo from a list instead of manually entering owner/repo/token.

**Architecture:** A new `GitHubAuthService` actor drives the three-step device flow (request code → poll for token → list repos). A new `GitHubLoginView` presents each step reactively via an `AuthState` enum. `AddEditRepoView` gains a "Sign in with GitHub" primary button that sheets this view; manual entry remains as a fallback below a divider.

**Tech Stack:** Swift/SwiftUI, XCTest + existing `MockURLProtocol`/`.mock` URLSession, GitHub Device Flow API, GitHub REST API v3.

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `AppFeedback/Models/GitHubAuthModels.swift` | `DeviceCodeResponse`, `GitHubRepo` structs |
| Create | `AppFeedback/Services/GitHubAuthService.swift` | Device flow actor: request code, poll token, list repos |
| Create | `AppFeedback/Views/Settings/GitHubLoginView.swift` | Full device-flow UI driven by `AuthState` enum |
| Create | `AppFeedbackTests/GitHubAuthTests.swift` | Model decoding + service logic tests |
| Modify | `AppFeedback/Views/Settings/AddEditRepoView.swift` | Add "Sign in with GitHub" button + `GitHubLoginView` sheet |

---

## Task 0: Register a GitHub OAuth App (manual, ~2 min)

This is a one-time human step. No code changes.

- [ ] Go to `https://github.com/settings/developers` → **OAuth Apps** → **New OAuth App**
- [ ] Fill in:
  - Application name: `AppFeedback`
  - Homepage URL: `https://github.com` (placeholder — device flow ignores it)
  - Authorization callback URL: `https://github.com` (placeholder — device flow ignores it)
- [ ] Click **Register application**
- [ ] Copy the **Client ID** (looks like `Ov23li...`). You will paste it into `GitHubAuthService.clientID` in Task 2. **Do not generate a client secret** — device flow does not use one.

---

## Task 1: Add models + tests

**Files:**
- Create: `AppFeedback/Models/GitHubAuthModels.swift`
- Create: `AppFeedbackTests/GitHubAuthTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `AppFeedbackTests/GitHubAuthTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests — confirm they fail**

```
curl -s -X POST http://localhost:19741/api/test
```

Expected: build error — `DeviceCodeResponse` and `GitHubRepo` not found.

- [ ] **Step 3: Create the models**

Create `AppFeedback/Models/GitHubAuthModels.swift`:

```swift
import Foundation

struct DeviceCodeResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUri = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

struct GitHubRepo: Decodable, Identifiable {
    let id: Int
    let name: String
    let fullName: String
    let isPrivate: Bool
    let owner: Owner

    struct Owner: Decodable {
        let login: String
    }

    enum CodingKeys: String, CodingKey {
        case id, name, owner
        case fullName = "full_name"
        case isPrivate = "private"
    }
}
```

- [ ] **Step 4: Run tests — confirm they pass**

```
curl -s -X POST http://localhost:19741/api/test
```

Expected: `test_deviceCodeResponse_decodesFromGitHubJSON` PASS, `test_gitHubRepo_decodesFromGitHubJSON` PASS.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Models/GitHubAuthModels.swift AppFeedbackTests/GitHubAuthTests.swift
git commit -m "feat: add GitHubAuthModels with tests"
```

---

## Task 2: Add GitHubAuthService + tests

**Files:**
- Create: `AppFeedback/Services/GitHubAuthService.swift`
- Modify: `AppFeedbackTests/GitHubAuthTests.swift` (append service tests)

- [ ] **Step 1: Write the failing service tests**

Append to `AppFeedbackTests/GitHubAuthTests.swift` (after the closing `}` of `GitHubAuthModelsTests`):

```swift
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
}
```

- [ ] **Step 2: Run tests — confirm they fail**

```
curl -s -X POST http://localhost:19741/api/test
```

Expected: build error — `GitHubAuthService` not found.

- [ ] **Step 3: Create GitHubAuthService**

Create `AppFeedback/Services/GitHubAuthService.swift`:

```swift
import Foundation

actor GitHubAuthService {
    static let clientID = "PASTE_YOUR_CLIENT_ID_HERE"
    private static let scope = "repo"

    enum AuthError: LocalizedError {
        case accessDenied
        case expiredToken
        case unexpectedResponse
        case apiError(Int)

        var errorDescription: String? {
            switch self {
            case .accessDenied:        return "Access was denied on GitHub."
            case .expiredToken:        return "The code expired. Please try again."
            case .unexpectedResponse:  return "Unexpected response from GitHub."
            case .apiError(let code):  return "GitHub API returned \(code)."
            }
        }
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func requestDeviceCode() async throws -> DeviceCodeResponse {
        var request = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "client_id=\(Self.clientID)&scope=\(Self.scope)".data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuthError.apiError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
    }

    func pollForToken(deviceCode: String, interval: Int) async throws -> String {
        var currentInterval = interval
        while true {
            if currentInterval > 0 {
                try await Task.sleep(for: .seconds(currentInterval))
            }
            try Task.checkCancellation()

            var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let body = "client_id=\(Self.clientID)&device_code=\(deviceCode)&grant_type=urn:ietf:params:oauth:grant-type:device_code"
            request.httpBody = body.data(using: .utf8)

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw AuthError.apiError((response as? HTTPURLResponse)?.statusCode ?? 0)
            }

            guard let json = try? JSONDecoder().decode([String: String].self, from: data) else {
                throw AuthError.unexpectedResponse
            }

            if let token = json["access_token"] { return token }

            switch json["error"] {
            case "authorization_pending": continue
            case "slow_down":             currentInterval += 5
            case "access_denied":         throw AuthError.accessDenied
            case "expired_token":         throw AuthError.expiredToken
            default:                      throw AuthError.unexpectedResponse
            }
        }
    }

    func listRepos(token: String) async throws -> [GitHubRepo] {
        var page = 1
        var collected: [GitHubRepo] = []

        while true {
            var comps = URLComponents(string: "https://api.github.com/user/repos")!
            comps.queryItems = [
                URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member"),
                URLQueryItem(name: "sort",        value: "pushed"),
                URLQueryItem(name: "per_page",    value: "100"),
                URLQueryItem(name: "page",        value: "\(page)"),
            ]
            var request = URLRequest(url: comps.url!)
            request.setValue("Bearer \(token)",                 forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw AuthError.apiError((response as? HTTPURLResponse)?.statusCode ?? 0)
            }

            let batch = try JSONDecoder().decode([GitHubRepo].self, from: data)
            collected.append(contentsOf: batch)
            if batch.count < 100 { break }
            page += 1
        }
        return collected
    }
}
```

- [ ] **Step 4: Run tests — confirm they pass**

```
curl -s -X POST http://localhost:19741/api/test
```

Expected: all 8 `GitHubAuthServiceTests` and 2 `GitHubAuthModelsTests` tests PASS.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/GitHubAuthService.swift AppFeedbackTests/GitHubAuthTests.swift
git commit -m "feat: add GitHubAuthService with device flow and tests"
```

---

## Task 3: Build GitHubLoginView

**Files:**
- Create: `AppFeedback/Views/Settings/GitHubLoginView.swift`

No tests for this task — it is pure SwiftUI view logic; verify manually by running the app.

- [ ] **Step 1: Create GitHubLoginView**

Create `AppFeedback/Views/Settings/GitHubLoginView.swift`:

```swift
import SwiftUI

@MainActor
struct GitHubLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Bindable var store: RepoStore

    @State private var authState: AuthState = .idle
    @State private var oauthToken = ""
    @State private var searchText = ""
    @State private var selectedRepo: GitHubRepo?
    @State private var displayName = ""
    @State private var pollTask: Task<Void, Never>?

    private let service = GitHubAuthService()

    enum AuthState {
        case idle
        case requestingCode
        case waitingForUser(DeviceCodeResponse)
        case fetchingRepos
        case pickingRepo([GitHubRepo])
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 380)
        #endif
        .onDisappear { pollTask?.cancel() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sign in with GitHub")
                    .font(.system(size: 13, weight: .semibold))
                Text("Authorize AppFeedback to access your repositories")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch authState {
        case .idle:
            idleView
        case .requestingCode:
            centeredProgress("Connecting to GitHub…")
        case .waitingForUser(let response):
            waitingView(response)
        case .fetchingRepos:
            centeredProgress("Loading your repositories…")
        case .pickingRepo(let repos):
            repoPickerView(repos)
        case .failed(let message):
            failedView(message)
        }
    }

    private var idleView: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Connect your GitHub account to browse and select a repository.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            Button("Sign in with GitHub") { startDeviceFlow() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func waitingView(_ response: DeviceCodeResponse) -> some View {
        VStack(spacing: 20) {
            Text("Enter this code at GitHub")
                .font(.system(size: 13, weight: .semibold))
            Text(response.userCode)
                .font(.system(size: 30, weight: .bold).monospaced())
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            Button("Open GitHub") {
                if let url = URL(string: response.verificationUri) { openURL(url) }
            }
            .buttonStyle(.borderedProminent)
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("Waiting for authorization…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func repoPickerView(_ repos: [GitHubRepo]) -> some View {
        let filtered = repos.filter {
            searchText.isEmpty || $0.fullName.localizedCaseInsensitiveContains(searchText)
        }
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Search repositories…", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            if filtered.isEmpty {
                Text(repos.isEmpty ? "No repositories found.\nCheck that your OAuth app has repo scope." : "No results.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered, id: \.id) { repo in
                    Button {
                        selectedRepo = repo
                        displayName = repo.name
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(repo.fullName)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.primary)
                                if repo.isPrivate {
                                    Label("Private", systemImage: "lock")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if selectedRepo?.id == repo.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.accentColor)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }

            if selectedRepo != nil {
                Divider()
                HStack(spacing: 10) {
                    TextField("Display name", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") { saveSelectedRepo() }
                        .disabled(displayName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .buttonStyle(.borderedProminent)
                }
                .padding(12)
            }
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button("Try Again") { authState = .idle }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func centeredProgress(_ label: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func startDeviceFlow() {
        authState = .requestingCode
        pollTask?.cancel()
        pollTask = Task {
            do {
                let codeResponse = try await service.requestDeviceCode()
                authState = .waitingForUser(codeResponse)
                let token = try await service.pollForToken(
                    deviceCode: codeResponse.deviceCode,
                    interval: codeResponse.interval
                )
                oauthToken = token
                authState = .fetchingRepos
                let repos = try await service.listRepos(token: token)
                authState = .pickingRepo(repos)
            } catch is CancellationError {
                // user dismissed — do nothing
            } catch {
                authState = .failed(error.localizedDescription)
            }
        }
    }

    private func saveSelectedRepo() {
        guard let selected = selectedRepo else { return }
        let trimName = displayName.trimmingCharacters(in: .whitespaces)
        let config = RepoConfig(
            displayName: trimName.isEmpty ? selected.name : trimName,
            owner: selected.owner.login,
            repo: selected.name
        )
        store.add(config)
        KeychainService.save(token: oauthToken, for: config)
        dismiss()
    }
}
```

- [ ] **Step 2: Build — confirm no errors**

```
curl -s -X POST http://localhost:19741/api/build
```

Expected: `Build succeeded`.

- [ ] **Step 3: Commit**

```bash
git add AppFeedback/Views/Settings/GitHubLoginView.swift
git commit -m "feat: add GitHubLoginView for device flow UI"
```

---

## Task 4: Wire GitHubLoginView into AddEditRepoView

**Files:**
- Modify: `AppFeedback/Views/Settings/AddEditRepoView.swift`

- [ ] **Step 1: Add `showGitHubLogin` state and sheet**

In `AddEditRepoView`, add a `@State private var showGitHubLogin = false` property alongside the existing state vars, then add `.sheet(isPresented: $showGitHubLogin) { GitHubLoginView(store: store) }` to the body's VStack. Only show the GitHub login option when adding a new repo (not editing).

Replace the entire `AddEditRepoView` body with:

```swift
var body: some View {
    VStack(spacing: 0) {
        header
        Divider()
        ScrollView {
            VStack(spacing: 20) {
                if !isEditing {
                    Button {
                        showGitHubLogin = true
                    } label: {
                        HStack {
                            Image(systemName: "person.badge.key.fill")
                            Text("Sign in with GitHub")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    HStack {
                        VStack { Divider() }
                        Text("or enter manually")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        VStack { Divider() }
                    }
                }

                fieldSection(
                    label: "Display Name",
                    hint: "A friendly name shown in the sidebar"
                ) {
                    GroupBox {
                        StyledTextField("My App Feedback", text: $displayName)
                    }
                }

                fieldSection(
                    label: "GitHub Repository",
                    hint: "The owner and repository name on GitHub"
                ) {
                    GroupBox {
                        HStack(spacing: 0) {
                            StyledTextField("owner", text: $owner, monospaced: true)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                            Text("/")
                                .foregroundStyle(.tertiary)
                                .font(.system(size: 14, weight: .light))
                                .padding(.horizontal, 6)
                            StyledTextField("repo-name", text: $repo, monospaced: true)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                        }
                    }
                }

                fieldSection(
                    label: "GitHub Token",
                    hint: nil
                ) {
                    GroupBox {
                        StyledTextField("ghp_…", text: $token, secure: true, monospaced: true)
                            .autocorrectionDisabled()
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("Requires repo read access. Stored securely in Keychain.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(20)
        }
    }
    #if os(macOS)
    .frame(minWidth: 440, minHeight: 320)
    #endif
    .onAppear { populateFromExisting() }
    .sheet(isPresented: $showGitHubLogin) {
        GitHubLoginView(store: store)
    }
}
```

Also add `@State private var showGitHubLogin = false` to the state properties block at the top of `AddEditRepoView`.

- [ ] **Step 2: Build — confirm no errors**

```
curl -s -X POST http://localhost:19741/api/build
```

Expected: `Build succeeded`.

- [ ] **Step 3: Run and verify manually**

```
curl -s -X POST http://localhost:19741/api/run
```

Verify:
- "Add Repository" sheet shows "Sign in with GitHub" button at top and manual fields below a divider
- "Edit Repository" sheet shows only the manual fields (no GitHub button)
- Tapping "Sign in with GitHub" opens `GitHubLoginView`
- The "+ Add Repo" empty-state button also opens `GitHubLoginView` (it sheets `AddEditRepoView`, which now has the button)

- [ ] **Step 4: Run all tests — confirm nothing regressed**

```
curl -s -X POST http://localhost:19741/api/test
```

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Views/Settings/AddEditRepoView.swift
git commit -m "feat: add GitHub OAuth login to AddEditRepoView"
```

---

## Manual end-to-end test (after Task 0 client_id is filled in)

1. Replace `PASTE_YOUR_CLIENT_ID_HERE` in `GitHubAuthService.clientID` with the real client ID from Task 0.
2. Run the app. Open "Add Repository".
3. Tap "Sign in with GitHub" — verify the code screen appears with your user code.
4. Tap "Open GitHub" — browser opens `https://github.com/login/device`.
5. Enter the code and authorize.
6. App auto-advances to the repo list — verify your repos appear, private ones show a lock icon.
7. Search works correctly.
8. Select a repo → display name field appears pre-filled.
9. Tap "Add" → repo appears in the sidebar, issues load normally.
10. Verify the token is saved: edit the repo — the GitHub login button is hidden and manual fields are populated.

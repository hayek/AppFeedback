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

            let json: [String: String]
            do {
                json = try JSONDecoder().decode([String: String].self, from: data)
            } catch {
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

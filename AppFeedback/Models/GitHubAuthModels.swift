import Foundation

struct DeviceCodeResponse: Decodable, Sendable {
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

struct GitHubRepo: Decodable, Identifiable, Sendable {
    let id: Int
    let name: String
    let fullName: String
    let isPrivate: Bool
    let owner: Owner

    struct Owner: Decodable, Sendable {
        let login: String
    }

    enum CodingKeys: String, CodingKey {
        case id, name, owner
        case fullName = "full_name"
        case isPrivate = "private"
    }
}

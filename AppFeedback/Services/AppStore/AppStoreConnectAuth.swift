import Foundation
import CryptoKit

/// Mints an ES256 JWT for App Store Connect from a `.p8` PEM private key, per the ASC auth
/// contract: header {alg:ES256,kid,typ:JWT}, payload {iss,iat,exp(≤20m),aud:appstoreconnect-v1},
/// signed with CryptoKit P256 using the 64-byte raw r‖s representation (NOT DER). The token is
/// cached and only re-minted as it nears expiry (we keep a ~15-minute usable window).
actor AppStoreConnectAuth {
    private let issuerID: String
    private let keyID: String
    private let p8PEM: String

    private var cached: (token: String, expiresAt: Date)?

    /// Usable lifetime we hand out before re-minting. ASC allows exp ≤ 20 min; we mint with a
    /// 20-minute exp and refresh once under 5 minutes remain, so callers always get ≥ ~15 min.
    private static let lifetime: TimeInterval = 20 * 60
    private static let refreshFloor: TimeInterval = 5 * 60

    init(issuerID: String, keyID: String, p8PEM: String) {
        self.issuerID = issuerID
        self.keyID = keyID
        self.p8PEM = p8PEM
    }

    func token() async throws -> String {
        let now = Date()
        if let cached, cached.expiresAt.timeIntervalSince(now) > Self.refreshFloor {
            return cached.token
        }
        let jwt = try Self.makeJWT(issuerID: issuerID, keyID: keyID, p8PEM: p8PEM, now: now)
        cached = (jwt, now.addingTimeInterval(Self.lifetime))
        return jwt
    }

    // MARK: - Pure JWT minting (testable without the cache)

    static func makeJWT(issuerID: String, keyID: String, p8PEM: String, now: Date) throws -> String {
        let key: P256.Signing.PrivateKey
        do {
            key = try P256.Signing.PrivateKey(pemRepresentation: p8PEM)
        } catch {
            throw AppStoreConnectError.badKey(error.localizedDescription)
        }
        let iat = Int(now.timeIntervalSince1970)
        let exp = iat + 1200   // 20 minutes, the ASC maximum
        let header: [String: Any] = ["alg": "ES256", "kid": keyID, "typ": "JWT"]
        let payload: [String: Any] = ["iss": issuerID, "iat": iat, "exp": exp, "aud": "appstoreconnect-v1"]
        let headerSegment = base64URL(try JSONSerialization.data(withJSONObject: header))
        let payloadSegment = base64URL(try JSONSerialization.data(withJSONObject: payload))
        let signingInput = headerSegment + "." + payloadSegment
        // signature(for:) applies SHA-256 internally — do NOT pre-hash.
        let signature = try key.signature(for: Data(signingInput.utf8))
        let sigSegment = base64URL(signature.rawRepresentation)   // 64-byte r‖s, NOT DER
        return signingInput + "." + sigSegment
    }

    /// base64url: standard base64 with `+`→`-`, `/`→`_`, padding `=` stripped.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

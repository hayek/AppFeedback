import XCTest
import CryptoKit
@testable import AppFeedback

final class AppStoreConnectAuthTests: XCTestCase {
    // Generate a P256 key IN TEST (never the Keychain) and use its PEM as the .p8.
    private func makeKey() -> (pem: String, pub: P256.Signing.PublicKey) {
        let key = P256.Signing.PrivateKey()
        return (key.pemRepresentation, key.publicKey)
    }

    private func b64urlDecode(_ s: String) -> Data {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)!
    }

    func testJWTHeaderPayloadAndExp() throws {
        let (pem, _) = makeKey()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let jwt = try AppStoreConnectAuth.makeJWT(issuerID: "ISS-1", keyID: "KID-1", p8PEM: pem, now: now)
        let parts = jwt.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        let header = try JSONSerialization.jsonObject(with: b64urlDecode(parts[0])) as! [String: Any]
        XCTAssertEqual(header["alg"] as? String, "ES256")
        XCTAssertEqual(header["kid"] as? String, "KID-1")
        XCTAssertEqual(header["typ"] as? String, "JWT")
        let payload = try JSONSerialization.jsonObject(with: b64urlDecode(parts[1])) as! [String: Any]
        XCTAssertEqual(payload["iss"] as? String, "ISS-1")
        XCTAssertEqual(payload["aud"] as? String, "appstoreconnect-v1")
        let iat = payload["iat"] as! Int
        let exp = payload["exp"] as! Int
        XCTAssertEqual(iat, Int(now.timeIntervalSince1970))
        XCTAssertLessThanOrEqual(exp - iat, 1200)   // ≤ 20 minutes
        XCTAssertGreaterThan(exp, iat)
    }

    func testSignatureIsRaw64BytesVerifiableByPublicKey() throws {
        let (pem, pub) = makeKey()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let jwt = try AppStoreConnectAuth.makeJWT(issuerID: "i", keyID: "k", p8PEM: pem, now: now)
        let parts = jwt.split(separator: ".").map(String.init)
        let signingInput = parts[0] + "." + parts[1]
        let sigData = b64urlDecode(parts[2])
        XCTAssertEqual(sigData.count, 64, "ASC requires 64-byte raw r||s, NOT DER")
        // signature(for:) hashes SHA-256 internally → verify the same way.
        let sig = try P256.Signing.ECDSASignature(rawRepresentation: sigData)
        XCTAssertTrue(pub.isValidSignature(sig, for: Data(signingInput.utf8)))
    }

    func testTokenCachesWithinWindow() async throws {
        let (pem, _) = makeKey()
        let auth = AppStoreConnectAuth(issuerID: "i", keyID: "k", p8PEM: pem)
        let a = try await auth.token()
        let b = try await auth.token()
        XCTAssertEqual(a, b, "token() reuses the cached JWT until it nears expiry")
    }

    func testBadPEMThrows() {
        XCTAssertThrowsError(try AppStoreConnectAuth.makeJWT(issuerID: "i", keyID: "k", p8PEM: "not a key", now: Date()))
    }
}

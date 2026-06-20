import Foundation
import Observation

/// View-independent logic behind `AppStoreSourceForm`, so the key-validation / app-pick / save
/// behavior is unit-tested without SwiftUI. The form owns one of these as `@State`.
@MainActor
@Observable
final class AppStoreSourceFormModel {
    enum Phase: Equatable {
        case idle, testing, valid
        case failed(String)
    }

    // Editable fields.
    var issuerID = ""
    var keyID = ""
    var pemText = ""           // the .p8 PEM contents (imported via .fileImporter)
    var manualAppID = ""       // numeric ASC app id fallback when the picker can't load

    // Test / validation state.
    var phase: Phase = .idle
    var discoveredApps: [ASCApp] = []
    var selectedAppID: String?

    init() {}

    /// Reads the `.p8` at `url` into `pemText`. Handles iOS Files security-scoped URLs.
    func importPEM(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            pemText = text
        } else if let data = try? Data(contentsOf: url) {
            pemText = String(decoding: data, as: UTF8.self)
        }
    }

    /// Validates the key by minting a JWT and calling `listApps()`. `makeClient` is injected so tests
    /// pass a fake; production passes a closure building a real `AppStoreConnectClient`.
    func test(makeClient: (String, String, String) -> any AppStoreConnectClientProtocol) async {
        guard !issuerID.isEmpty, !keyID.isEmpty, !pemText.isEmpty else {
            phase = .failed("Enter Issuer ID, Key ID, and import the .p8 key first."); return
        }
        phase = .testing
        let client = makeClient(issuerID, keyID, pemText)
        do {
            let apps = try await client.listApps()
            discoveredApps = apps.sorted { $0.name < $1.name }
            if selectedAppID == nil { selectedAppID = discoveredApps.first?.id }
            phase = .valid
        } catch {
            let code = (error as? StatusCarryingError)?.statusCode ?? 0
            switch code {
            case 401: phase = .failed("Authentication failed — check the Issuer ID, Key ID, and .p8 key.")
            case 403: phase = .failed("This key is not authorized for the App Store Connect API.")
            default:  phase = .failed((error as? LocalizedError)?.errorDescription ?? "Could not reach App Store Connect.")
            }
        }
    }

    var canSave: Bool {
        !issuerID.trimmingCharacters(in: .whitespaces).isEmpty
            && !keyID.trimmingCharacters(in: .whitespaces).isEmpty
            && !pemText.isEmpty
            && resolvedAppAppleID() != nil
    }

    /// Picker selection wins; otherwise a trimmed numeric manual id; otherwise nil.
    func resolvedAppAppleID() -> String? {
        if let selectedAppID, !selectedAppID.isEmpty { return selectedAppID }
        let trimmed = manualAppID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) else { return nil }
        return trimmed
    }

    /// Persists the PEM to the Keychain (keyed by product id) and writes the IDs onto the product.
    func save(productID: UUID, into store: ProductStore) async {
        guard let appID = resolvedAppAppleID() else { return }
        await KeychainService.saveASCKey(pemText, for: productID)
        guard var product = store.products.first(where: { $0.id == productID }) else { return }
        product.appStoreIssuerID = issuerID.trimmingCharacters(in: .whitespaces)
        product.appStoreKeyID = keyID.trimmingCharacters(in: .whitespaces)
        product.appStoreAppAppleID = appID
        store.update(product)
    }
}

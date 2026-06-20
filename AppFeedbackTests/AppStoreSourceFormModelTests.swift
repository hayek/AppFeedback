import XCTest
@testable import AppFeedback

@MainActor
final class AppStoreSourceFormModelTests: XCTestCase {
    func testTestSuccessPopulatesAppsAndMarksValid() async {
        let client = FakeAppStoreConnectClient()
        client.setApps([ASCApp(id: "111", bundleId: "com.acme.app", name: "Acme"),
                        ASCApp(id: "222", bundleId: "com.acme.pro", name: "Acme Pro")])
        let model = AppStoreSourceFormModel()
        model.issuerID = "iss"; model.keyID = "kid"; model.pemText = "pem"
        await model.test { _, _, _ in client }
        guard case .valid = model.phase else { return XCTFail("expected .valid, got \(model.phase)") }
        XCTAssertEqual(model.discoveredApps.count, 2)
    }

    func testTestForbiddenMarksFailed() async {
        let client = FakeAppStoreConnectClient()
        client.setThrowOnList(AppStoreConnectError.forbidden)
        let model = AppStoreSourceFormModel()
        model.issuerID = "iss"; model.keyID = "kid"; model.pemText = "pem"
        await model.test { _, _, _ in client }
        guard case .failed = model.phase else { return XCTFail("expected .failed, got \(model.phase)") }
    }

    func testCanSaveRequiresCredsPlusAppChoice() {
        let model = AppStoreSourceFormModel()
        XCTAssertFalse(model.canSave)
        model.issuerID = "iss"; model.keyID = "kid"; model.pemText = "pem"
        XCTAssertFalse(model.canSave, "no app chosen yet")
        model.manualAppID = "  6443123456 "
        XCTAssertTrue(model.canSave)
        XCTAssertEqual(model.resolvedAppAppleID(), "6443123456", "manual id trimmed")
        model.selectedAppID = "999"
        XCTAssertEqual(model.resolvedAppAppleID(), "999", "picker selection wins over manual")
    }

    func testManualAppIDMustBeNumeric() {
        let model = AppStoreSourceFormModel()
        model.issuerID = "iss"; model.keyID = "kid"; model.pemText = "pem"
        model.manualAppID = "not-a-number"
        XCTAssertFalse(model.canSave)
        XCTAssertNil(model.resolvedAppAppleID())
    }
}

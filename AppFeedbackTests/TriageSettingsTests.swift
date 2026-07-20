import Testing
import Foundation
@testable import AppFeedback

@MainActor
struct TriageSettingsTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "triage-tests-\(UUID().uuidString)")!
    }

    @Test func defaultsToOffAndPersistsMode() {
        let defaults = makeDefaults()
        let s1 = TriageSettings(defaults: defaults)
        #expect(s1.mode == .off)
        s1.mode = .hybrid
        let s2 = TriageSettings(defaults: defaults)
        #expect(s2.mode == .hybrid)
    }

    @Test func snapshotMarkerIsPerRepo() {
        let s = TriageSettings(defaults: makeDefaults())
        #expect(!s.hasSnapshotted(owner: "o", repo: "r"))
        s.markSnapshotted(owner: "o", repo: "r")
        #expect(s.hasSnapshotted(owner: "o", repo: "r"))
        #expect(!s.hasSnapshotted(owner: "o", repo: "other"))
    }
}

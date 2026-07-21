import Testing
import SwiftUI
@testable import AppFeedback

#if os(macOS)
@MainActor
struct SettingsIconRowSmokeTests {
    @Test func iconRowRenders() {
        let row = SettingsIconRow(title: "Email", systemImage: "envelope.fill", tileColor: .blue)
        _ = row.body
    }
}
#endif

import SwiftUI

@main
struct AppFeedbackApp: App {
    @State private var store = RepoStore()

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
        }
        #if os(macOS)
        Settings {
            SettingsView(store: store)
        }
        #endif
    }
}

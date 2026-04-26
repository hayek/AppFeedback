import SwiftUI

@main
struct AppFeedbackApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        #if os(macOS)
        Settings {
            SettingsView(store: RepoStore())
        }
        #endif
    }
}

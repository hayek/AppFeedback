import SwiftUI

/// SCAFFOLD (Phase 2). The real App Store Connect setup form — paste Issuer ID + Key ID,
/// import the .p8, "Test", app picker — is implemented in **Phase 3**. This placeholder only
/// establishes the navigation destination + the Off/Configured status surface so the Sources
/// section in `ProductSettingsView` compiles and routes here today.
struct AppStoreSourceForm: View {
    let store: ProductStore
    let product: ProductConfig

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    Text(product.appStoreSourceStatus == .configured ? "Configured" : "Off")
                        .foregroundStyle(.secondary)
                }
                if product.appStoreSourceStatus == .configured,
                   let appID = product.appStoreAppAppleID {
                    LabeledContent("App ID") { Text(appID).foregroundStyle(.secondary) }
                }
            } header: {
                Text("App Store Reviews")
            } footer: {
                Text("App Store Connect setup (Issuer ID, Key ID, .p8 key, app selection) arrives in a later update.")
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .navigationTitle("App Store")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

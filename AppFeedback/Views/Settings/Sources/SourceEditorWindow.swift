import SwiftUI

/// Identifies which product + which source an editor window should configure. Passed as the
/// `WindowGroup` value so each (product, source) gets its own reusable window.
struct SourceEditorRequest: Hashable, Codable {
    enum Kind: String, Hashable, Codable { case appStore, email }
    let productID: UUID
    let kind: Kind
}

#if os(macOS)
/// macOS source-configuration window. A real window (not a sheet) so it gets native window chrome —
/// the standard close button and a real title bar — which a `.sheet` cannot provide on macOS. The
/// primary **Add** action is pinned bottom-right and drives the form via its external save-trigger /
/// can-save bindings; the native window close button dismisses without saving.
struct SourceEditorWindow: View {
    let request: SourceEditorRequest?

    @Environment(ProductStore.self) private var store
    @State private var save = false
    @State private var canSave = false

    var body: some View {
        Group {
            if let request, let product = store.products.first(where: { $0.id == request.productID }) {
                let primaryTitle: String = {
                    switch request.kind {
                    case .appStore: return product.appStoreSourceStatus == .configured ? "Save" : "Add"
                    case .email:    return product.emailSourceStatus    == .configured ? "Save" : "Add"
                    }
                }()
                VStack(spacing: 0) {
                    switch request.kind {
                    case .appStore:
                        AppStoreSourceForm(store: store, product: product,
                                           externalSaveTrigger: $save, externalCanSave: $canSave)
                    case .email:
                        EmailSourceForm(product: product,
                                        externalSaveTrigger: $save, externalCanSave: $canSave)
                    }
                    Divider()
                    HStack {
                        Spacer()
                        Button(primaryTitle) { save = true }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!canSave)
                    }
                    .padding()
                }
                .navigationTitle(request.kind == .appStore ? "App Store" : "Email Feedback Inbox")
            } else {
                ContentUnavailableView("Source unavailable", systemImage: "questionmark.circle")
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 640)
    }
}
#endif

#if os(macOS)
import SwiftUI

/// macOS master-detail for the Products settings tab: a product list on the left and the
/// selected product's `ProductSettingsView` on the right. Selection is bound to
/// `SettingsNavigation.selectedProductID` so the sidebar "Settings…" item can focus a product
/// in this (separate) Settings window.
struct ProductsSettingsTab: View {
    @Bindable var store: ProductStore
    @Bindable var navigation: SettingsNavigation

    private var allDisplayNames: [String] { store.repos.map(\.displayName).sorted() }

    private var selectedProduct: ProductConfig? {
        store.repos.first(where: { $0.id == navigation.selectedProductID })
            ?? store.repos.first
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { selectedProduct?.id },
                set: { navigation.selectedProductID = $0 }
            )) {
                ForEach(store.repos) { product in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(ColorPalette.color(for: product.displayName, in: allDisplayNames))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(product.displayName)
                            Text("\(product.owner)/\(product.repo)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(product.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
            .onAppear {
                if navigation.selectedProductID == nil
                    || !store.repos.contains(where: { $0.id == navigation.selectedProductID }) {
                    navigation.selectedProductID = store.repos.first?.id
                }
            }
        } detail: {
            if let product = selectedProduct {
                NavigationStack {
                    ProductSettingsView(store: store, product: product)
                }
                .id(product.id)   // rebuild the detail when the selected product changes
            } else {
                ContentUnavailableView("No Products", systemImage: "shippingbox",
                    description: Text("Add a product to configure its feedback sources."))
            }
        }
    }
}
#endif

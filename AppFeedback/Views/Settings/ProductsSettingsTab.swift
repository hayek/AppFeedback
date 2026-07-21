#if os(macOS)
import SwiftUI

/// macOS master-detail for the Products settings tab: a product list on the left and the
/// selected product's `ProductSettingsView` on the right. Selection is bound to
/// `SettingsNavigation.selection` so the sidebar "Settings…" item can focus a product
/// in this (separate) Settings window.
///
/// The `.onAppear` guard in the sidebar resolves or falls back when the focused product is
/// missing (Task 7 — delivered together with the Task 6 master-detail scaffold in commit 0be5f1b).
struct ProductsSettingsTab: View {
    @Bindable var store: ProductStore
    @Bindable var navigation: SettingsNavigation
    @State private var showAdd = false

    private var allDisplayNames: [String] { store.products.map(\.displayName).sorted() }

    private var selectedProduct: ProductConfig? {
        store.products.first(where: { $0.id == navigation.selection?.productID })
            ?? store.products.first
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { selectedProduct?.id },
                set: { if let id = $0 { navigation.selection = .product(id) } }
            )) {
                ForEach(store.products) { product in
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
                if navigation.selection?.productID == nil
                    || !store.products.contains(where: { $0.id == navigation.selection?.productID }) {
                    if let first = store.products.first {
                        navigation.selection = .product(first.id)
                    }
                }
            }
            .toolbar {
                ToolbarItem {
                    Button { showAdd = true } label: {
                        Label("Add Product", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddEditRepoView(store: store)
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

#if os(iOS)
import SwiftUI

/// iOS-specific shell that wraps `EmailSourceForm` in a `NavigationStack` when presented as
/// a sheet (rather than a `NavigationLink` destination). Shares `EmailSourceFormModel` with
/// the macOS form — all logic lives there.
struct IOSEmailSourceForm: View {
    let product: ProductConfig

    var body: some View {
        NavigationStack {
            EmailSourceForm(product: product)
        }
    }
}
#endif

#if os(iOS)
import SwiftUI

/// iOS-specific shell that wraps `EmailSourceForm` in a `NavigationStack` when presented as
/// a sheet (rather than a `NavigationLink` destination). Shares `EmailSourceFormModel` with
/// the macOS form — all logic lives there.
///
/// Provides explicit Done (save + dismiss) and Cancel (dismiss without saving) toolbar buttons
/// so users have a clear path to exit the sheet in either direction.
struct IOSEmailSourceForm: View {
    let product: ProductConfig

    @Environment(\.dismiss) private var dismiss

    /// Flipped to `true` by the "Save" toolbar button; `EmailSourceForm` observes this via
    /// `onChange` and calls its own `save()` (which has the necessary environment access).
    @State private var saveTrigger = false

    var body: some View {
        NavigationStack {
            EmailSourceForm(product: product, externalSaveTrigger: $saveTrigger)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { saveTrigger = true }
                    }
                }
        }
    }
}
#endif

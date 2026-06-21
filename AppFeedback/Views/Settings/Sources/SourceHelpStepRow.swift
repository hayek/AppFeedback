import SwiftUI

/// A numbered step row used in the setup-help sections of source configuration forms.
/// Shared between `AppStoreSourceForm` (keyStep) and `EmailSourceForm` (mailStep)
/// to keep their step-list styling in sync.
struct SourceHelpStepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

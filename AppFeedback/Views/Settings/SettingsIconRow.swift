#if os(macOS)
import SwiftUI

/// System Settings-style sidebar row: an SF Symbol centered on a small colored
/// rounded-rect tile, followed by the pane title.
struct SettingsIconRow: View {
    let title: String
    let systemImage: String
    let tileColor: Color

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tileColor.gradient)
                    .frame(width: 24, height: 24)
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(title)
        }
        .padding(.vertical, 1)
    }
}
#endif

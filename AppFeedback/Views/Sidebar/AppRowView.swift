import SwiftUI

struct AppRowView: View {
    let label: String
    let count: Int
    /// Color of the leading dot only.
    let color: Color
    let isSelected: Bool
    /// Tint for the selected label/badge. Kept independent of `color` so recoloring the
    /// dot doesn't theme the whole row.
    var selectionTint: Color = .accentColor

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: isSelected ? color : .clear, radius: 4)
            Text(label)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? selectionTint : .primary)
                .lineLimit(1)
            Spacer()
            Text("\(count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? selectionTint : .secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    isSelected
                        ? selectionTint.opacity(0.12)
                        : Color.secondary.opacity(0.08),
                    in: Capsule()
                )
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

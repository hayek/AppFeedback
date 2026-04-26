import SwiftUI

struct AppRowView: View {
    let label: String
    let count: Int
    let color: Color
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: isSelected ? color : .clear, radius: 4)
            Text(label)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? color : .primary)
                .lineLimit(1)
            Spacer()
            Text("\(count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? color : .secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    isSelected
                        ? color.opacity(0.12)
                        : Color.secondary.opacity(0.08),
                    in: Capsule()
                )
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

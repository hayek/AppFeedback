import SwiftUI

// MARK: - Semantic colors

extension TaskStatus {
    /// Accent color used for the status dot, chip tint, and the card's left edge bar.
    var accent: Color {
        switch self {
        case .todo:       return Color(red: 0.56, green: 0.58, blue: 0.62)   // calm graphite
        case .inProgress: return Color(red: 0.98, green: 0.69, blue: 0.22)   // amber
        case .done:       return Color(red: 0.30, green: 0.80, blue: 0.50)   // green
        }
    }
}

extension TaskPriority {
    var accent: Color {
        switch self {
        case .low:  return Color(red: 0.45, green: 0.78, blue: 0.58)         // soft green
        case .med:  return Color(red: 0.97, green: 0.74, blue: 0.28)         // amber
        case .high: return Color(red: 0.95, green: 0.42, blue: 0.38)         // coral red
        }
    }
}

extension VersionState {
    var title: String {
        switch self {
        case .new:      return "New"
        case .wip:      return "In Progress"
        case .released: return "Released"
        }
    }
    var accent: Color {
        switch self {
        case .new:      return Color(red: 0.56, green: 0.58, blue: 0.62)
        case .wip:      return Color(red: 0.98, green: 0.69, blue: 0.22)
        case .released: return Color(red: 0.30, green: 0.80, blue: 0.50)
        }
    }
    var symbol: String {
        switch self {
        case .new:      return "sparkles"
        case .wip:      return "hammer.fill"
        case .released: return "checkmark.seal.fill"
        }
    }
}

// MARK: - Surface tokens

private enum Surface {
    static let cardRadius: CGFloat = 12
    static func cardFill(_ hovering: Bool) -> Color { Color.primary.opacity(hovering ? 0.07 : 0.04) }
    static let hairline = Color.primary.opacity(0.07)
}

// MARK: - Section header

struct PanelSectionHeader: View {
    let title: String
    var count: Int = 0
    var addLabel: String? = nil
    var add: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 7) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(1.1)
                .foregroundStyle(.secondary)
            if count > 0 {
                Text("\(count)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            Spacer(minLength: 0)
            if let addLabel, let add {
                Button(action: add) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                        Text(addLabel).font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.13)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Add action (New Task / New Version)

struct PanelAddButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(hovering ? 0.18 : 0.11))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.20), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

// MARK: - Empty state

struct PanelEmptyState: View {
    let icon: String
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.leading, 2)
    }
}

// MARK: - Chip menu (status / priority on a task card)

struct ChipMenu<Value: Hashable>: View {
    let label: String
    let dot: Color
    let options: [Value]
    let title: (Value) -> String
    let onSelect: (Value) -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button(title(option)) { onSelect(option) }
            }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(dot).frame(width: 6, height: 6)
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
            .contentShape(Capsule())
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Task card

struct TaskCard: View {
    let task: TaskItem
    let onStatus: (TaskStatus) -> Void
    let onPriority: (TaskPriority) -> Void
    var onOpen: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("#\(task.number)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                Text(task.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovering ? .secondary : .tertiary)
            }
            HStack(spacing: 6) {
                ChipMenu(label: task.status.displayName, dot: task.status.accent,
                         options: TaskStatus.allCases, title: { $0.displayName }, onSelect: onStatus)
                ChipMenu(label: task.priority.displayName, dot: task.priority.accent,
                         options: TaskPriority.allCases, title: { $0.displayName }, onSelect: onPriority)
                Spacer(minLength: 0)
                if !task.feedbackRefs.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "link").font(.system(size: 9, weight: .semibold))
                        Text("\(task.feedbackRefs.count)").font(.caption2.weight(.semibold).monospacedDigit())
                    }
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 11)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .background(
            RoundedRectangle(cornerRadius: Surface.cardRadius, style: .continuous)
                .fill(Surface.cardFill(hovering))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Surface.cardRadius, style: .continuous)
                .strokeBorder(Surface.hairline, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            Capsule()
                .fill(task.status.accent)
                .frame(width: 3)
                .padding(.vertical, 11)
                .padding(.leading, 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: Surface.cardRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Surface.cardRadius, style: .continuous))
        .onTapGesture { onOpen() }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

// MARK: - Version card

struct VersionStatePill: View {
    let state: VersionState
    var body: some View {
        Text(state.title.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(state.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(state.accent.opacity(0.15)))
    }
}

struct VersionCard: View {
    let name: String
    let state: VersionState
    let taskCount: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(state.accent.opacity(0.15)).frame(width: 30, height: 30)
                    Image(systemName: state.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(state.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("\(taskCount) task\(taskCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                VersionStatePill(state: state)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 11)
            .background(
                RoundedRectangle(cornerRadius: Surface.cardRadius, style: .continuous)
                    .fill(Surface.cardFill(hovering))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Surface.cardRadius, style: .continuous)
                    .strokeBorder(Surface.hairline, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Surface.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

// MARK: - Selectable chip (used in the New Task sheet)

struct SelectChip: View {
    let title: String
    let tint: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(title).font(.subheadline.weight(.medium))
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(selected ? tint.opacity(0.20) : Color.primary.opacity(0.05)))
            .overlay(Capsule().strokeBorder(selected ? tint.opacity(0.55) : Color.primary.opacity(0.07), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

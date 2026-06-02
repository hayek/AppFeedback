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
    /// When set, a just-created task shows its creation badge (a green "Created ✓") in the
    /// trailing slot for a few seconds before reverting to the normal chevron.
    var creationBadge: CreationPhase? = nil
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
                if let creationBadge {
                    CreationBadge(phase: creationBadge)
                        .transition(.opacity)   // the label fades out when it clears
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hovering ? .secondary : .tertiary)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.4), value: creationBadge)   // fade the label in/out
            HStack(spacing: 6) {
                ChipMenu(label: task.status.displayName, dot: task.status.accent,
                         options: TaskStatus.allCases, title: { $0.displayName }, onSelect: onStatus)
                ChipMenu(label: task.priority.displayName, dot: task.priority.accent,
                         options: TaskPriority.allCases, title: { $0.displayName }, onSelect: onPriority)
                Spacer(minLength: 0)
                if let version = task.milestoneTitle, !version.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "shippingbox").font(.system(size: 9))
                        Text(version).font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                }
                if !task.feedbackRefs.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "link").font(.system(size: 9, weight: .semibold))
                        Text("\(task.feedbackRefs.count)").font(.caption2.weight(.semibold).monospacedDigit())
                    }
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 11)
        .padding(.horizontal, 13)
        .background(
            RoundedRectangle(cornerRadius: Surface.cardRadius, style: .continuous)
                .fill(Surface.cardFill(hovering))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Surface.cardRadius, style: .continuous)
                .strokeBorder(Surface.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Surface.cardRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Surface.cardRadius, style: .continuous))
        .onTapGesture { onOpen() }
        .onDrag { NSItemProvider(object: "\(task.number)" as NSString) }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

// MARK: - Optimistic creation card (tasks & versions)

/// The creation-status pill shown on a task or version card: a "Creating…" shimmer (mirroring
/// the mail "Sending…" badge), a green animated checkmark on success, or a red "Failed".
struct CreationBadge: View {
    let phase: CreationPhase

    var body: some View {
        content
            .font(.system(size: 11, weight: .medium))
            .animation(.easeInOut(duration: 0.3), value: phase)   // match the List's row animation
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .creating:
            HStack(spacing: 3) {
                Image(systemName: "hourglass")
                ShimmerText("Creating…")
            }
            .foregroundStyle(.secondary)
            .transition(.opacity)
        case .created:
            HStack(spacing: 3) {
                CreatedCheckmark()
                Text("Created")
            }
            .foregroundStyle(TaskStatus.done.accent)   // the same green as a done task
            .transition(.opacity)
        case .failed:
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Failed")
            }
            .foregroundStyle(.red)
            .transition(.opacity)
        }
    }
}

/// A bold green checkmark (no enclosing circle) that springs in once — the "created" moment.
/// The spring's overshoot gives a single satisfying pop; it appears only on the real card
/// (the placeholder keeps showing "Creating…"), so it never animates twice.
private struct CreatedCheckmark: View {
    @State private var shown = false
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 12, weight: .bold))
            .scaleEffect(shown ? 1 : 0.2)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) { shown = true }
            }
    }
}

/// The reason + Retry / Dismiss controls shown on a failed creation card (task or version).
struct CreationFailedActions: View {
    let reason: String
    var onRetry: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(reason)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Button(action: onRetry) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .bold))
                        Text("Retry").font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                Button(action: onDismiss) {
                    Text("Dismiss").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A task card stand-in shown the instant the user taps Create, before GitHub confirms the
/// issue. Carries the entered draft and a `CreationBadge`; on failure it shows the reason
/// inline with Retry / Dismiss. Once the badge clears (or a retry succeeds), it's removed and
/// the real `TaskCard` takes its place.
struct PendingTaskCard: View {
    let creation: TaskCreation
    var onRetry: () -> Void = {}
    var onDismiss: () -> Void = {}

    private var draft: TaskDraft { creation.draft }
    private var isCreating: Bool { creation.phase == .creating }

    /// A placeholder stands in until the real card arrives, so it never shows the green
    /// "Created ✓" — that animates once, on the real card. While the write has actually
    /// succeeded (`.created`) but the issue hasn't reloaded yet, keep showing "Creating…".
    private var displayPhase: CreationPhase {
        if case .failed = creation.phase { return creation.phase }
        return .creating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(draft.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                CreationBadge(phase: displayPhase)
            }
            HStack(spacing: 6) {
                StaticChip(label: draft.status.displayName, dot: draft.status.accent)
                StaticChip(label: draft.priority.displayName, dot: draft.priority.accent)
                Spacer(minLength: 0)
                if let version = draft.milestoneTitle, !version.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "shippingbox").font(.system(size: 9))
                        Text(version).font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                }
            }
            if case .failed(let reason) = creation.phase {
                CreationFailedActions(reason: reason, onRetry: onRetry, onDismiss: onDismiss)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 11)
        .padding(.horizontal, 13)
        .background(
            RoundedRectangle(cornerRadius: Surface.cardRadius, style: .continuous)
                .fill(Surface.cardFill(false))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Surface.cardRadius, style: .continuous)
                .strokeBorder(Surface.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Surface.cardRadius, style: .continuous))
        .opacity(isCreating ? 0.9 : 1)   // a touch dim while it's not yet a real task
    }
}

/// A non-interactive twin of `ChipMenu`'s label — the status/priority pill on a pending card,
/// which can't be edited until the task actually exists.
private struct StaticChip: View {
    let label: String
    let dot: Color
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
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
    /// When set, a just-created version shows its creation badge (a green "Created ✓") for a few
    /// seconds before reverting to the chevron — or, on `.failed`, a non-tappable card with Retry.
    var creationBadge: CreationPhase? = nil
    var onRetry: () -> Void = {}
    var onDismiss: () -> Void = {}
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        if case .failed(let reason) = creationBadge {
            failedCard(reason: reason)
        } else {
            Button(action: action) { cardContent }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.14), value: hovering)
        }
    }

    private var cardContent: some View {
        HStack(spacing: 12) {
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
            if let creationBadge {
                CreationBadge(phase: creationBadge)
                    .transition(.opacity)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: creationBadge)   // fade the label in/out
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .background(cardSurface)
        .contentShape(RoundedRectangle(cornerRadius: Surface.cardRadius, style: .continuous))
    }

    private func failedCard(reason: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                CreationBadge(phase: .failed(reason))
            }
            CreationFailedActions(reason: reason, onRetry: onRetry, onDismiss: onDismiss)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 11)
        .padding(.horizontal, 11)
        .background(cardSurface)
    }

    private var cardSurface: some View {
        RoundedRectangle(cornerRadius: Surface.cardRadius, style: .continuous)
            .fill(Surface.cardFill(hovering))
            .overlay(
                RoundedRectangle(cornerRadius: Surface.cardRadius, style: .continuous)
                    .strokeBorder(Surface.hairline, lineWidth: 1)
            )
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

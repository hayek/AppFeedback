import SwiftUI

/// One-tap AI triage suggestion shown on a feedback card: assign to an existing
/// task or create a proposed one. Pending records only.
struct TriageSuggestionChip: View {
    let record: TriageVerdictRecord
    /// Title of the assign-target task, when it exists in the loaded task list.
    /// nil (task deleted / create-new suggestion) falls back to the number-only label.
    var taskTitle: String? = nil
    /// True while this suggestion's accept is in flight; disables Add and shows a spinner
    /// in its place so a double-tap can't fire two GitHub creates/assigns.
    var isAccepting: Bool = false
    let onAccept: () -> Void
    let onDismiss: () -> Void
    /// Opens the assign-target task. nil hides the open button.
    var onOpenTask: (() -> Void)? = nil

    private var label: String {
        if let n = record.suggestedTaskNumber {
            if let taskTitle {
                return "Assign to #\(n) · \(taskTitle)"
            }
            return "Assign to task #\(n)"
        }
        return "New task: \(record.suggestedTitle ?? "Untitled")"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            Text(label)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let onOpenTask {
                Button(action: onOpenTask) {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .help("Open task")
            }
            if isAccepting {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Button("Add", action: onAccept)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .disabled(isAccepting)
            .help("Dismiss suggestion")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

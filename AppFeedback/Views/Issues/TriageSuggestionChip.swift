import SwiftUI

/// One-tap AI triage suggestion shown on a feedback card: assign to an existing
/// task or create a proposed one. Pending records only.
struct TriageSuggestionChip: View {
    let record: TriageVerdictRecord
    let onAccept: () -> Void
    let onDismiss: () -> Void

    private var label: String {
        if let n = record.suggestedTaskNumber {
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
            Spacer(minLength: 4)
            Button("Add", action: onAccept)
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .help("Dismiss suggestion")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

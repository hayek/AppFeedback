import SwiftUI

struct UnreadSummaryView: View {
    let state: SummaryState
    let collapseKey: String
    /// Matches ``IssueListViewModel/aiSummarizesUnreadIssuesOnly`` — drives loading copy only.
    var summarizesUnreadIssues: Bool = false
    var onRetry: () -> Void = {}

    @AppStorage private var collapsed: Bool

    init(
        state: SummaryState,
        collapseKey: String,
        summarizesUnreadIssues: Bool = false,
        onRetry: @escaping () -> Void = {}
    ) {
        self.state = state
        self.collapseKey = collapseKey
        self.summarizesUnreadIssues = summarizesUnreadIssues
        self.onRetry = onRetry
        self._collapsed = AppStorage(wrappedValue: false, "summary.collapsed.\(collapseKey)")
    }

    var body: some View {
        switch state {
        case .skipped, .unavailable, .idle:
            EmptyView()
        case .loading:
            card {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(
                        summarizesUnreadIssues
                            ? "Summarizing unread feedback…"
                            : "Summarizing last 30 days of feedback…"
                    )
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            card {
                HStack {
                    Text("Couldn't generate summary — \(message)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry", action: onRetry)
                        .font(.system(size: 12, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                }
            }
        case .ready(let summary):
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        collapsed.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.tint)
                            Text(summary.headline)
                                .font(.system(size: 13, weight: .semibold))
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if !collapsed {
                        VStack(alignment: .leading, spacing: 12) {
                            prosConsSection(title: "Pros", text: summary.pros, tint: Color.green.opacity(0.82))
                            prosConsSection(title: "Cons", text: summary.cons, tint: Color.red.opacity(0.78))
                        }
                        .transition(.opacity)
                    }
                }
            }
            .animation(.default, value: collapsed)
        }
    }

    @ViewBuilder
    private func prosConsSection(title: String, text: String, tint: Color) -> some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            VStack(alignment: .leading, spacing: 11) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.3)
                    .foregroundStyle(tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(tint.opacity(0.18), in: Capsule())

                Text(trimmed)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                tint.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(tint.opacity(0.32), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.tint.opacity(0.2), lineWidth: 0.5)
            )
    }
}

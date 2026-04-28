import SwiftUI

struct UnreadSummaryView: View {
    let state: SummaryState
    let collapseKey: String
    var onRetry: () -> Void = {}

    @AppStorage private var collapsed: Bool

    init(state: SummaryState, collapseKey: String, onRetry: @escaping () -> Void = {}) {
        self.state = state
        self.collapseKey = collapseKey
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
                    Text("Summarizing unread issues…")
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
                VStack(alignment: .leading, spacing: 8) {
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
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(summary.bullets.enumerated()), id: \.offset) { _, bullet in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("•").foregroundStyle(.tertiary)
                                    Text(bullet.text)
                                        .font(.system(size: 12))
                                    Spacer()
                                    Text("\(bullet.issueCount)")
                                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(.secondary.opacity(0.12), in: Capsule())
                                }
                            }
                        }
                    }
                }
            }
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

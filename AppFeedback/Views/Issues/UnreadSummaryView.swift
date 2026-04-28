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

                    if !collapsed, !summary.sections.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(summary.sections.enumerated()), id: \.offset) { _, section in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(section.title)
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(section.body)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.top, 2)
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

import SwiftUI

struct IssueListView: View {
    @Bindable var viewModel: IssueListViewModel
    let loader: IssueLoader?
    let allApps: [String]
    var onRefresh: (() async -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.appFilter != nil {
                FilterBarView(viewModel: viewModel)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }

            if let message = staleBannerMessage {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text(message)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.08))
            }

            Group {
                switch loaderState {
                case .idle, .loading where viewModel.allIssues.isEmpty:
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let error):
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle).foregroundStyle(.red)
                        Text(error.localizedDescription).font(.body)
                        if let onRefresh {
                            Button("Retry") { Task { await onRefresh() } }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                default:
                    issueList
                }
            }
        }
        .searchable(text: $viewModel.searchQuery, prompt: "Search issues, apps, emails…")
        #if os(macOS)
        .background(Color(NSColor.controlBackgroundColor))
        #else
        .background(Color(.systemBackground))
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Sort", selection: $viewModel.sortOrder) {
                    Text("Newest").tag(IssueListViewModel.SortOrder.newest)
                    Text("Oldest").tag(IssueListViewModel.SortOrder.oldest)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            if let onRefresh {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await onRefresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var issueList: some View {
        let visible = viewModel.visibleIssues
        if visible.isEmpty {
            Text("No issues found")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    HStack {
                        Text(summaryText(total: viewModel.allIssues.count, visible: visible.count))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 2)

                    ForEach(visible) { issue in
                        IssueCardView(
                            issue: issue,
                            appColor: ColorPalette.color(for: issue.appName ?? "", in: allApps)
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
    }

    private var loaderState: IssueLoader.State { loader?.state ?? .idle }

    private var staleBannerMessage: String? {
        guard let loader else { return nil }
        if case .loaded(_, let date) = loader.state, date == Date(timeIntervalSince1970: 0) {
            return "Showing cached data — refresh to update"
        }
        return nil
    }

    private func summaryText(total: Int, visible: Int) -> String {
        visible == total
            ? "\(total) issue\(total == 1 ? "" : "s")"
            : "\(visible) of \(total) issues"
    }
}

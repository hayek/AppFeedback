import SwiftUI

struct IssueListView: View {
    @Bindable var viewModel: IssueListViewModel
    let loader: IssueLoader?
    let allApps: [String]
    var onRefresh: (() async -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                    TextField("Search issues, apps, emails…", text: $viewModel.searchQuery)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                Picker("Sort", selection: $viewModel.sortOrder) {
                    Text("Newest").tag(IssueListViewModel.SortOrder.newest)
                    Text("Oldest").tag(IssueListViewModel.SortOrder.oldest)
                }
                .pickerStyle(.segmented)
                .fixedSize()

                if let onRefresh {
                    Button {
                        Task { await onRefresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if viewModel.appFilter != nil && !viewModel.filters.isEmpty {
                FilterBarView(viewModel: viewModel)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
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
        #if os(macOS)
        .background(Color(NSColor.controlBackgroundColor))
        #else
        .background(Color(.systemBackground))
        #endif
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

    private func summaryText(total: Int, visible: Int) -> String {
        visible == total
            ? "\(total) issue\(total == 1 ? "" : "s")"
            : "\(visible) of \(total) issues"
    }
}

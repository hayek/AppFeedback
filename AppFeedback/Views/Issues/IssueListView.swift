import SwiftUI

struct IssueListView: View {
    @Bindable var viewModel: IssueListViewModel
    let loader: IssueLoader?
    let allApps: [String]
    var onRefresh: (() async -> Void)?
    var repoOwner: String = ""
    var repoName: String = ""
    var appColorOverrides: [String: String] = [:]
    @Bindable var summaryVM: UnreadSummaryViewModel
    let summaryCollapseKey: String

    #if os(macOS)
    @State private var composing: ComposeContext?
    #endif

    var body: some View {
        VStack(spacing: 0) {
            if loader?.isShowingCachedData == true {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("Showing cached data — refresh to update")
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
                            Button("Retry") {
                                Task { await onRefresh() }
                            }
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
                    if viewModel.allowsAppFilter || viewModel.appFilter != nil || !viewModel.filters.isEmpty {
                        FilterBarView(viewModel: viewModel)
                    }

                    UnreadSummaryView(
                        state: summaryVM.state,
                        collapseKey: summaryCollapseKey
                    )
                    .padding(.horizontal, 2)

                    HStack {
                        Text(summaryText(total: viewModel.allIssues.count, visible: visible.count))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 2)

                    ForEach(visible) { issue in
                        issueCard(for: issue)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .task(id: summaryTaskID) {
                    await summaryVM.update(
                        unread: viewModel.unreadIssues,
                        targetLanguage: viewModel.intelligenceSettings?.targetLanguageCode ?? "en"
                    )
                }
            }
            #if os(macOS)
            .sheet(item: $composing) { ctx in
                ComposeMailView(
                    recipient: ctx.recipient,
                    issue: ctx.issue,
                    repoOwner: repoOwner,
                    repoName: repoName
                )
            }
            #endif
        }
    }

    private func appColor(for appName: String) -> Color {
        if let hex = appColorOverrides[appName] {
            return Color(hex: hex)
        }
        return ColorPalette.color(for: appName, in: allApps)
    }

    @ViewBuilder
    private func issueCard(for issue: FeedbackIssue) -> some View {
        #if os(macOS)
        IssueCardView(
            issue: issue,
            appColor: appColor(for: issue.appName ?? ""),
            isUnread: viewModel.isUnread(issue),
            onInteract: { viewModel.markSeen(issue) },
            activeApp: viewModel.appFilter,
            activeAppVersion: viewModel.filters.appVersion,
            activeDevice: viewModel.filters.device,
            activeOSVersion: viewModel.filters.osVersion,
            onToggleApp: { value in
                viewModel.appFilter = viewModel.appFilter == value ? nil : value
            },
            onToggleAppVersion: { value in
                viewModel.filters.appVersion = viewModel.filters.appVersion == value ? nil : value
            },
            onToggleDevice: { value in
                viewModel.filters.device = viewModel.filters.device == value ? nil : value
            },
            onToggleOSVersion: { value in
                viewModel.filters.osVersion = viewModel.filters.osVersion == value ? nil : value
            },
            activeIssueType: viewModel.filters.issueType,
            onToggleIssueType: { type in
                viewModel.filters.issueType = viewModel.filters.issueType == type ? nil : type
            },
            onTapEmail: { email in
                composing = ComposeContext(recipient: email, issue: issue)
            },
            intelligenceAvailable: viewModel.intelligenceProvider?.availability.isReady ?? false,
            targetLanguageCode: viewModel.intelligenceSettings?.targetLanguageCode ?? "en"
        )
        #else
        IssueCardView(
            issue: issue,
            appColor: appColor(for: issue.appName ?? ""),
            isUnread: viewModel.isUnread(issue),
            onInteract: { viewModel.markSeen(issue) },
            activeApp: viewModel.appFilter,
            activeAppVersion: viewModel.filters.appVersion,
            activeDevice: viewModel.filters.device,
            activeOSVersion: viewModel.filters.osVersion,
            onToggleApp: { value in
                viewModel.appFilter = viewModel.appFilter == value ? nil : value
            },
            onToggleAppVersion: { value in
                viewModel.filters.appVersion = viewModel.filters.appVersion == value ? nil : value
            },
            onToggleDevice: { value in
                viewModel.filters.device = viewModel.filters.device == value ? nil : value
            },
            onToggleOSVersion: { value in
                viewModel.filters.osVersion = viewModel.filters.osVersion == value ? nil : value
            },
            activeIssueType: viewModel.filters.issueType,
            onToggleIssueType: { type in
                viewModel.filters.issueType = viewModel.filters.issueType == type ? nil : type
            },
            intelligenceAvailable: viewModel.intelligenceProvider?.availability.isReady ?? false,
            targetLanguageCode: viewModel.intelligenceSettings?.targetLanguageCode ?? "en"
        )
        #endif
    }

    private var loaderState: IssueLoader.State { loader?.state ?? .idle }

    private var summaryTaskID: String {
        let unread = viewModel.unreadIssues.map(\.number).sorted().map(String.init).joined(separator: ",")
        let lang = viewModel.intelligenceSettings?.targetLanguageCode ?? "en"
        return "\(lang)|\(unread)"
    }

    private func summaryText(total: Int, visible: Int) -> String {
        visible == total
            ? "\(total) issue\(total == 1 ? "" : "s")"
            : "\(visible) of \(total) issues"
    }
}

#if os(macOS)
struct ComposeContext: Identifiable {
    let id = UUID()
    let recipient: String
    let issue: FeedbackIssue
}
#endif

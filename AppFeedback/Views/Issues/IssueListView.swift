import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct IssueListView: View {
    @Bindable var viewModel: IssueListViewModel
    let loader: IssueLoader?
    let allApps: [String]
    var onRefresh: (() async -> Void)?
    /// Attach a task to a feedback by dragging a task card onto a feedback row: (taskNumber, feedbackNumber).
    var onDropTask: ((Int, Int) -> Void)? = nil
    @State private var dropTargetNumber: Int?
    /// Surfaces a failed triage-accept write (offline, expired token) so the failure isn't silent —
    /// the record stays `.pending` on failure, so the chip remains for retry. Mirrors RootView's
    /// `writeError` pattern for other GitHub write failures.
    @State private var triageAcceptError: String?
    /// Tasks attached to each feedback (by feedback number), shown as clickable tags.
    var attachedTasksByFeedback: [Int: [TaskItem]] = [:]
    /// Release state per version name, used to color the version badge on task tags.
    var versionStates: [String: VersionState] = [:]
    var onOpenTask: ((TaskItem) -> Void)? = nil
    /// Detach a task from a feedback (tap the × on a tag): (taskNumber, feedbackNumber).
    var onRemoveTaskFromFeedback: ((Int, Int) -> Void)? = nil
    var repoOwner: String = ""
    var repoName: String = ""
    /// Accent color chosen for this repo, applied to feedback dots and UI tint. `nil` = system accent.
    var repoAccent: Color? = nil
    @Bindable var summaryVM: UnreadSummaryViewModel
    let summaryCollapseKey: String
    /// Phase 3's CloudKit-synced mirror store (read response state, persist write-back).
    var mirrorStore: AppStoreReviewMirrorStore? = nil
    /// Resolves the App Store responder context (client + read-only + owner/repo) for a product;
    /// nil ⇒ that product has no App Store source. Backed by Phase 3's registry (async).
    var appStoreResponder: ((UUID) async -> AppStoreResponderContext?)? = nil
    /// One response controller per App Store feedback (keyed on issue number). Cached so the
    /// editor draft survives re-renders triggered by `mirrorStore.version` bumps. Built lazily.
    @State private var responseControllers: [Int: AppStoreResponseController] = [:]
    /// Issue numbers for which a controller-build Task is already in flight. Guards against
    /// spawning multiple concurrent Tasks for the same issue across rapid render passes.
    @State private var buildingControllers: Set<Int> = []
    /// This repo's config, used for the AI triage backfill action and accepting suggestions.
    /// `nil` when the caller hasn't resolved the selected product yet.
    var repoConfig: ProductConfig? = nil
    /// Invoked after a triage suggestion is accepted (assign/create), mirroring the refresh
    /// RootView performs after any other task creation so the change appears in the list.
    var onTriageApplied: (() async -> Void)? = nil

    @Environment(FeedbackTriageCoordinator.self) private var triageCoordinator
    @Environment(TriageSettings.self) private var triageSettings
    @Environment(IntelligenceService.self) private var intelligenceService

    @AppStorage private var summaryCollapsed: Bool

    /// Reactive view of cloud-synced summary rows so devices without on-device
    /// Foundation Models re-evaluate when CloudKit delivers a row written by another device.
    @Query private var summaryCaches: [IssueSummaryCache]

    init(
        viewModel: IssueListViewModel,
        loader: IssueLoader?,
        allApps: [String],
        onRefresh: (() async -> Void)? = nil,
        onDropTask: ((Int, Int) -> Void)? = nil,
        attachedTasksByFeedback: [Int: [TaskItem]] = [:],
        versionStates: [String: VersionState] = [:],
        onOpenTask: ((TaskItem) -> Void)? = nil,
        onRemoveTaskFromFeedback: ((Int, Int) -> Void)? = nil,
        repoOwner: String = "",
        repoName: String = "",
        repoAccent: Color? = nil,
        summaryVM: UnreadSummaryViewModel,
        summaryCollapseKey: String,
        mirrorStore: AppStoreReviewMirrorStore? = nil,
        appStoreResponder: ((UUID) async -> AppStoreResponderContext?)? = nil,
        repoConfig: ProductConfig? = nil,
        onTriageApplied: (() async -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.loader = loader
        self.allApps = allApps
        self.onRefresh = onRefresh
        self.onDropTask = onDropTask
        self.attachedTasksByFeedback = attachedTasksByFeedback
        self.versionStates = versionStates
        self.onOpenTask = onOpenTask
        self.onRemoveTaskFromFeedback = onRemoveTaskFromFeedback
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.repoAccent = repoAccent
        self.summaryVM = summaryVM
        self.summaryCollapseKey = summaryCollapseKey
        self.mirrorStore = mirrorStore
        self.appStoreResponder = appStoreResponder
        self.repoConfig = repoConfig
        self.onTriageApplied = onTriageApplied
        self._summaryCollapsed = AppStorage(wrappedValue: false, "summary.collapsed.\(summaryCollapseKey)")
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch loaderState {
                case .idle where viewModel.allIssues.isEmpty,
                     .loading where viewModel.allIssues.isEmpty:
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
        .background(TranslationHost(viewModel: viewModel))
        .searchable(text: $viewModel.searchQuery, prompt: "Search issues, apps, emails…")
        #if os(macOS)
        .background(Color(NSColor.controlBackgroundColor))
        #else
        .background(Color(.systemBackground))
        #endif
        .refreshable {
            await onRefresh?()
        }
        .alert("Couldn't complete", isPresented: Binding(
            get: { triageAcceptError != nil },
            set: { if !$0 { triageAcceptError = nil } }
        )) {
            Button("OK", role: .cancel) { triageAcceptError = nil }
        } message: {
            Text(triageAcceptError ?? "")
        }
        #if os(macOS)
        .toolbar {
            if let onRefresh {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await onRefresh() }
                    } label: {
                        if showsRefreshSpinner {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(showsRefreshSpinner)
                }
            }
        }
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    guard let repoConfig else { return }
                    Task { await triageCoordinator.runBackfill(repo: repoConfig, issues: viewModel.allIssues) }
                } label: {
                    if triageCoordinator.isProcessing {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.small)
                            if let progress = triageCoordinator.progress {
                                Text("\(progress.done)/\(progress.total)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Image(systemName: "sparkles")
                    }
                }
                .disabled(
                    repoConfig == nil
                        || triageSettings.mode == .off
                        || !intelligenceService.availability.isReady
                        || triageCoordinator.isProcessing
                )
                .help("Triage Feedback with AI")
            }
        }
    }

    @ViewBuilder
    private var issueList: some View {
        let visible = viewModel.visibleIssues
        let hasActiveFilter = !viewModel.appFilter.isEmpty || !viewModel.filters.isEmpty
        let showsFilterBar = !viewModel.allIssues.isEmpty || hasActiveFilter
        let summariesEnabled = viewModel.intelligenceSettings?.summariesEnabled ?? true
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if summariesEnabled {
                        UnreadSummaryView(
                            state: summaryVM.state,
                            collapsed: $summaryCollapsed,
                            summarizesUnreadIssues: viewModel.aiSummarizesUnreadIssuesOnly
                        )
                        .padding(.horizontal, 2)
                    }

                    if showsFilterBar {
                        FilterBarView(viewModel: viewModel, accent: filterAccent)
                    }

                    if visible.isEmpty {
                        Text("No issues found")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                    } else {
                        HStack {
                            Text(summaryText(total: viewModel.allIssues.count, visible: visible.count))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 2)

                        ForEach(visible) { issue in
                            issueCard(for: issue)
                            .overlay {
                                if dropTargetNumber == issue.number {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(Color.accentColor, lineWidth: 2)
                                }
                            }
                            .onDrop(of: [.text], isTargeted: Binding(
                                get: { dropTargetNumber == issue.number },
                                set: { dropTargetNumber = ($0 && onDropTask != nil) ? issue.number : nil }
                            )) { providers in
                                guard onDropTask != nil, let provider = providers.first else { return false }
                                let feedbackNumber = issue.number
                                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                                    if let string = object as? String, let taskNumber = Int(string) {
                                        Task { @MainActor in onDropTask?(taskNumber, feedbackNumber) }
                                    }
                                }
                                return true
                            }
                            .id(issue.number)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .animation(.default, value: summaryCollapsed)
                .task(id: summaryTaskID) {
                    guard summariesEnabled else { return }
                    let context: AISummaryPromptContext = viewModel.aiSummarizesUnreadIssuesOnly
                        ? .unreadIssues : .rollingLastThirtyDays
                    await summaryVM.update(
                        issues: viewModel.issuesForAISummaryCard,
                        targetLanguage: targetLanguageCode,
                        promptContext: context,
                        cache: viewModel.summaryCacheBinding(targetLanguage: targetLanguageCode)
                    )
                }
            }
            .onChange(of: viewModel.highlightedIssueNumber) { _, newValue in
                guard let number = newValue else { return }
                withAnimation {
                    proxy.scrollTo(number, anchor: .top)
                }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    viewModel.highlightedIssueNumber = nil
                }
            }
        }
    }

    private var filterAccent: Color {
        if !viewModel.allowsAppFilter, let onlyApp = viewModel.appFilter.first {
            return appColor(for: onlyApp)
        }
        return repoAccent ?? .accentColor
    }

    private func appColor(for appName: String) -> Color {
        if let repoAccent { return repoAccent }
        return ColorPalette.color(for: appName, in: allApps)
    }

    /// Returns the cached controller for an App Store issue, building it once (asynchronously).
    /// Returns nil for SDK/email items, when the mirror/responder deps are absent, when the
    /// reviewId marker is missing, or when the product has no App Store source (graceful nil —
    /// the panel hides). The first call returns nil and fires a Task that populates the cache;
    /// the resulting @State mutation triggers a re-render so the panel appears on the next pass.
    ///
    /// `buildingControllers` acts as an in-flight guard: once a Task is spawned for a given
    /// issue number it is inserted into the set; subsequent render passes that reach this code
    /// path (before the Task completes) skip spawning a second Task, bounding the build to at
    /// most one concurrent Task per issue and preventing cache-slot races.
    private func responseController(for issue: FeedbackIssue) -> AppStoreResponseController? {
        guard issue.source == .appStore else { return nil }
        if let cached = responseControllers[issue.number] { return cached }
        // Build asynchronously (responderContext is async); controller will appear on next render.
        // Skip if a build Task is already in flight for this issue number.
        guard !buildingControllers.contains(issue.number),
              let mirrorStore,
              let appStoreResponder,
              let reviewId = AppStoreReviewIdExtractor.reviewId(fromBody: issue.rawBody),
              let productID = mirrorStore.mirror(reviewId: reviewId)?.productID else { return nil }
        let issueNumber = issue.number
        Task { @MainActor in
            // Insert here — deferred into the Task so this mutation does NOT occur during
            // view body evaluation (SwiftUI forbids @State mutations during body computation).
            buildingControllers.insert(issueNumber)
            defer { buildingControllers.remove(issueNumber) }
            guard let context = await appStoreResponder(productID) else { return }
            let controller = AppStoreResponseController(
                reviewId: reviewId,
                productID: productID,
                issueNumber: issueNumber,
                repoOwner: context.owner,
                repoName: context.repo,
                client: context.client,
                mirrorStore: mirrorStore,
                commentPoster: GitHubCommentPoster(),
                tokenLoader: { [owner = context.owner, repo = context.repo] in
                    await KeychainService.load(for: ProductConfig(displayName: repo, owner: owner, repo: repo))
                },
                readOnly: context.isReadOnly,
                onReadOnly: context.onReadOnly)
            responseControllers[issueNumber] = controller
        }
        return nil
    }

    @ViewBuilder
    private func issueCard(for issue: FeedbackIssue) -> some View {
        let suggestion = triageCoordinator.pendingSuggestion(owner: repoOwner, repo: repoName, number: issue.number)
        IssueCardView(
            issue: issue,
            repoOwner: repoOwner,
            repoName: repoName,
            appColor: appColor(for: issue.appName ?? ""),
            isUnread: viewModel.isUnread(issue),
            onInteract: { viewModel.markSeen(issue) },
            activeApp: viewModel.appFilter,
            activeAppVersion: viewModel.filters.appVersion,
            activeDevice: viewModel.filters.device,
            activeOSVersion: viewModel.filters.osVersion,
            onToggleApp: { value in
                viewModel.appFilter.toggleMembership(value)
            },
            onToggleAppVersion: { value in
                viewModel.filters.appVersion.toggleMembership(value)
            },
            onToggleDevice: { value in
                viewModel.filters.device.toggleMembership(value)
            },
            onToggleOSVersion: { value in
                viewModel.filters.osVersion.toggleMembership(value)
            },
            activeIssueType: viewModel.filters.issueType,
            onToggleIssueType: { type in
                viewModel.filters.issueType.toggleMembership(type)
            },
            targetLanguageCode: targetLanguageCode,
            isTranslating: viewModel.isTranslating(issue),
            isHighlighted: viewModel.highlightedIssueNumber == issue.number,
            translationUnsupported: {
                guard let detected = issue.detectedLanguageCode, !detected.isEmpty else { return false }
                return viewModel.unsupportedSourceLanguages.contains(detected)
            }(),
            onRetranslate: { viewModel.forceRetranslate(issueNumber: issue.number) },
            needsDownloadLanguage: viewModel.needsLanguageDownload(issue),
            onRequestDownload: { viewModel.approveLanguageDownload(for: issue) },
            attachedTasks: attachedTasksByFeedback[issue.number] ?? [],
            versionStates: versionStates,
            onOpenTask: onOpenTask,
            onRemoveTask: onRemoveTaskFromFeedback.map { remove in { task in remove(task.number, issue.number) } },
            responseController: responseController(for: issue),
            triageSuggestion: suggestion,
            onAcceptSuggestion: (repoConfig.flatMap { config in suggestion.map { (config, $0) } }).map { config, record in
                {
                    Task {
                        do {
                            try await triageCoordinator.accept(record: record, repo: config, issues: viewModel.allIssues)
                            await onTriageApplied?()
                        } catch {
                            // Record stays .pending on failure — leave the chip in place for retry.
                            triageAcceptError = "Couldn't accept suggestion for #\(record.feedbackNumber): \(error.localizedDescription)"
                        }
                    }
                }
            },
            onDismissSuggestion: suggestion.map { record in
                { triageCoordinator.dismiss(record: record) }
            }
        )
    }

    private var loaderState: IssueLoader.State { loader?.state ?? .idle }

    private var showsRefreshSpinner: Bool {
        loader?.isInFlight == true
    }

    private var targetLanguageCode: String {
        viewModel.intelligenceSettings?.targetLanguageCode ?? IntelligenceSettings.systemLanguageCode()
    }

    private var summaryTaskID: String {
        let unread = UnreadSummaryViewModel.issueNumbersFingerprint(viewModel.unreadIssues)
        let window = UnreadSummaryViewModel.issueNumbersFingerprint(viewModel.issuesRecentForSummary)
        let mode = viewModel.aiSummarizesUnreadIssuesOnly ? "u" : "r"
        // Include the freshest matching cache row's updatedAt so .task re-fires when
        // CloudKit delivers a summary written by another device. `max(by:)` matches
        // `fetchSummaryRow`'s newest-wins semantics during CloudKit duplicate-row
        // sync convergence — otherwise the two could disagree and `cacheSig` oscillate.
        let cacheSig = summaryCaches
            .filter {
                $0.repoOwner == repoOwner
                    && $0.repoName == repoName
                    && $0.targetLanguage == targetLanguageCode
            }
            .max(by: { $0.updatedAt < $1.updatedAt })?
            .updatedAt.timeIntervalSince1970 ?? 0
        return "\(targetLanguageCode)|\(mode)|\(unread)|\(window)|\(cacheSig)"
    }

    private func summaryText(total: Int, visible: Int) -> String {
        visible == total
            ? "\(total) issue\(total == 1 ? "" : "s")"
            : "\(visible) of \(total) issues"
    }
}


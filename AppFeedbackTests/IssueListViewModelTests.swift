import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class IssueListViewModelTests: XCTestCase {

    private func makeIssue(
        number: Int,
        title: String = "Issue",
        appName: String? = "TestApp",
        appVersion: String? = "1.0",
        device: String? = "Mac",
        osVersion: String? = "14.0",
        email: String? = nil,
        daysAgo: Double = 0
    ) -> FeedbackIssue {
        FeedbackIssue(
            number: number, title: title,
            createdAt: Date().addingTimeInterval(-daysAgo * 86400),
            rawBody: "", appName: appName, appVersion: appVersion,
            device: device, osVersion: osVersion, email: email,
            description: "desc \(number)", labels: []
        )
    }

    func test_visibleIssues_noFilter_returnsAll() {
        let vm = IssueListViewModel()
        vm.allIssues = [makeIssue(number: 1), makeIssue(number: 2)]
        XCTAssertEqual(vm.visibleIssues.count, 2)
    }

    func test_visibleIssues_appFilter() {
        let vm = IssueListViewModel()
        vm.allIssues = [makeIssue(number: 1, appName: "A"), makeIssue(number: 2, appName: "B")]
        vm.appFilter = ["A"]
        XCTAssertEqual(vm.visibleIssues.count, 1)
        XCTAssertEqual(vm.visibleIssues.first?.number, 1)
    }

    func test_visibleIssues_versionPillFilter() {
        let vm = IssueListViewModel()
        vm.allIssues = [makeIssue(number: 1, appVersion: "1.0"), makeIssue(number: 2, appVersion: "2.0")]
        vm.filters.appVersion = ["1.0"]
        XCTAssertEqual(vm.visibleIssues.count, 1)
    }

    func test_visibleIssues_search_matchesTitle() {
        let vm = IssueListViewModel()
        vm.allIssues = [makeIssue(number: 1, title: "Crash on launch"), makeIssue(number: 2, title: "Dark mode")]
        vm.searchQuery = "crash"
        XCTAssertEqual(vm.visibleIssues.count, 1)
        XCTAssertEqual(vm.visibleIssues.first?.title, "Crash on launch")
    }

    func test_uniqueAppVersions_forCurrentApp() {
        let vm = IssueListViewModel()
        vm.allIssues = [
            makeIssue(number: 1, appName: "A", appVersion: "1.0"),
            makeIssue(number: 2, appName: "A", appVersion: "2.0"),
            makeIssue(number: 3, appName: "B", appVersion: "3.0"),
        ]
        vm.appFilter = ["A"]
        XCTAssertEqual(Set(vm.uniqueValues(for: \.appVersion)), ["1.0", "2.0"])
    }

    func test_hiddenApps_excludedFromVisibleIssues() {
        let vm = IssueListViewModel()
        vm.allIssues = [
            makeIssue(number: 1, appName: "Foo"),
            makeIssue(number: 2, appName: "Bar"),
            makeIssue(number: 3, appName: "Foo"),
        ]
        vm.hiddenApps = ["Foo"]
        let visible = vm.visibleIssues
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.number, 2)
    }

    func test_hiddenApps_excludedFromUniqueAppNames() {
        let vm = IssueListViewModel()
        vm.allIssues = [
            makeIssue(number: 1, appName: "Foo"),
            makeIssue(number: 2, appName: "Bar"),
        ]
        vm.hiddenApps = ["Foo"]
        XCTAssertEqual(vm.uniqueAppNames, ["Bar"])
        XCTAssertFalse(vm.uniqueAppNames.contains("Foo"))
    }

    func test_hiddenApps_excludedFromUniqueValues() {
        let vm = IssueListViewModel()
        vm.allIssues = [
            makeIssue(number: 1, appName: "Foo", appVersion: "2.0"),
            makeIssue(number: 2, appName: "Bar", appVersion: "1.0"),
        ]
        vm.hiddenApps = ["Foo"]
        XCTAssertEqual(vm.uniqueValues(for: \.appVersion), ["1.0"])
    }

    func test_hiddenApps_emptyByDefault() {
        let vm = IssueListViewModel()
        vm.allIssues = [makeIssue(number: 1, appName: "Foo"), makeIssue(number: 2, appName: "Bar")]
        XCTAssertEqual(vm.visibleIssues.count, 2)
    }

    func test_issuesRecentForSummary_ordersNewestWithinThirtyDays() {
        let vm = IssueListViewModel()
        vm.allIssues = [
            makeIssue(number: 10, title: "A", daysAgo: 10),
            makeIssue(number: 20, title: "B", daysAgo: 45),
            makeIssue(number: 30, title: "C", daysAgo: 1),
        ]
        XCTAssertEqual(vm.issuesRecentForSummary.map(\.number), [30, 10])
    }

    func test_issuesRecentForSummary_respectsHiddenApps() {
        let vm = IssueListViewModel()
        vm.allIssues = [
            makeIssue(number: 1, appName: "Hide", daysAgo: 5),
            makeIssue(number: 2, appName: "Show", daysAgo: 5),
        ]
        vm.hiddenApps = ["Hide"]
        XCTAssertEqual(vm.issuesRecentForSummary.map(\.number), [2])
    }

    func test_issuesForAISummary_prefersUnreadWhenTwoOrMore() throws {
        let vm = IssueListViewModel()
        vm.attachSeenStore(try makeStore(), owner: "o", repo: "r")
        let a = makeIssue(number: 1)
        let b = makeIssue(number: 2)
        vm.applyLoaded([a, b])
        XCTAssertTrue(vm.aiSummarizesUnreadIssuesOnly)
        XCTAssertEqual(Set(vm.issuesForAISummaryCard.map(\.number)), [1, 2])
    }

    func test_issuesForAISummary_usesRollingWhenUnreadBelowThreshold() throws {
        let vm = IssueListViewModel()
        vm.attachSeenStore(try makeStore(), owner: "o", repo: "r")
        vm.applyLoaded([makeIssue(number: 1), makeIssue(number: 2)])
        vm.markSeen(makeIssue(number: 1))
        XCTAssertFalse(vm.aiSummarizesUnreadIssuesOnly)
        XCTAssertEqual(vm.issuesForAISummaryCard.map(\.number), vm.issuesRecentForSummary.map(\.number))
    }

    func test_hiddenApps_excludedFromUnreadIssues() throws {
        let vm = IssueListViewModel()
        vm.attachSeenStore(try makeStore(), owner: "o", repo: "r")
        vm.allIssues = [
            makeIssue(number: 10, appName: "Foo"),
            makeIssue(number: 11, appName: "Bar"),
        ]
        vm.hiddenApps = ["Foo"]
        vm.applyLoaded(vm.allIssues) // marks both as unread
        let unread = vm.unreadIssues
        XCTAssertFalse(unread.contains(where: { $0.number == 10 }), "Foo issue should not be unread-visible")
        XCTAssertTrue(unread.contains(where: { $0.number == 11 }), "Bar issue should be unread-visible")
    }
}

@MainActor
extension IssueListViewModelTests {
    private func makeStore() throws -> SeenIssueStore {
        let schema = Schema([SeenIssue.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return SeenIssueStore(context: ModelContext(container))
    }

    private func issue(_ n: Int) -> FeedbackIssue {
        FeedbackIssue(
            number: n, title: "t\(n)",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(n)),
            rawBody: "", appName: nil, appVersion: nil,
            device: nil, osVersion: nil, email: nil, description: "", labels: []
        )
    }

    func test_applyLoaded_marksIssuesUnreadOnFirstLoad() throws {
        let vm = IssueListViewModel()
        vm.attachSeenStore(try makeStore(), owner: "o", repo: "r")
        vm.applyLoaded([issue(1), issue(2), issue(3)])
        XCTAssertTrue(vm.isUnread(issue(1)))
        XCTAssertTrue(vm.isUnread(issue(2)))
        XCTAssertTrue(vm.isUnread(issue(3)))
    }

    func test_applyLoaded_secondLoadFlushesPreviousAsSeen() throws {
        let vm = IssueListViewModel()
        let store = try makeStore()
        vm.attachSeenStore(store, owner: "o", repo: "r")
        vm.applyLoaded([issue(1), issue(2)])
        vm.applyLoaded([issue(1), issue(2), issue(3)]) // flushes 1,2 as seen
        XCTAssertFalse(vm.isUnread(issue(1)))
        XCTAssertFalse(vm.isUnread(issue(2)))
        XCTAssertTrue(vm.isUnread(issue(3)))
        XCTAssertEqual(store.seenNumbers(owner: "o", repo: "r"), [1, 2])
    }

    func test_markSeen_clearsDotImmediately() throws {
        let vm = IssueListViewModel()
        let store = try makeStore()
        vm.attachSeenStore(store, owner: "o", repo: "r")
        vm.applyLoaded([issue(1), issue(2)])
        vm.markSeen(issue(1))
        XCTAssertFalse(vm.isUnread(issue(1)))
        XCTAssertTrue(vm.isUnread(issue(2)))
        XCTAssertEqual(store.seenNumbers(owner: "o", repo: "r"), [1])
    }

    func test_isUnread_falseWhenNoStoreAttached() {
        let vm = IssueListViewModel()
        vm.applyLoaded([issue(1)])
        XCTAssertFalse(vm.isUnread(issue(1)))
    }

    func test_translation_skipsTargetLanguageIssues() {
        let settings = IntelligenceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.targetLanguageCode = "en"

        let vm = IssueListViewModel()
        let englishIssue = FeedbackIssue(
            number: 1,
            title: "Crash on launch when opening settings page repeatedly",
            createdAt: Date(),
            rawBody: "App crashes",
            appName: "App", appVersion: nil, device: nil, osVersion: nil, email: nil,
            description: "App crashes when I open settings repeatedly on macOS.",
            labels: []
        )
        vm.allIssues = [englishIssue]
        let context = ModelContext(try! ModelContainer(for: CachedIssue.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        vm.attachIntelligence(provider: MockIntelligenceProvider(), settings: settings, cacheContext: context)

        vm.startTranslationsIfNeeded()
        // An English issue with target "en" is the same language → never enqueued.
        XCTAssertTrue(vm.pendingTranslations.isEmpty)
    }

    func test_translation_enqueuesNonTargetLanguageForFramework() {
        let settings = IntelligenceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.targetLanguageCode = "en"

        let vm = IssueListViewModel()
        let spanishIssue = FeedbackIssue(
            number: 2,
            title: "La aplicación se cierra inesperadamente",
            createdAt: Date(),
            rawBody: "",
            appName: "App", appVersion: nil, device: nil, osVersion: nil, email: nil,
            description: "La aplicación se cierra cuando abro la página de configuración.",
            labels: []
        )
        vm.allIssues = [spanishIssue]
        let context = ModelContext(try! ModelContainer(for: CachedIssue.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        vm.attachIntelligence(provider: MockIntelligenceProvider(), settings: settings, cacheContext: context)

        // No on-device call anymore: a non-target issue is enqueued directly for the
        // Translation framework (driven by TranslationHost), carrying its detected source.
        vm.startTranslationsIfNeeded()
        XCTAssertEqual(vm.pendingTranslations.count, 1)
        let req = vm.pendingTranslations.first
        XCTAssertEqual(req?.issueNumber, 2)
        XCTAssertEqual(req?.target, "en")
        XCTAssertEqual(req?.detected, "es")
        XCTAssertEqual(req?.title, "La aplicación se cierra inesperadamente")

        // Simulating the framework returning a result commits via the shared path.
        vm.applyTranslation(req!, title: "The app closes unexpectedly",
                            body: "The app closes when I open the settings page.")
        XCTAssertEqual(vm.allIssues[0].translatedTitle, "The app closes unexpectedly")
        XCTAssertEqual(vm.allIssues[0].translationTargetLanguage, "en")
        XCTAssertTrue(vm.pendingTranslations.isEmpty)
    }

    func test_translation_enqueuesWithoutAppleIntelligence() {
        // The global Apple-Intelligence availability gate is gone: translation runs through
        // the Translation framework regardless of SystemLanguageModel availability.
        let mock = MockIntelligenceProvider()
        mock.availability = .appleIntelligenceNotEnabled
        let settings = IntelligenceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.targetLanguageCode = "en"

        let vm = IssueListViewModel()
        vm.allIssues = [FeedbackIssue(
            number: 3,
            title: "La aplicación se cierra inesperadamente",
            createdAt: Date(),
            rawBody: "",
            appName: "App", appVersion: nil, device: nil, osVersion: nil, email: nil,
            description: "La aplicación se cierra cuando abro la página de configuración.",
            labels: [])]
        let context = ModelContext(try! ModelContainer(for: CachedIssue.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        vm.attachIntelligence(provider: mock, settings: settings, cacheContext: context)

        vm.startTranslationsIfNeeded()
        XCTAssertEqual(vm.pendingTranslations.count, 1)
    }

    func test_applyLoaded_hydratesTranslationsFromCloudStore() {
        // Simulates the iOS-without-Apple-Intelligence case: another device computed
        // the translation and persisted it to the cloud-synced IssueTranslation table.
        // applyLoaded must surface that translation on this device.
        let settings = IntelligenceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.targetLanguageCode = "en"
        settings.translationEnabled = true

        let container = try! ModelContainer(
            for: CachedIssue.self, IssueTranslation.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        // Translation produced by another device, arriving via CloudKit.
        context.insert(IssueTranslation(
            repoOwner: "org",
            repoName: "repo",
            number: 7,
            targetLanguage: "en",
            detectedLanguageCode: "es",
            translatedTitle: "App crashes unexpectedly",
            translatedBody: "App crashes when I open settings repeatedly."
        ))
        try? context.save()

        let vm = IssueListViewModel()
        let store = SeenIssueStore(context: context)
        vm.attachSeenStore(store, owner: "org", repo: "repo")
        vm.attachIntelligence(provider: MockIntelligenceProvider(), settings: settings, cacheContext: context)

        let untranslated = FeedbackIssue(
            number: 7,
            title: "La aplicación se cierra inesperadamente",
            createdAt: Date(),
            rawBody: "",
            appName: "App", appVersion: nil, device: nil, osVersion: nil, email: nil,
            description: "La aplicación se cierra cuando abro la configuración.",
            labels: []
        )

        vm.applyLoaded([untranslated])

        XCTAssertEqual(vm.allIssues[0].translatedTitle, "App crashes unexpectedly")
        XCTAssertEqual(vm.allIssues[0].translatedBody, "App crashes when I open settings repeatedly.")
        XCTAssertEqual(vm.allIssues[0].translationTargetLanguage, "en")
        XCTAssertEqual(vm.allIssues[0].detectedLanguageCode, "es")
    }

    func test_hasTranslation_titleOnlyPartialWithNonEmptyBody_isNotTranslated() {
        // A title-only partial (translatedBody nil while the body is non-empty) must NOT
        // report hasTranslation — otherwise the card labels the issue "translated" while
        // still showing the original-language body (the #381 mislabel).
        let partial = FeedbackIssue(
            number: 1, title: "Lifetime Preis:", createdAt: Date(), rawBody: "",
            appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil,
            description: "Guten Tag, meine Demo ist abgelaufen.", labels: [],
            translatedTitle: "Lifetime Price:", translatedBody: nil
        )
        XCTAssertFalse(partial.hasTranslation)

        // Both non-empty fields translated → fully translated.
        let full = FeedbackIssue(
            number: 2, title: "Lifetime Preis:", createdAt: Date(), rawBody: "",
            appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil,
            description: "Guten Tag, meine Demo ist abgelaufen.", labels: [],
            translatedTitle: "Lifetime Price:", translatedBody: "Hello, my demo expired."
        )
        XCTAssertTrue(full.hasTranslation)

        // Title-only is legitimately complete when the body is empty (nothing to translate).
        let titleOnlyEmptyBody = FeedbackIssue(
            number: 3, title: "Lifetime Preis:", createdAt: Date(), rawBody: "",
            appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil,
            description: "", labels: [],
            translatedTitle: "Lifetime Price:", translatedBody: nil
        )
        XCTAssertTrue(titleOnlyEmptyBody.hasTranslation)
    }

    /// Builds a VM with a single non-target-language issue (German) enqueued for
    /// translation, and returns the enqueued request. The Translation framework itself
    /// can't run in tests, so tests drive the view-model side of the queue directly.
    @MainActor
    private func makePendingTranslationVM(germanBody: String)
        -> (vm: IssueListViewModel, context: ModelContext, request: IssueListViewModel.TranslationRequest)? {
        let settings = IntelligenceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.targetLanguageCode = "en"
        let context = ModelContext(try! ModelContainer(for: CachedIssue.self, IssueTranslation.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let vm = IssueListViewModel()
        vm.attachSeenStore(SeenIssueStore(context: context), owner: "org", repo: "repo")
        let issue = FeedbackIssue(
            number: 381, title: "Lifetime Preis:", createdAt: Date(), rawBody: germanBody,
            appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil,
            description: germanBody, labels: [])
        context.insert(CachedIssue.from(issue, repoOwner: "org", repoName: "repo"))
        try? context.save()
        vm.allIssues = [issue]
        vm.attachIntelligence(provider: MockIntelligenceProvider(), settings: settings, cacheContext: context)

        vm.startTranslationsIfNeeded()
        guard let r = vm.pendingTranslations.first(where: { $0.issueNumber == 381 }) else { return nil }
        return (vm, context, r)
    }

    func test_emptyTranslationResult_notStoredAsTranslation() {
        // An empty/whitespace result from the framework must not be committed as a
        // translation (it would render a blank body under a "translated" label).
        let germanBody = "Guten Tag, meine Demo ist gerade abgelaufen und ich wollte das Lifetime Produkt kaufen. Leider wird mir bei der Zahlung immer ein 50 Prozent höherer Preis angezeigt als in der App."
        guard let (vm, _, request) = makePendingTranslationVM(germanBody: germanBody) else {
            return XCTFail("issue never enqueued for translation")
        }
        vm.applyTranslation(request, title: "[t] Lifetime Price:", body: "   ")
        XCTAssertEqual(vm.allIssues[0].translatedTitle, "[t] Lifetime Price:")
        XCTAssertNil(vm.allIssues[0].translatedBody)
    }

    func test_transientErrorWithPartialResult_doesNotCommitPartial_andStaysRetryable() {
        // Repro of the #381 partial-commit hazard on the framework path: a transient
        // failure (e.g. cancellation when the view disappears) lands AFTER the title
        // translated but BEFORE the body. The outcome must NOT commit the title-only
        // partial — that would stamp translationTargetLanguage and freeze the issue with
        // the body stranded in its original language under a "translated" label, never
        // retried. It must drop instead, leaving the cache un-stamped for a fresh retry.
        let germanBody = "Guten Tag, meine Demo ist gerade abgelaufen und ich wollte das Lifetime Produkt kaufen. Leider wird mir bei der Zahlung immer ein 50 Prozent höherer Preis angezeigt als in der App."
        guard let (vm, context, request) = makePendingTranslationVM(germanBody: germanBody) else {
            return XCTFail("issue never enqueued for translation")
        }

        vm.applyTranslationOutcome(request, title: "[t] Lifetime Preis:", body: nil, transientError: true)

        // No partial committed in memory.
        XCTAssertNil(vm.allIssues[0].translatedTitle)
        XCTAssertNil(vm.allIssues[0].translatedBody)
        XCTAssertTrue(vm.pendingTranslations.isEmpty)
        // Cache stays un-stamped so the whole issue retries on the next launch.
        let fetched = try? context.fetch(
            FetchDescriptor<CachedIssue>(predicate: #Predicate { $0.number == 381 })).first
        XCTAssertNil(fetched?.translationTargetLanguage)
    }

    func testApplyLoadedExcludesTaskIssuesFromFeedback() {
        let vm = IssueListViewModel()
        let feedback = FeedbackIssue(number: 1, title: "fb", createdAt: Date(), rawBody: "",
            appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil,
            description: "", labels: [])
        let task = FeedbackIssue(number: 2, title: "task", createdAt: Date(), rawBody: "",
            appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil,
            description: "", labels: [IssueLabel(name: AppFeedbackLabels.task, colorHex: "5319e7")])
        vm.applyLoaded([feedback, task])
        XCTAssertEqual(vm.allIssues.map(\.number), [1])
        XCTAssertEqual(vm.tasks.map(\.number), [2])
    }

    func test_translationUnavailable_blacklistsLanguage() {
        // When the Translation framework reports a pair genuinely unsupported, the source
        // language is blacklisted for the session so we stop retrying every issue in it.
        let germanBody = "Guten Tag, meine Demo ist gerade abgelaufen und ich wollte das Lifetime Produkt kaufen."
        guard let (vm, _, request) = makePendingTranslationVM(germanBody: germanBody) else {
            return XCTFail("issue never enqueued for translation")
        }
        XCTAssertEqual(request.detected, "de")

        vm.handleTranslationUnavailable(request)
        XCTAssertTrue(vm.unsupportedSourceLanguages.contains("de"))
        XCTAssertTrue(vm.pendingTranslations.isEmpty)
    }

    func test_invalidateTranslations_clearsQueueAndBlacklist() {
        // A target-language change invalidates: pending work, download gating, and the
        // session blacklist all reset so the new target gets a fresh evaluation.
        let germanBody = "Guten Tag, meine Demo ist gerade abgelaufen und ich wollte das Lifetime Produkt kaufen."
        guard let (vm, _, request) = makePendingTranslationVM(germanBody: germanBody) else {
            return XCTFail("issue never enqueued for translation")
        }
        vm.handleTranslationUnavailable(request)
        XCTAssertFalse(vm.unsupportedSourceLanguages.isEmpty)

        vm.invalidateTranslations()
        XCTAssertTrue(vm.pendingTranslations.isEmpty)
        XCTAssertTrue(vm.unsupportedSourceLanguages.isEmpty)
        XCTAssertNil(vm.allIssues[0].translationTargetLanguage)
    }

    // MARK: - Language download gating

    private func makeRequest(
        detected: String,
        target: String = "en"
    ) -> IssueListViewModel.TranslationRequest {
        IssueListViewModel.TranslationRequest(
            requestID: UUID(), issueNumber: 1, title: "t", body: "b",
            detected: detected, target: target)
    }

    func test_pumpDecision_installed_proceeds() {
        let vm = IssueListViewModel()
        XCTAssertEqual(vm.pumpDecision(for: makeRequest(detected: "ar"), state: .installed), .proceed)
    }

    func test_pumpDecision_unsupported_isUnavailable() {
        let vm = IssueListViewModel()
        XCTAssertEqual(vm.pumpDecision(for: makeRequest(detected: "ar"), state: .unsupported), .unavailable)
    }

    func test_pumpDecision_supportedUnapproved_needsDownload() {
        let vm = IssueListViewModel()
        XCTAssertEqual(vm.pumpDecision(for: makeRequest(detected: "ar"), state: .supported), .needsDownload)
    }

    func test_pumpDecision_supportedApproved_proceeds() {
        let vm = IssueListViewModel()
        vm.approveLanguageDownload(detected: "ar", target: "en")
        XCTAssertEqual(vm.pumpDecision(for: makeRequest(detected: "ar"), state: .supported), .proceed)
    }

    func test_pumpDecision_approvalIsPairSpecific() {
        let vm = IssueListViewModel()
        vm.approveLanguageDownload(detected: "ar", target: "en")
        // A different source language for the same target is still gated.
        XCTAssertEqual(vm.pumpDecision(for: makeRequest(detected: "fr"), state: .supported), .needsDownload)
        // The same source language but a different target is still gated.
        XCTAssertEqual(vm.pumpDecision(for: makeRequest(detected: "ar", target: "de"), state: .supported), .needsDownload)
    }

    func test_languageDownloadGate_lifecycle() {
        // A real pending German→English request to exercise the download gate.
        let germanBody = "Guten Tag, meine Demo ist gerade abgelaufen und ich wollte das Lifetime Produkt kaufen. Leider wird mir bei der Zahlung immer ein 50 Prozent höherer Preis angezeigt als in der App."
        guard let (vm, _, request) = makePendingTranslationVM(germanBody: germanBody) else {
            return XCTFail("issue never enqueued for translation")
        }
        let issue = vm.allIssues[0]

        // Not gated yet: no prompt, request is pumpable.
        XCTAssertNil(vm.needsLanguageDownload(issue))
        XCTAssertEqual(vm.nextPumpableRequest()?.issueNumber, 381)

        // Host gates the pair (simulating a `.supported` status): prompt appears,
        // and the gated pair is skipped so it can't block a ready pair behind it.
        vm.markNeedsDownload(detected: request.detected, target: request.target)
        XCTAssertNotNil(vm.needsLanguageDownload(issue))
        XCTAssertNil(vm.nextPumpableRequest())

        // User taps download: prompt clears, request becomes pumpable, a `.supported`
        // pair now proceeds, and the host is nudged via the tick.
        let tickBefore = vm.downloadApprovalTick
        vm.approveLanguageDownload(for: issue)
        XCTAssertNil(vm.needsLanguageDownload(issue))
        XCTAssertEqual(vm.nextPumpableRequest()?.issueNumber, 381)
        XCTAssertEqual(vm.pumpDecision(for: request, state: .supported), .proceed)
        XCTAssertGreaterThan(vm.downloadApprovalTick, tickBefore)

        // User dismisses the sheet without downloading: re-gate, prompt returns.
        vm.regateDownload(detected: request.detected, target: request.target)
        XCTAssertNotNil(vm.needsLanguageDownload(issue))
        XCTAssertEqual(vm.pumpDecision(for: request, state: .supported), .needsDownload)
    }
}

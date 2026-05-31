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

    func test_translation_skipsTargetLanguageIssues() async {
        let mock = MockIntelligenceProvider()
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
        vm.attachIntelligence(provider: mock, settings: settings, cacheContext: context)

        vm.startTranslationsIfNeeded()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(mock.translateCalls.count, 0)
    }

    func test_translation_translatesNonTargetLanguage() async {
        let mock = MockIntelligenceProvider()
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
        vm.attachIntelligence(provider: mock, settings: settings, cacheContext: context)

        vm.startTranslationsIfNeeded()

        for _ in 0..<50 {
            if mock.translateCalls.count >= 2 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(mock.translateCalls.count, 2)
        XCTAssertEqual(vm.allIssues[0].translationTargetLanguage, "en")
        XCTAssertEqual(vm.allIssues[0].translatedTitle, "[t] La aplicación se cierra inesperadamente")
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

    func test_translation_guardrailBlockOnBody_routesToFallbackNotPartialCommit() async {
        // Repro of #381: Apple's on-device safety guardrail false-positives on the
        // German body, so the body attempt throws .guardrailBlocked while the short
        // title translates fine. A guardrail block must route the WHOLE issue to the
        // Translation-framework fallback — NOT commit a title-only result that freezes
        // the issue (translationTargetLanguage stamped, so no retry) with the body
        // left in the original language under a "translated" label.
        let germanBody = "Guten Tag, meine Demo ist gerade abgelaufen und ich wollte das Lifetime Produkt kaufen. Leider wird mir bei der Zahlung immer ein 50 Prozent höherer Preis angezeigt als in der App. Können Sie hierbei bitte helfen?"
        let mock = MockIntelligenceProvider()
        mock.translateHandler = { text, _, _ in
            if text == germanBody { throw IntelligenceError.guardrailBlocked }
            return "[t] " + text
        }
        let settings = IntelligenceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.targetLanguageCode = "en"

        let vm = IssueListViewModel()
        vm.allIssues = [FeedbackIssue(
            number: 381,
            title: "Lifetime Preis:",
            createdAt: Date(),
            rawBody: germanBody,
            appName: "App", appVersion: nil, device: nil, osVersion: nil, email: nil,
            description: germanBody,
            labels: []
        )]
        let context = ModelContext(try! ModelContainer(for: CachedIssue.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        vm.attachIntelligence(provider: mock, settings: settings, cacheContext: context)

        vm.startTranslationsIfNeeded()

        var finished = false
        for _ in 0..<200 {
            if !vm.translatingNumbers.contains(381) { finished = true; break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(finished, "translation task did not finish within the timeout")
        // The title actually translated on-device — proves the title-vs-body asymmetry the
        // test guards (a body-only block), not a both-fields-failed false pass.
        XCTAssertTrue(mock.translateCalls.contains { $0.text == "Lifetime Preis:" })

        // Routed to the fallback for the whole issue, tagged as a guardrail block…
        XCTAssertEqual(vm.pendingFallbacks.count, 1)
        XCTAssertEqual(vm.pendingFallbacks.first?.issueNumber, 381)
        XCTAssertEqual(vm.pendingFallbacks.first?.reason, .guardrail)
        // …and NOT frozen as a title-only partial commit.
        XCTAssertNil(vm.allIssues[0].translatedTitle)
        XCTAssertNil(vm.allIssues[0].translationTargetLanguage)
    }

    /// Sets up a VM whose body translation trips the guardrail (title translates fine),
    /// drives it, and returns once the issue is enqueued to the fallback.
    @MainActor
    private func makeGuardrailFallbackVM(germanBody: String) async
        -> (vm: IssueListViewModel, context: ModelContext, request: IssueListViewModel.FallbackRequest)? {
        let mock = MockIntelligenceProvider()
        mock.translateHandler = { text, _, _ in
            if text == germanBody { throw IntelligenceError.guardrailBlocked }
            return "[t] " + text
        }
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
        vm.attachIntelligence(provider: mock, settings: settings, cacheContext: context)

        vm.startTranslationsIfNeeded()
        for _ in 0..<200 {
            if let r = vm.pendingFallbacks.first(where: { $0.issueNumber == 381 }) {
                return (vm, context, r)
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    func test_guardrailFallbackUnavailable_doesNotBlacklistLanguage_andLeavesCacheRetryable() async {
        // When a guardrail-routed issue's pair is ALSO unavailable in the Translation
        // framework, we must NOT blacklist the whole language (other German issues
        // translate fine on-device), and the cache must stay un-stamped so it retries
        // next launch rather than being permanently frozen.
        let germanBody = "Guten Tag, meine Demo ist gerade abgelaufen und ich wollte das Lifetime Produkt kaufen. Leider wird mir bei der Zahlung immer ein 50 Prozent höherer Preis angezeigt als in der App."
        guard let (vm, context, request) = await makeGuardrailFallbackVM(germanBody: germanBody) else {
            return XCTFail("guardrail body never routed to fallback")
        }
        XCTAssertEqual(request.reason, .guardrail)

        vm.handleFallbackUnavailable(request)

        XCTAssertFalse(vm.unsupportedSourceLanguages.contains("de"))
        XCTAssertTrue(vm.pendingFallbacks.isEmpty)
        let fetched = try? context.fetch(
            FetchDescriptor<CachedIssue>(predicate: #Predicate { $0.number == 381 })).first
        XCTAssertNil(fetched?.translationTargetLanguage)
    }

    func test_guardrailFallbackEmptyResult_notStoredAsTranslation() async {
        // An empty/whitespace result from the framework must not be committed as a
        // translation (it would render a blank body under a "translated" label).
        let germanBody = "Guten Tag, meine Demo ist gerade abgelaufen und ich wollte das Lifetime Produkt kaufen. Leider wird mir bei der Zahlung immer ein 50 Prozent höherer Preis angezeigt als in der App."
        guard let (vm, _, request) = await makeGuardrailFallbackVM(germanBody: germanBody) else {
            return XCTFail("guardrail body never routed to fallback")
        }
        vm.applyFallbackTranslation(request, title: "[t] Lifetime Price:", body: "   ")
        XCTAssertEqual(vm.allIssues[0].translatedTitle, "[t] Lifetime Price:")
        XCTAssertNil(vm.allIssues[0].translatedBody)
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

    func test_unsupportedLanguageFallbackUnavailable_blacklistsLanguage() async {
        // Contrast with the guardrail case: a genuine on-device-unsupported language that
        // the framework also can't translate SHOULD blacklist the language for the session.
        let germanBody = "Guten Tag, meine Demo ist gerade abgelaufen und ich wollte das Lifetime Produkt kaufen."
        let mock = MockIntelligenceProvider()
        mock.translateHandler = { _, _, _ in throw IntelligenceError.unsupportedLanguage }
        let settings = IntelligenceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.targetLanguageCode = "en"
        let context = ModelContext(try! ModelContainer(for: CachedIssue.self, IssueTranslation.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let vm = IssueListViewModel()
        vm.attachSeenStore(SeenIssueStore(context: context), owner: "org", repo: "repo")
        vm.allIssues = [FeedbackIssue(
            number: 381, title: "Lifetime Preis:", createdAt: Date(), rawBody: germanBody,
            appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil,
            description: germanBody, labels: [])]
        vm.attachIntelligence(provider: mock, settings: settings, cacheContext: context)

        vm.startTranslationsIfNeeded()
        var request: IssueListViewModel.FallbackRequest?
        for _ in 0..<200 {
            if let r = vm.pendingFallbacks.first(where: { $0.issueNumber == 381 }) { request = r; break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let request else { return XCTFail("unsupported body never routed to fallback") }
        XCTAssertEqual(request.reason, .unsupportedOnDevice)

        vm.handleFallbackUnavailable(request)
        XCTAssertTrue(vm.unsupportedSourceLanguages.contains("de"))
    }
}

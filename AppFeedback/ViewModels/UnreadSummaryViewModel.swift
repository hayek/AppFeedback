import Foundation
import Observation
import SwiftData

enum SummaryState: Equatable {
    case idle
    case loading
    case ready(IssueSummaryDTO)
    case skipped
    case unavailable
    case failed(String)
}

struct SummaryCacheScope: Equatable, Sendable {
    let repoOwner: String
    let repoName: String
    let targetLanguage: String
}

/// Cache identity plus the SwiftData context to read/write through. Bundled
/// so the "scope without context (or vice versa)" combination is unrepresentable.
/// Only meaningful in rolling-30-day mode and for the unfiltered repo view.
struct SummaryCacheBinding {
    let scope: SummaryCacheScope
    let context: ModelContext
}

@Observable @MainActor
final class UnreadSummaryViewModel {
    private(set) var state: SummaryState = .idle

    private let provider: IntelligenceProvider
    private let debounceMs: UInt64
    private var currentTask: Task<Void, Never>?

    init(provider: IntelligenceProvider, debounceMs: UInt64 = 500) {
        self.provider = provider
        self.debounceMs = debounceMs
    }

    func update(
        issues: [FeedbackIssue],
        targetLanguage: String,
        promptContext: AISummaryPromptContext,
        cache: SummaryCacheBinding? = nil
    ) async {
        currentTask?.cancel()

        let fingerprint = Self.issueNumbersFingerprint(issues)
        let activeCache = promptContext == .rollingLastThirtyDays ? cache : nil

        var cachedDTO: IssueSummaryDTO? = nil
        var cachedFingerprint: String? = nil
        if let activeCache, let row = fetchSummaryRow(binding: activeCache) {
            cachedDTO = IssueSummaryDTO(headline: row.headline, pros: row.pros, cons: row.cons)
            cachedFingerprint = row.inputFingerprint
        }

        if !provider.availability.isReady {
            state = cachedDTO.map { .ready($0) } ?? .unavailable
            return
        }
        if issues.count < 2 {
            state = cachedDTO.map { .ready($0) } ?? .skipped
            return
        }

        if let cachedDTO {
            state = .ready(cachedDTO)
            if cachedFingerprint == fingerprint { return }
        } else {
            state = .loading
        }

        let provider = self.provider
        let debounceMs = self.debounceMs
        let hadCached = cachedDTO != nil
        currentTask = Task { [weak self] in
            if debounceMs > 0 {
                try? await Task.sleep(nanoseconds: debounceMs * 1_000_000)
            }
            if Task.isCancelled { return }
            do {
                let result = try await provider.summarize(
                    issues: issues,
                    targetLanguage: targetLanguage,
                    promptContext: promptContext
                )
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self else { return }
                    self.state = .ready(result)
                    if let activeCache {
                        self.persistSummary(binding: activeCache, dto: result, fingerprint: fingerprint)
                    }
                }
            } catch is CancellationError {
            } catch {
                if Task.isCancelled { return }
                let message = error.localizedDescription
                await MainActor.run {
                    guard let self else { return }
                    if !hadCached { self.state = .failed(message) }
                }
            }
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        state = .idle
    }

    /// Bumped whenever the summary's *meaning* changes (e.g. `pros` reframed to
    /// genuine-praise-only) so already-cached rows recompute once on upgrade instead
    /// of rendering stale content under new labels.
    static let summaryFormatVersion = 2

    /// Sorted, comma-joined issue numbers, prefixed with the format version — a stable
    /// identity for a set of issues *under the current summary semantics*.
    /// Shared so cache-fingerprint and SwiftUI task-id derive from the same source.
    static func issueNumbersFingerprint(_ issues: [FeedbackIssue]) -> String {
        let numbers = issues.map(\.number).sorted().map(String.init).joined(separator: ",")
        return "v\(summaryFormatVersion):\(numbers)"
    }

    private func fetchSummaryRow(binding: SummaryCacheBinding) -> IssueSummaryCache? {
        let owner = binding.scope.repoOwner
        let repo = binding.scope.repoName
        let lang = binding.scope.targetLanguage
        var descriptor = FetchDescriptor<IssueSummaryCache>(
            predicate: #Predicate { row in
                row.repoOwner == owner && row.repoName == repo && row.targetLanguage == lang
            },
            // Newest-first + limit 1: CloudKit can briefly materialize duplicate rows
            // during sync convergence; pick the freshest without paying for the rest.
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? binding.context.fetch(descriptor))?.first
    }

    private func persistSummary(
        binding: SummaryCacheBinding,
        dto: IssueSummaryDTO,
        fingerprint: String
    ) {
        if let row = fetchSummaryRow(binding: binding) {
            row.headline = dto.headline
            row.pros = dto.pros
            row.cons = dto.cons
            row.inputFingerprint = fingerprint
            row.updatedAt = Date()
        } else {
            binding.context.insert(IssueSummaryCache(
                repoOwner: binding.scope.repoOwner,
                repoName: binding.scope.repoName,
                targetLanguage: binding.scope.targetLanguage,
                headline: dto.headline,
                pros: dto.pros,
                cons: dto.cons,
                inputFingerprint: fingerprint
            ))
        }
        try? binding.context.save()
    }
}

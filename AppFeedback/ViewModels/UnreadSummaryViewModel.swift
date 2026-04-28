import Foundation
import Observation

enum SummaryState: Equatable {
    case idle
    case loading
    case ready(IssueSummaryDTO)
    case skipped
    case unavailable
    case failed(String)
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

    func update(unread: [FeedbackIssue], targetLanguage: String) async {
        currentTask?.cancel()

        if !provider.availability.isReady {
            state = .unavailable
            return
        }
        if unread.count < 2 {
            state = .skipped
            return
        }
        state = .loading
        let provider = self.provider
        let debounceMs = self.debounceMs
        currentTask = Task { [weak self] in
            if debounceMs > 0 {
                try? await Task.sleep(nanoseconds: debounceMs * 1_000_000)
            }
            if Task.isCancelled { return }
            do {
                let result = try await provider.summarize(issues: unread, targetLanguage: targetLanguage)
                if Task.isCancelled { return }
                await MainActor.run { self?.state = .ready(result) }
            } catch is CancellationError {
            } catch {
                if Task.isCancelled { return }
                let message = error.localizedDescription
                await MainActor.run { self?.state = .failed(message) }
            }
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        state = .idle
    }
}

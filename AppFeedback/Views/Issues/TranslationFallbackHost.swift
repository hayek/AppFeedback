import SwiftUI
import Translation

/// Invisible host that drives Apple's Translation framework as a fallback for
/// issues the on-device Foundation Models translator refused with
/// `unsupportedLanguageOrLocale`. Reads `viewModel.pendingFallbacks`,
/// processes one source-language pair at a time, and reports results back.
struct TranslationFallbackHost: View {
    @Bindable var viewModel: IssueListViewModel

    @State private var activeConfig: TranslationSession.Configuration?
    @State private var activeLanguage: String?
    @State private var activeTarget: String?
    /// Set synchronously inside `pumpIfIdle` before the LanguageAvailability roundtrip
    /// dispatches, so a second `pumpIfIdle` call in the same runloop tick (initial `.task`
    /// + `.onChange`) doesn't launch a duplicate availability check. Cleared on the
    /// MainActor hop that decides what to do next.
    @State private var isPumping = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(activeConfig) { session in
                guard let detected = activeLanguage, let target = activeTarget else { return }
                await drain(session: session, detected: detected, target: target)
            }
            .task { pumpIfIdle() }
            .onChange(of: viewModel.pendingFallbacks) { _, _ in pumpIfIdle() }
    }

    private func pumpIfIdle() {
        guard activeConfig == nil, !isPumping else { return }
        guard let next = viewModel.pendingFallbacks.first else { return }
        let detected = next.detected
        let target = next.target
        isPumping = true
        Task {
            let status = await LanguageAvailability().status(
                from: Locale.Language(identifier: detected),
                to: Locale.Language(identifier: target)
            )
            await MainActor.run {
                isPumping = false
                if status == .unsupported {
                    // Let the view model decide based on WHY this issue was routed here:
                    // a genuine unsupported language blacklists the language; a guardrail
                    // false-positive drops just this issue (the language is otherwise fine).
                    viewModel.handleFallbackUnavailable(next)
                    pumpIfIdle()
                    return
                }
                activeLanguage = detected
                activeTarget = target
                activeConfig = TranslationSession.Configuration(
                    source: Locale.Language(identifier: detected),
                    target: Locale.Language(identifier: target)
                )
            }
        }
    }

    private func drain(session: TranslationSession, detected: String, target: String) async {
        while true {
            // Match BOTH detected and target — if the user switched the global target
            // mid-drain, new requests carry the new target and must be processed by a
            // session bound to that target, not this one.
            let request: IssueListViewModel.FallbackRequest? = await MainActor.run {
                viewModel.pendingFallbacks.first(where: { $0.detected == detected && $0.target == target })
            }
            guard let request else { break }

            // A request with no content to translate would otherwise hit the
            // "neither translatedTitle nor translatedBody, no thrown error" branch and
            // poison the whole source language for the session.
            if request.title.isEmpty && request.body.isEmpty {
                await MainActor.run { viewModel.dropPendingFallback(request) }
                continue
            }

            var translatedTitle: String?
            var translatedBody: String?
            var transientError = false
            do {
                if !request.title.isEmpty {
                    translatedTitle = try await session.translate(request.title).targetText
                }
                if !request.body.isEmpty {
                    translatedBody = try await session.translate(request.body).targetText
                }
            } catch {
                // Could be transient (network, cancellation) — don't blacklist
                // the whole source language on the strength of one failure.
                transientError = true
                print("[FallbackTranslate] error for #\(request.issueNumber): \(error)")
            }

            await MainActor.run {
                if translatedTitle != nil || translatedBody != nil {
                    viewModel.applyFallbackTranslation(request, title: translatedTitle, body: translatedBody)
                } else if transientError {
                    viewModel.dropPendingFallback(request)
                } else {
                    viewModel.markFallbackUnsupported(detectedLanguage: request.detected)
                }
            }
        }

        await MainActor.run {
            activeConfig = nil
            activeLanguage = nil
            activeTarget = nil
            pumpIfIdle()
        }
    }
}

import SwiftUI
import Translation

/// Invisible host that drives Apple's Translation framework — the app's sole translation
/// engine. Reads `viewModel.pendingTranslations`, processes one language pair at a time,
/// and reports results back. Pairs whose languages aren't downloaded are gated in the view
/// model and surfaced as a per-issue tap target rather than auto-presenting the system
/// download sheet; the session for such a pair starts only after the user approves.
struct TranslationHost: View {
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
            .onChange(of: viewModel.pendingTranslations) { _, _ in pumpIfIdle() }
            .onChange(of: viewModel.downloadApprovalTick) { _, _ in pumpIfIdle() }
    }

    /// Maps Apple's availability status into the view-model's framework-agnostic enum.
    private func currentState(detected: String, target: String) async -> IssueListViewModel.LanguageDownloadState {
        let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: detected),
            to: Locale.Language(identifier: target)
        )
        switch status {
        case .installed: return .installed
        case .supported: return .supported
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    private func pumpIfIdle() {
        guard activeConfig == nil, !isPumping else { return }
        // Take the first pending request whose pair isn't gated awaiting a download —
        // otherwise a gated pair at the head would block a ready pair behind it.
        guard let next = viewModel.nextPumpableRequest() else { return }
        let detected = next.detected
        let target = next.target
        isPumping = true
        Task {
            let state = await currentState(detected: detected, target: target)
            await MainActor.run {
                isPumping = false
                switch viewModel.pumpDecision(for: next, state: state) {
                case .unavailable:
                    // The pair is genuinely unsupported — blacklist the source language.
                    viewModel.handleTranslationUnavailable(next)
                    pumpIfIdle()
                case .needsDownload:
                    // Gate it and surface the inline affordance; try other pairs that
                    // may already be installed.
                    viewModel.markNeedsDownload(detected: detected, target: target)
                    pumpIfIdle()
                case .proceed:
                    activeLanguage = detected
                    activeTarget = target
                    activeConfig = TranslationSession.Configuration(
                        source: Locale.Language(identifier: detected),
                        target: Locale.Language(identifier: target)
                    )
                }
            }
        }
    }

    private func drain(session: TranslationSession, detected: String, target: String) async {
        while true {
            // Match BOTH detected and target — if the user switched the global target
            // mid-drain, new requests carry the new target and must be processed by a
            // session bound to that target, not this one.
            let request: IssueListViewModel.TranslationRequest? = await MainActor.run {
                viewModel.pendingTranslations.first(where: { $0.detected == detected && $0.target == target })
            }
            guard let request else { break }

            // A request with no content to translate would otherwise hit the
            // "neither translatedTitle nor translatedBody, no thrown error" branch and
            // poison the whole source language for the session.
            if request.title.isEmpty && request.body.isEmpty {
                await MainActor.run { viewModel.dropPendingRequest(request) }
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
                // The user may have dismissed the system download sheet without
                // downloading. If the pair still only reports `.supported` (not
                // installed), treat it as a declined download: re-gate so the inline
                // prompt returns and leave every queued request for this pair pending.
                if await currentState(detected: detected, target: target) == .supported {
                    await MainActor.run {
                        viewModel.regateDownload(detected: detected, target: target)
                    }
                    break
                }
                // Otherwise a genuine transient error (network, cancellation) — don't
                // blacklist the whole source language on the strength of one failure.
                transientError = true
                print("[Translate] error for #\(request.issueNumber): \(error)")
            }

            await MainActor.run {
                viewModel.applyTranslationOutcome(
                    request,
                    title: translatedTitle,
                    body: translatedBody,
                    transientError: transientError
                )
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

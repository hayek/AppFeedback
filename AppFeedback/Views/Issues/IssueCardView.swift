import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum DateDisplayStyle: Int, CaseIterable {
    case relative = 0
    case date = 1
    case dateTime = 2

    var next: DateDisplayStyle {
        DateDisplayStyle(rawValue: (rawValue + 1) % DateDisplayStyle.allCases.count) ?? .date
    }

    func format(_ date: Date) -> String {
        switch self {
        case .relative:
            return date.formatted(.relative(presentation: .named))
        case .date:
            return date.formatted(date: .abbreviated, time: .omitted)
        case .dateTime:
            let d = date.formatted(date: .abbreviated, time: .omitted)
            let t = date.formatted(date: .omitted, time: .shortened)
            return "\(d), \(t)"
        }
    }
}

struct ToggleableDateText: View {
    let date: Date
    var onInteract: (() -> Void)? = nil
    @AppStorage("app.dateDisplayStyle") private var rawStyle: Int = 0

    private var style: DateDisplayStyle {
        DateDisplayStyle(rawValue: rawStyle) ?? .date
    }

    var body: some View {
        Text(style.format(date))
            .contentTransition(.numericText())
            .animation(.snappy(duration: 0.25), value: rawStyle)
            .onTapGesture {
                onInteract?()
                rawStyle = style.next.rawValue
            }
    }
}

struct IssueCardView: View {
    let issue: FeedbackIssue
    let repoOwner: String
    let repoName: String
    let appColor: Color
    var isUnread: Bool = false
    var onInteract: (() -> Void)? = nil
    var activeAppVersion: Set<String> = []
    var activeDevice: Set<String> = []
    var activeOSVersion: Set<String> = []
    var onToggleAppVersion: ((String) -> Void)? = nil
    var onToggleDevice: ((String) -> Void)? = nil
    var onToggleOSVersion: ((String) -> Void)? = nil
    var activeIssueType: Set<IssueType> = []
    var onToggleIssueType: ((IssueType) -> Void)? = nil
    var targetLanguageCode: String = "en"
    var isTranslating: Bool = false
    var isHighlighted: Bool = false
    var translationUnsupported: Bool = false
    var onRetranslate: (() -> Void)? = nil
    /// Non-nil source-language display name when this issue is waiting on a
    /// user-approved language download before it can be translated.
    var needsDownloadLanguage: String? = nil
    /// Invoked when the user taps the inline download link; approves the language pair.
    var onRequestDownload: (() -> Void)? = nil
    /// Tasks that address this feedback, shown as clickable tags that open the task detail.
    var attachedTasks: [TaskItem] = []
    /// Release state per version name, used to color a task tag's version badge by release status.
    var versionStates: [String: VersionState] = [:]
    var onOpenTask: ((TaskItem) -> Void)? = nil
    var onRemoveTask: ((TaskItem) -> Void)? = nil
    /// The App Store response controller for this card, built and cached once per issue by
    /// `IssueListView` (nil for SDK/email items or when App Store source isn't configured).
    /// Passing it in — rather than constructing it in `body` — keeps the draft alive across
    /// re-renders (e.g. when `mirrorStore.version` bumps on a CloudKit import).
    var responseController: AppStoreResponseController? = nil
    /// Pending AI triage suggestion for this feedback (nil when triage is off, not yet run,
    /// or already resolved). Renders `TriageSuggestionChip` at the bottom of the card.
    var triageSuggestion: TriageVerdictRecord? = nil
    /// True while this suggestion's accept is in flight; disables the chip's Add
    /// button so a double-tap can't fire two GitHub creates/assigns.
    var isAcceptingSuggestion: Bool = false
    var onAcceptSuggestion: (() -> Void)? = nil
    var onDismissSuggestion: (() -> Void)? = nil
    /// Title of the suggestion's assign-target task (shown inline in the chip).
    var suggestedTaskTitle: String? = nil
    /// Opens the suggestion's assign-target task; nil hides the chip's open button.
    var onOpenSuggestedTask: (() -> Void)? = nil

    @Environment(MailThreadStore.self) private var threadStore
    @Environment(ReplyTemplateStore.self) private var replyTemplateStore
    #if canImport(SwiftMail)
    @Environment(MailDraftStore.self) private var drafts
    #endif

    @State private var showOriginal: Bool = false
    @State private var highlightActive: Bool = false
    @State private var didCopy: Bool = false
    @State private var threads: [MailThread] = []
    @State private var showTemplatePicker: Bool = false
    /// Whether the App Store response composer is expanded. Collapsed by default so the card
    /// stays the same size as any other feedback card until you choose to reply.
    @State private var showsAppStoreResponder: Bool = false

    private var translationVisible: Bool { issue.hasTranslation && !showOriginal }

    /// Fractional width of the scroll fade on each edge of the tag row. Because the
    /// gradient stops are fractional, the same value reads as a wider fade on the
    /// roomier macOS card — so we tighten it there to keep the fade hugging the edge
    /// the way it does on iOS.
    private var tagFadeInset: CGFloat {
        #if os(macOS)
        0.015
        #else
        0.04
        #endif
    }

    /// True when the issue itself is unread, or any attached mail thread has an inbound
    /// reply the user hasn't viewed yet. Re-evaluates on `threadStore.version` changes.
    private var effectiveUnread: Bool {
        if isUnread { return true }
        return threads.contains { threadStore.hasUnreadInbound(thread: $0) }
    }

    private var sourceLanguageDisplayName: String? {
        guard let code = issue.detectedLanguageCode, !code.isEmpty else { return nil }
        return Locale.current.localizedString(forLanguageCode: code)
    }

    private var copyText: String {
        FeedbackClipboard.text(for: issue, threads: threads, translated: translationVisible)
    }

    private func copyToClipboard() {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(copyText, forType: .string)
        #else
        UIPasteboard.general.string = copyText
        #endif
    }

    private func copyEmailToClipboard(_ email: String) {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(email, forType: .string)
        #else
        UIPasteboard.general.string = email
        #endif
    }

    private func replyToEmail(_ email: String) {
        #if canImport(SwiftMail)
        withAnimation(.easeOut(duration: 0.2)) {
            drafts.setOpenRequest(
                ComposeRequest(
                    recipient: email,
                    issue: issue,
                    repoOwner: repoOwner,
                    repoName: repoName,
                    inReplyTo: nil,
                    subjectOverride: nil,
                    senderAccountID: nil
                ),
                for: newEmailKey(for: email)
            )
        }
        #else
        guard let encoded = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let mailURL = URL(string: "mailto:\(encoded)") else { return }
        #if os(macOS)
        NSWorkspace.shared.open(mailURL)
        #else
        UIApplication.shared.open(mailURL)
        #endif
        #endif
    }

    #if canImport(SwiftMail)
    private func newEmailKey(for email: String) -> DraftKey {
        .newEmail(repoOwner: repoOwner, repoName: repoName, issueNumber: issue.number, recipient: email)
    }

    private var activeInlineComposers: [(key: DraftKey, request: ComposeRequest)] {
        guard let email = issue.email else { return [] }
        let key = newEmailKey(for: email)
        if let req = drafts.openRequest(for: key) {
            return [(key, req)]
        }
        return []
    }

    /// Open the inline composer for `email`, seeded with the template body. When `autoSend`
    /// is true the composer sends immediately (if credentialed); otherwise it stays open
    /// for editing. Mirrors `replyToEmail(_:)` but carries the template body.
    private func useTemplate(_ template: ReplyTemplate, autoSend: Bool, email: String) {
        withAnimation(.easeOut(duration: 0.2)) {
            drafts.setOpenRequest(
                ComposeRequest(
                    recipient: email,
                    issue: issue,
                    repoOwner: repoOwner,
                    repoName: repoName,
                    inReplyTo: nil,
                    subjectOverride: nil,
                    senderAccountID: nil,
                    initialBody: template.body,
                    autoSend: autoSend
                ),
                for: newEmailKey(for: email)
            )
        }
    }
    #endif

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(appColor)
                .frame(width: 3)
                .clipShape(UnevenRoundedRectangle(
                    topLeadingRadius: 10, bottomLeadingRadius: 10,
                    bottomTrailingRadius: 0, topTrailingRadius: 0
                ))

            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    let titleText = issue.displayedTitle(translated: translationVisible)
                    let bodyText = issue.displayedBody(translated: translationVisible)
                    HStack(alignment: .top, spacing: 12) {
                        SourceBadgeView(source: issue.source, rating: issue.rating)
                            .fixedSize()
                        if !titleText.isEmpty {
                            IssueTitleText(text: titleText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Spacer(minLength: 0)
                        }
                        metaColumn
                    }
                    if !bodyText.isEmpty {
                        IssueBodyText(body: bodyText)
                    }

                    if !issue.attachments.isEmpty {
                        AttachmentStripView(attachments: issue.attachments)
                    }

                    if isTranslating {
                        ShimmeringText("Translating…")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.top, 4)
                    } else if let downloadLanguage = needsDownloadLanguage {
                        Button { onRequestDownload?() } label: {
                            Label("Translate · download \(downloadLanguage)",
                                  systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.top, 4)
                    } else if issue.hasTranslation {
                        HStack(spacing: 4) {
                            Button(showOriginal ? "Show translation" : "Show original") {
                                showOriginal.toggle()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            if translationVisible, let from = sourceLanguageDisplayName {
                                Text("(translated from \(from))")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.top, 4)
                        .contextMenu {
                            if let onRetranslate {
                                Button("Re-translate", action: onRetranslate)
                            }
                        }
                    } else if translationUnsupported {
                        let lang = sourceLanguageDisplayName ?? "this language"
                        Text("Translation not supported for \(lang)")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                    }

                    HStack(spacing: 8) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(attachedTasks) { task in
                                    TaskTagView(
                                        number: task.number,
                                        title: task.title,
                                        status: task.status,
                                        version: task.milestoneTitle,
                                        versionStatus: task.milestoneTitle.flatMap { versionStates[$0] },
                                        onOpen: { onInteract?(); onOpenTask?(task) },
                                        onRemove: onRemoveTask.map { remove in { remove(task) } }
                                    )
                                }
                                ForEach(issue.labels.cardChips, id: \.name) { label in
                                    LabelChipView(label: label)
                                }
                                if let version = issue.appVersion {
                                    tappable(value: version, onTap: onToggleAppVersion) {
                                        TagView(text: "v\(version)", color: appColor, isActive: activeAppVersion.contains(version))
                                    }
                                }
                                if let device = issue.device {
                                    tappable(value: device, onTap: onToggleDevice) {
                                        MetaTagView(key: "device", value: DeviceName.friendly(device), isActive: activeDevice.contains(device))
                                    }
                                }
                                if let os = issue.osVersion {
                                    tappable(value: os, onTap: onToggleOSVersion) {
                                        MetaTagView(key: "os", value: OSVersionFormat.display(os), isActive: activeOSVersion.contains(os))
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                        }
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: .black, location: tagFadeInset),
                                    .init(color: .black, location: 1.0 - tagFadeInset),
                                    .init(color: .clear, location: 1.0)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .padding(.leading, -12)

                        if issue.source == .appStore, responseController != nil, !showsAppStoreResponder {
                            AppStoreRespondBadgeButton(
                                color: appColor,
                                hasResponse: responseController?.mode == .hasResponse,
                                onRespond: {
                                    onInteract?()
                                    withAnimation(.easeOut(duration: 0.2)) { showsAppStoreResponder = true }
                                }
                            )
                        }

                        if let email = issue.email, threads.isEmpty {
                            ReplyBadgeButton(
                                email: email,
                                color: appColor,
                                onReply: {
                                    onInteract?()
                                    replyToEmail(email)
                                },
                                onCopy: {
                                    onInteract?()
                                    copyEmailToClipboard(email)
                                },
                                onTemplates: {
                                    onInteract?()
                                    showTemplatePicker = true
                                }
                            )
                            #if canImport(SwiftMail)
                            .sheet(isPresented: $showTemplatePicker) {
                                ReplyTemplatePickerView(
                                    store: replyTemplateStore,
                                    repoOwner: repoOwner,
                                    repoName: repoName,
                                    accent: appColor,
                                    onSend: { template in useTemplate(template, autoSend: true, email: email) },
                                    onPrefill: { template in useTemplate(template, autoSend: false, email: email) }
                                )
                            }
                            #endif
                        }
                    }

                    if !threads.isEmpty {
                        ForEach(threads) { thread in
                            MailThreadView(thread: thread, issue: issue, repoOwner: repoOwner, repoName: repoName, appColor: appColor)
                                .padding(.top, 8)
                        }
                    }

                    // Opened from the "Respond"/"Update response" badge, exactly like the email
                    // composer opens from Reply — an App Store card is otherwise as compact as
                    // every other feedback card.
                    if issue.source == .appStore, let responseController, showsAppStoreResponder {
                        AppStoreResponsePanel(
                            controller: responseController,
                            onClose: {
                                withAnimation(.easeOut(duration: 0.2)) { showsAppStoreResponder = false }
                            }
                        )
                    }

                    #if canImport(SwiftMail)
                    ForEach(activeInlineComposers, id: \.key) { entry in
                        InlineReplyView(
                            key: entry.key,
                            request: entry.request,
                            onClose: {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    drafts.clearOpenRequest(for: entry.key)
                                }
                            }
                        )
                        .padding(.top, 8)
                    }
                    #endif

                    if let triageSuggestion {
                        TriageSuggestionChip(
                            record: triageSuggestion,
                            taskTitle: suggestedTaskTitle,
                            isAccepting: isAcceptingSuggestion,
                            onAccept: { onAcceptSuggestion?() },
                            onDismiss: { onDismissSuggestion?() },
                            onOpenTask: onOpenSuggestedTask.map { open in
                                { onInteract?(); open() }
                            }
                        )
                        .padding(.top, 8)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .opacity(effectiveUnread ? 1 : 0)
                    .padding(.leading, 4)
                    .padding(.top, 20)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Unread")
                    .accessibilityHidden(!effectiveUnread)
            }
        }
        .background(.background)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(highlightActive ? 0.15 : 0))
                .animation(.easeOut(duration: 0.6), value: highlightActive)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        .contentShape(Rectangle())
        .onAppear { refreshThreads() }
        .onChange(of: threadStore.version) { _, _ in refreshThreads() }
        .onTapGesture { onInteract?() }
        .onChange(of: isHighlighted) { _, newValue in
            if newValue {
                highlightActive = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    highlightActive = false
                }
            }
        }
    }

    private func refreshThreads() {
        threads = threadStore.threads(forIssue: (repoOwner, repoName, issue.number, issue.title))
    }

    private var metaColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            ToggleableDateText(date: issue.createdAt, onInteract: onInteract)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize()
            HStack(spacing: 4) {
                if let typed = issue.labels.issueType {
                    IssueTypeIconButton(
                        type: typed.type,
                        isActive: activeIssueType.contains(typed.type),
                        onTap: onToggleIssueType.map { handler in
                            { onInteract?(); handler(typed.type) }
                        }
                    )
                }
                Text("#\(issue.number)")
                    .font(.system(size: 11, weight: .medium))
                Button {
                    onInteract?()
                    copyToClipboard()
                    didCopy = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        didCopy = false
                    }
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(didCopy ? AnyShapeStyle(Color.green) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help("Copy issue")
                .accessibilityLabel(didCopy ? "Copied" : "Copy issue")
            }
            .foregroundStyle(.tertiary)
        }
        .fixedSize()
    }

    @ViewBuilder
    private func tappable<Content: View>(
        value: String,
        onTap: ((String) -> Void)?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if let onTap {
            Button {
                onInteract?()
                onTap(value)
            } label: { content() }
                .buttonStyle(.plain)
        } else {
            content()
        }
    }
}

/// Selectable issue title styled at 15pt semibold. Place inline next to other
/// row-level chrome (e.g. a meta column) so the body can flow at full width
/// below it.
struct IssueTitleText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Selectable issue body. Two initializers:
/// - `body:` parses inline-only markdown so `**bold**`, `*italic*`,
///   `[link](url)`, and `` `code` `` render styled; block markdown (`##`, `-`)
///   appears verbatim. Use for GitHub issue bodies.
/// - `plainBody:` renders the input as literal characters, no markdown parsing.
///   Use for user-typed content (e.g. mail) where `**` and `_` are literal.
struct IssueBodyText: View {
    private let content: BodyContent

    private enum BodyContent {
        case empty
        case markdown(AttributedString)
        case plain(String)

        var text: Text? {
            switch self {
            case .empty: return nil
            case .markdown(let attr): return Text(attr)
            case .plain(let str): return Text(str)
            }
        }
    }

    init(body: String) {
        if body.isEmpty {
            self.content = .empty
        } else {
            var options = AttributedString.MarkdownParsingOptions()
            options.interpretedSyntax = .inlineOnlyPreservingWhitespace
            let parsed = (try? AttributedString(markdown: body, options: options)) ?? AttributedString(body)
            self.content = .markdown(parsed)
        }
    }

    init(plainBody: String) {
        self.content = plainBody.isEmpty ? .empty : .plain(plainBody)
    }

    var body: some View {
        if let bodyText = content.text {
            bodyText
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct IssueTypeIconButton: View {
    let type: IssueType
    let isActive: Bool
    let onTap: (() -> Void)?

    var body: some View {
        let icon = Image(systemName: type.systemImage)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(isActive ? AnyShapeStyle(Color.primary.opacity(0.75)) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
            .help(type.displayName)
            .accessibilityLabel("Filter by \(type.displayName)")

        if let onTap {
            Button(action: onTap) { icon }
                .buttonStyle(.plain)
        } else {
            icon
        }
    }
}

private struct TaskTagView: View {
    let number: Int
    let title: String
    var status: TaskStatus = .todo
    var version: String? = nil
    /// Release state of the attached version — colors the version badge. Falls back to the
    /// task tint when the version isn't resolved yet.
    var versionStatus: VersionState? = nil
    var onOpen: () -> Void
    var onRemove: (() -> Void)?

    /// Display form of the attached milestone/version, "v"-prefixed unless it already is.
    private var versionLabel: String? {
        guard let version = version?.trimmingCharacters(in: .whitespaces), !version.isEmpty else { return nil }
        return version.lowercased().hasPrefix("v") ? version : "v\(version)"
    }

    var body: some View {
        let tint = status.accent
        HStack(spacing: 5) {
            HStack(spacing: 5) {
                if let versionLabel {
                    // Inverted pill colored by the release's status (not the task's):
                    // fill is the version-state color, text is the surrounding background.
                    Text(versionLabel)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.background)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(versionStatus?.accent ?? tint, in: RoundedRectangle(cornerRadius: 4))
                }
                Image(systemName: "checklist").font(.system(size: 9, weight: .bold))
                Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { onOpen() }
            .help("Open task #\(number)")
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(tint.opacity(0.85))
                        #if os(iOS)
                        // Touch-friendly 22pt hit area, but the negative vertical
                        // padding pulls its layout height back so it doesn't inflate
                        // the pill — keeping this tag the same height as the others
                        // in the row (the macOS path is already compact).
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                        .padding(.vertical, -8)
                        #else
                        .padding(.leading, 1)
                        #endif
                }
                .buttonStyle(.plain)
                .help("Remove task #\(number) from this feedback")
            }
        }
        .foregroundStyle(tint)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.leading, 3)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(tint.opacity(0.4), lineWidth: 1))
    }
}

private struct LabelChipView: View {
    let label: IssueLabel

    var body: some View {
        let color = Color(hex: label.colorHex)
        Text(label.name)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color.contrastingForeground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.5), lineWidth: 0.5))
    }
}

private extension Color {
    var contrastingForeground: Color {
        // GitHub-style: pick black/white based on perceived luminance of the hex color.
        guard let components = cgColor?.components, components.count >= 3 else { return .white }
        let luminance = 0.299 * components[0] + 0.587 * components[1] + 0.114 * components[2]
        return luminance > 0.6 ? .black : .white
    }
}

private struct TagView: View {
    let text: String
    let color: Color
    let isActive: Bool
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(isActive ? 0.22 : 0.1), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(isActive ? 0.6 : 0.25), lineWidth: 1))
    }
}

private struct MetaTagView: View {
    let key: String
    let value: String
    let isActive: Bool
    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 9, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            (isActive ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08)),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(
            isActive ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.15),
            lineWidth: 1
        ))
    }
}

/// The pill chrome worn by a card's inline action badges (Reply, Respond on App Store) — one
/// definition so a new source's badge can't drift from the others.
struct CardBadgePill: ViewModifier {
    let color: Color

    func body(content: Content) -> some View {
        content
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.4), lineWidth: 1))
    }
}

extension View {
    func cardBadgePill(color: Color) -> some View { modifier(CardBadgePill(color: color)) }
}

struct ReplyBadgeButton: View {
    struct ReplyFromOption: Identifiable, Hashable {
        let id: UUID
        let address: String
    }

    let email: String
    let color: Color
    let onReply: () -> Void
    let onCopy: () -> Void
    var replyFromOptions: [ReplyFromOption] = []
    var onReplyFrom: ((UUID) -> Void)? = nil
    /// When set, renders a divider + template segment that opens the reply-template picker.
    var onTemplates: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            // Left segment: the existing reply action.
            Button(action: onReply) {
                HStack(spacing: 4) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Reply")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .help("Reply to \(email)")

            // Right segment: open the template picker. Only present when wired up.
            if let onTemplates {
                Rectangle()
                    .fill(color.opacity(0.4))
                    .frame(width: 1, height: 16)
                Button(action: onTemplates) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .help("Reply with a template")
                .accessibilityLabel("Reply with template")
            }
        }
        .cardBadgePill(color: color)
        .contextMenu {
            Button("Reply to \(email)", action: onReply)
            if !replyFromOptions.isEmpty, let onReplyFrom {
                Menu("Reply from") {
                    ForEach(replyFromOptions) { opt in
                        Button(opt.address) { onReplyFrom(opt.id) }
                    }
                }
            }
            if let onTemplates {
                Button("Reply with template…", action: onTemplates)
            }
            Button("Copy address", action: onCopy)
        }
    }
}

private struct ShimmeringText: View {
    let text: String
    @State private var phase: CGFloat = -1

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .overlay(
                LinearGradient(
                    colors: [.clear, .white.opacity(0.7), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 80)
                .offset(x: phase * 160)
                .blendMode(.plusLighter)
                .mask(Text(text))
            )
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

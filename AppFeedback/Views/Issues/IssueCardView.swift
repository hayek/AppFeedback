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
    var activeApp: Set<String> = []
    var activeAppVersion: Set<String> = []
    var activeDevice: Set<String> = []
    var activeOSVersion: Set<String> = []
    var onToggleApp: ((String) -> Void)? = nil
    var onToggleAppVersion: ((String) -> Void)? = nil
    var onToggleDevice: ((String) -> Void)? = nil
    var onToggleOSVersion: ((String) -> Void)? = nil
    var activeIssueType: Set<IssueType> = []
    var onToggleIssueType: ((IssueType) -> Void)? = nil
    var intelligenceAvailable: Bool = false
    var targetLanguageCode: String = "en"
    var isTranslating: Bool = false
    var isHighlighted: Bool = false
    var translationUnsupported: Bool = false
    var onRetranslate: (() -> Void)? = nil

    @Environment(MailThreadStore.self) private var threadStore
    #if canImport(SwiftMail)
    @Environment(MailDraftStore.self) private var drafts
    #endif

    @State private var showOriginal: Bool = false
    @State private var highlightActive: Bool = false
    @State private var didCopy: Bool = false
    @State private var threads: [MailThread] = []

    private var translationVisible: Bool { issue.hasTranslation && !showOriginal }

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

    private var needsTranslationButUnavailable: Bool {
        guard !intelligenceAvailable else { return false }
        guard let detected = issue.detectedLanguageCode, !detected.isEmpty else { return false }
        return !detected.hasPrefix(targetLanguageCode)
    }

    private var copyText: String {
        var lines: [String] = []
        lines.append(issue.displayedTitle(translated: translationVisible))
        let body = issue.displayedBody(translated: translationVisible)
        if !body.isEmpty {
            lines.append("")
            lines.append(body)
        }
        var badges: [String] = []
        if let typed = issue.labels.issueType {
            badges.append(typed.type.displayName)
        }
        for label in issue.labels.withoutTypeAndUserSubmitted {
            badges.append(label.name)
        }
        if let app = issue.appName { badges.append(app) }
        if let version = issue.appVersion { badges.append("v\(version)") }
        if let device = issue.device { badges.append("device: \(DeviceName.friendly(device))") }
        if let os = issue.osVersion { badges.append("os: \(OSVersionFormat.display(os))") }
        if let email = issue.email { badges.append("✉ \(email)") }
        if !badges.isEmpty {
            lines.append("")
            lines.append(badges.joined(separator: " • "))
        }
        return lines.joined(separator: "\n")
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
                if effectiveUnread {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                        .padding(.top, 6)
                        .accessibilityLabel("Unread")
                }
                VStack(alignment: .leading, spacing: 8) {
                    let titleText = issue.displayedTitle(translated: translationVisible)
                    let bodyText = issue.displayedBody(translated: translationVisible)
                    HStack(alignment: .top, spacing: 12) {
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
                    } else if needsTranslationButUnavailable {
                        Text("Apple Intelligence required to translate")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                    }

                    HStack(spacing: 8) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(issue.labels.withoutTypeAndUserSubmitted, id: \.name) { label in
                                    LabelChipView(label: label)
                                }
                                if let app = issue.appName, !activeApp.contains(app) {
                                    tappable(value: app, onTap: onToggleApp) {
                                        TagView(text: app, color: appColor, isActive: activeApp.contains(app))
                                    }
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
                                    .init(color: .black, location: 0.04),
                                    .init(color: .black, location: 0.96),
                                    .init(color: .clear, location: 1.0)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .padding(.leading, -12)

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
                                }
                            )
                        }
                    }

                    if !threads.isEmpty {
                        ForEach(threads) { thread in
                            MailThreadView(thread: thread, issue: issue, repoOwner: repoOwner, repoName: repoName, appColor: appColor)
                                .padding(.top, 8)
                        }
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
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
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

    var body: some View {
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
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Reply to \(email)")
        .contextMenu {
            Button("Reply to \(email)", action: onReply)
            if !replyFromOptions.isEmpty, let onReplyFrom {
                Menu("Reply from") {
                    ForEach(replyFromOptions) { opt in
                        Button(opt.address) { onReplyFrom(opt.id) }
                    }
                }
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

import SwiftUI

struct IssueCardView: View {
    let issue: FeedbackIssue
    let appColor: Color
    var isUnread: Bool = false
    var onInteract: (() -> Void)? = nil
    var activeApp: String? = nil
    var activeAppVersion: String? = nil
    var activeDevice: String? = nil
    var activeOSVersion: String? = nil
    var onToggleApp: ((String) -> Void)? = nil
    var onToggleAppVersion: ((String) -> Void)? = nil
    var onToggleDevice: ((String) -> Void)? = nil
    var onToggleOSVersion: ((String) -> Void)? = nil
    var activeIssueType: IssueType? = nil
    var onToggleIssueType: ((IssueType) -> Void)? = nil
    var onTapEmail: ((String) -> Void)? = nil
    var intelligenceAvailable: Bool = false
    var targetLanguageCode: String = "en"

    @State private var showOriginal: Bool = false

    private var translationVisible: Bool { issue.hasTranslation && !showOriginal }

    private var needsTranslationButUnavailable: Bool {
        guard !intelligenceAvailable else { return false }
        guard let detected = issue.detectedLanguageCode, !detected.isEmpty else { return false }
        return !detected.hasPrefix(targetLanguageCode)
    }

    private var formattedDate: String {
        issue.createdAt.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(appColor)
                .frame(width: 3)
                .clipShape(UnevenRoundedRectangle(
                    topLeadingRadius: 10, bottomLeadingRadius: 10,
                    bottomTrailingRadius: 0, topTrailingRadius: 0
                ))

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    if isUnread {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                            .padding(.top, 6)
                            .accessibilityLabel("Unread")
                    }
                    HStack(spacing: 4) {
                        Text("#\(issue.number)")
                            .font(.system(size: 11, weight: .medium))
                        if let typed = issue.labels.issueType {
                            IssueTypeIconButton(
                                type: typed.type,
                                isActive: activeIssueType == typed.type,
                                onTap: onToggleIssueType.map { handler in
                                    { onInteract?(); handler(typed.type) }
                                }
                            )
                        }
                    }
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                    Text(issue.displayedTitle(translated: translationVisible))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Text(formattedDate)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                        .fixedSize()
                }

                let bodyText = issue.displayedBody(translated: translationVisible)
                if !bodyText.isEmpty {
                    MarkdownBodyView(text: bodyText)
                        .textSelection(.enabled)
                }

                if issue.hasTranslation {
                    Button(showOriginal ? "Show translation" : "Show original") {
                        showOriginal.toggle()
                    }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                } else if needsTranslationButUnavailable {
                    Text("Apple Intelligence required to translate")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(issue.labels.withoutTypeAndUserSubmitted, id: \.name) { label in
                            LabelChipView(label: label)
                        }
                        if let app = issue.appName {
                            tappable(value: app, onTap: onToggleApp) {
                                TagView(text: app, color: appColor, isActive: activeApp == app)
                            }
                        }
                        if let version = issue.appVersion {
                            tappable(value: version, onTap: onToggleAppVersion) {
                                TagView(text: "v\(version)", color: appColor, isActive: activeAppVersion == version)
                            }
                        }
                        if let device = issue.device {
                            tappable(value: device, onTap: onToggleDevice) {
                                MetaTagView(key: "device", value: device, isActive: activeDevice == device)
                            }
                        }
                        if let os = issue.osVersion {
                            tappable(value: os, onTap: onToggleOSVersion) {
                                MetaTagView(key: "os", value: os, isActive: activeOSVersion == os)
                            }
                        }
                        if let email = issue.email {
                            if let onTapEmail {
                                Button {
                                    onInteract?()
                                    onTapEmail(email)
                                } label: {
                                    MetaTagView(key: "✉", value: email, isActive: false)
                                }
                                .buttonStyle(.plain)
                            } else if let encoded = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                                      let mailURL = URL(string: "mailto:\(encoded)") {
                                Link(destination: mailURL) {
                                    MetaTagView(key: "✉", value: email, isActive: false)
                                }
                                .simultaneousGesture(TapGesture().onEnded { onInteract?() })
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        .contentShape(Rectangle())
        .onTapGesture { onInteract?() }
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

private struct MarkdownBodyView: View {
    private let blocks: [MarkdownBlock]

    init(text: String) {
        self.blocks = MarkdownBlock.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inlineMarkdown(text))
                .font(.system(size: headingSize(level), weight: .semibold))
                .foregroundStyle(.primary)
        case .paragraph(let lines):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(inlineMarkdown(line))
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(idx + 1)." : "•")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 16, alignment: .trailing)
                        Text(inlineMarkdown(item))
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 17
        case 2: return 15
        default: return 14
        }
    }

    private func inlineMarkdown(_ s: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    }
}

private enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(lines: [String])
    case list(ordered: Bool, items: [String])

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var listItems: [String] = []
        var listOrdered: Bool? = nil

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(lines: paragraph))
                paragraph = []
            }
        }
        func flushList() {
            if let ordered = listOrdered, !listItems.isEmpty {
                blocks.append(.list(ordered: ordered, items: listItems))
            }
            listItems = []
            listOrdered = nil
        }
        func flushAll() { flushParagraph(); flushList() }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty { flushAll(); continue }

            if let (level, content) = parseHeading(line) {
                flushAll()
                blocks.append(.heading(level: level, text: content))
                continue
            }

            if let item = parseOrderedItem(line) {
                flushParagraph()
                if listOrdered == false { flushList() }
                listOrdered = true
                listItems.append(item)
                continue
            }

            if let item = parseUnorderedItem(line) {
                flushParagraph()
                if listOrdered == true { flushList() }
                listOrdered = false
                listItems.append(item)
                continue
            }

            flushList()
            paragraph.append(line)
        }
        flushAll()
        return blocks
    }

    private static func parseHeading(_ line: String) -> (Int, String)? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
            if level > 6 { return nil }
        }
        guard level > 0, level < line.count else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        return (level, String(rest.drop(while: { $0 == " " })))
    }

    private static func parseOrderedItem(_ line: String) -> String? {
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let prefix = line[line.startIndex..<dot]
        guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber) else { return nil }
        let after = line.index(after: dot)
        guard after < line.endIndex, line[after] == " " else { return nil }
        return String(line[line.index(after: after)...])
    }

    private static func parseUnorderedItem(_ line: String) -> String? {
        guard let first = line.first, first == "-" || first == "*" || first == "+" else { return nil }
        let rest = line.dropFirst()
        guard rest.first == " " else { return nil }
        return String(rest.drop(while: { $0 == " " }))
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

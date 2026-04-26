import SwiftUI

struct IssueCardView: View {
    let issue: FeedbackIssue
    let appColor: Color

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
                    Text("#\(issue.number)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                    Text(issue.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }

                if !issue.description.isEmpty {
                    Text(attributedDescription)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(4)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if let app = issue.appName {
                            TagView(text: app + (issue.appVersion.map { " v\($0)" } ?? ""),
                                    color: appColor)
                        }
                        if let device = issue.device {
                            MetaTagView(key: "device", value: device)
                        }
                        if let os = issue.osVersion {
                            MetaTagView(key: "os", value: os)
                        }
                        if let email = issue.email {
                            if let mailURL = URL(string: "mailto:\(email)") {
                                Link(destination: mailURL) {
                                    MetaTagView(key: "✉", value: email)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                        Text(formattedDate)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }

    private var attributedDescription: AttributedString {
        (try? AttributedString(markdown: issue.description)) ?? AttributedString(issue.description)
    }
}

private struct TagView: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.25), lineWidth: 1))
    }
}

private struct MetaTagView: View {
    let key: String
    let value: String
    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 9, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.15), lineWidth: 1))
    }
}

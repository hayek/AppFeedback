#if os(macOS)
import SwiftUI

struct ActivityWindow: View {
    @Environment(ActivityLog.self) private var log
    @State private var filter: KindFilter = .all

    enum KindFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case fetches = "Fetches"
        case emails = "Emails"
        var id: String { rawValue }
    }

    private var filteredEntries: [ActivityLogEntry] {
        switch filter {
        case .all:     return log.entries
        case .fetches: return log.entries.filter { $0.kind == .fetchIssues }
        case .emails:  return log.entries.filter { $0.kind == .sendEmail || $0.kind == .testConnection }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $filter) {
                ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(8)

            if filteredEntries.isEmpty {
                ContentUnavailableView("No Activity", systemImage: "list.bullet.rectangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredEntries) { entry in
                    ActivityRow(entry: entry)
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Spacer()
                Button("Clear All", role: .destructive) {
                    log.clearAll()
                }
                .disabled(log.entries.isEmpty)
            }
            .padding(8)
        }
        .frame(minWidth: 480, minHeight: 360)
    }
}

private struct ActivityRow: View {
    let entry: ActivityLogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 13))
                if let detail = entry.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            ToggleableDateText(date: entry.timestamp)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        switch entry.kind {
        case .fetchIssues:        return "arrow.down.circle"
        case .sendEmail:          return "paperplane"
        case .testConnection:     return "checkmark.shield"
        case .fetchMail:          return "envelope.badge"
        case .downloadAttachment: return "paperclip"
        case .postComment:        return "bubble.left.and.text.bubble.right"
        case .createIssue:        return "plus.circle"
        }
    }

    private var iconColor: Color {
        switch entry.status {
        case .inProgress: return .secondary
        case .success:    return .green
        case .failure:    return .red
        }
    }
}
#endif

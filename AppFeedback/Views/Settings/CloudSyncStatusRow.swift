import SwiftUI

struct CloudSyncStatusRow: View {
    let state: SyncState

    var body: some View {
        let style = Style(state: state)
        HStack(spacing: 10) {
            Image(systemName: style.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(style.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(style.title)
                    .font(.system(size: 12, weight: .semibold))
                if let detail = style.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if style.showsOpenSettings {
                Button("Open Settings", action: openSystemSettings)
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .bottom)
    }

    private struct Style {
        let icon: String
        let tint: Color
        let title: String
        let detail: String?
        let showsOpenSettings: Bool

        init(state: SyncState) {
            switch state {
            case .unknown:
                icon = "icloud"
                tint = .secondary
                title = "Checking iCloud…"
                detail = nil
                showsOpenSettings = false
            case .syncing:
                icon = "checkmark.icloud"
                tint = .green
                title = "Syncing via iCloud"
                detail = nil
                showsOpenSettings = false
            case .unavailable(let reason):
                icon = "icloud.slash"
                tint = .orange
                title = "iCloud unavailable"
                detail = switch reason {
                case .notSignedIn:            "Sign in to sync across devices."
                case .restricted:             "iCloud is restricted on this device."
                case .temporarilyUnavailable: "Try again in a moment."
                }
                showsOpenSettings = true
            case .error(let message):
                icon = "exclamationmark.icloud"
                tint = .red
                title = "iCloud error"
                detail = message
                showsOpenSettings = false
            }
        }
    }

    private func openSystemSettings() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane") {
            NSWorkspace.shared.open(url)
        }
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
}

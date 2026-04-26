import SwiftUI

struct CloudSyncStatusRow: View {
    let state: SyncState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if showsOpenSettingsButton {
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

    private var iconName: String {
        switch state {
        case .unknown:           return "icloud"
        case .syncing:           return "checkmark.icloud"
        case .unavailable:       return "icloud.slash"
        case .error:             return "exclamationmark.icloud"
        }
    }

    private var tint: Color {
        switch state {
        case .unknown:     return .secondary
        case .syncing:     return .green
        case .unavailable: return .orange
        case .error:       return .red
        }
    }

    private var title: String {
        switch state {
        case .unknown:           return "Checking iCloud…"
        case .syncing:           return "Syncing via iCloud"
        case .unavailable:       return "iCloud unavailable"
        case .error:             return "iCloud error"
        }
    }

    private var detail: String? {
        switch state {
        case .unavailable(let reason):
            switch reason {
            case .notSignedIn:           return "Sign in to sync across devices."
            case .restricted:            return "iCloud is restricted on this device."
            case .temporarilyUnavailable: return "Try again in a moment."
            }
        case .error(let message):        return message
        default:                         return nil
        }
    }

    private var showsOpenSettingsButton: Bool {
        if case .unavailable = state { return true }
        return false
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

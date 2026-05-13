#if os(macOS)
import SwiftUI

/// macOS Settings-style top tab strip: icon stacked over label, subtle highlight
/// on the active tab. Mirrors Apple's preferences look — needed because we use a
/// regular Window scene (which doesn't auto-style TabView's `.tabItem` with icons).
struct SettingsTabBar: View {
    @Binding var selection: SettingsTab
    let hasNotifications: Bool

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            tab(.repos,         icon: "folder",   label: "Repos")
            tab(.email,         icon: "envelope", label: "Email")
            tab(.intelligence,  icon: "sparkles", label: "Intelligence")
            if hasNotifications {
                tab(.notifications, icon: "bell", label: "Notifications")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func tab(_ tab: SettingsTab, icon: String, label: String) -> some View {
        let isSelected = selection == tab
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { selection = tab }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                Text(label)
                    .font(.system(size: 11))
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .frame(minWidth: 64)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
    }
}
#endif

#if os(macOS) || os(iOS)
import SwiftUI

extension SMTPCredentials.Preset {
    var iconSystemName: String {
        switch self {
        case .gmail:   return "envelope.fill"
        case .icloud:  return "icloud.fill"
        case .outlook: return "envelope.fill"
        case .custom:  return "gearshape.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .gmail:   return Color(red: 0.94, green: 0.27, blue: 0.20)   // Gmail red
        case .icloud:  return Color(red: 0.20, green: 0.55, blue: 0.93)   // iCloud blue
        case .outlook: return Color(red: 0.00, green: 0.46, blue: 0.79)   // Outlook blue
        case .custom:  return Color.gray
        }
    }
}

/// Circular provider chip used in the account list, sheet headers, and add-flow hero.
/// Size 28 fits a Form row; 44 fits a sheet header. Use the same shape across surfaces.
struct MailProviderBadge: View {
    let preset: SMTPCredentials.Preset
    var size: CGFloat = 28

    var body: some View {
        Circle()
            .fill(preset.tintColor.opacity(0.16))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: preset.iconSystemName)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(preset.tintColor)
            }
    }
}
#endif

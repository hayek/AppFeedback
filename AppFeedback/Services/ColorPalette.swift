import SwiftUI

enum ColorPalette {
    static let palette: [Color] = [
        Color(hex: "4ef8d0"), Color(hex: "7b8cff"), Color(hex: "ff6b8a"), Color(hex: "ffb347"),
        Color(hex: "a78bfa"), Color(hex: "34d399"), Color(hex: "f87171"), Color(hex: "60a5fa"),
        Color(hex: "fbbf24"), Color(hex: "e879f9"), Color(hex: "38bdf8"), Color(hex: "fb923c"),
    ]

    static func color(for appName: String, in allApps: [String]) -> Color {
        let sorted = allApps.sorted()
        guard let index = sorted.firstIndex(of: appName) else {
            return Color(hex: "888888")
        }
        return palette[index % palette.count]
    }
}

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >>  8) & 0xFF) / 255
        let b = Double( int        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

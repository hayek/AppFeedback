import SwiftUI
#if os(macOS)
import AppKit
#endif

enum ColorPalette {
    struct Swatch: Hashable {
        let name: String
        let hex: String
    }

    static let swatches: [Swatch] = [
        Swatch(name: "Mint",       hex: "4ef8d0"),
        Swatch(name: "Periwinkle", hex: "7b8cff"),
        Swatch(name: "Rose",       hex: "ff6b8a"),
        Swatch(name: "Apricot",    hex: "ffb347"),
        Swatch(name: "Lavender",   hex: "a78bfa"),
        Swatch(name: "Emerald",    hex: "34d399"),
        Swatch(name: "Coral",      hex: "f87171"),
        Swatch(name: "Sky",        hex: "60a5fa"),
        Swatch(name: "Amber",      hex: "fbbf24"),
        Swatch(name: "Orchid",     hex: "e879f9"),
        Swatch(name: "Cyan",       hex: "38bdf8"),
        Swatch(name: "Tangerine",  hex: "fb923c"),
    ]

    static let paletteHex: [String] = swatches.map(\.hex)
    static let palette: [Color] = paletteHex.map(Color.init(hex:))

    static func name(forHex hex: String) -> String? {
        swatches.first { $0.hex == hex }?.name
    }

    #if os(macOS)
    /// Filled colored circle as an NSImage. macOS strips SwiftUI tinting from
    /// menu items, but `Image(nsImage:)` with `isTemplate = false` survives.
    static func swatchImage(hex: String, diameter: CGFloat = 12) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(Color(hex: hex)).setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
    #endif

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

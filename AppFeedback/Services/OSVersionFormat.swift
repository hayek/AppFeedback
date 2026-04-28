import Foundation

enum OSVersionFormat {
    /// Strips locale-specific "Version"/"Build" labels and renders as `v<version>(<build>)`.
    static func display(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return raw }

        var version = trimmed
        var build: String?

        if let openIdx = trimmed.lastIndex(of: "("),
           let closeIdx = trimmed.lastIndex(of: ")"),
           openIdx < closeIdx {
            let inside = trimmed[trimmed.index(after: openIdx)..<closeIdx]
            if let r = inside.range(of: #"[0-9]+[A-Z][0-9]+[a-zA-Z0-9]*"#, options: .regularExpression) {
                build = String(inside[r])
            } else {
                let tokens = inside.split(whereSeparator: { $0.isWhitespace })
                if let last = tokens.last { build = String(last) }
            }
            version = String(trimmed[..<openIdx]).trimmingCharacters(in: .whitespaces)
        }

        guard let r = version.range(of: #"\d+(?:\.\d+)+"#, options: .regularExpression) else {
            // Try single integer version (e.g. "17")
            if let r2 = version.range(of: #"\d+"#, options: .regularExpression) {
                let v = String(version[r2])
                if let build, !build.isEmpty {
                    return "v\(v)(\(build))"
                }
                return "v\(v)"
            }
            return raw  // unparseable; preserve original
        }
        let v = String(version[r])

        if let build, !build.isEmpty {
            return "v\(v)(\(build))"
        }
        return "v\(v)"
    }
}

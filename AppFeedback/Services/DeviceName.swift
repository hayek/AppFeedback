import Foundation

/// Maps Apple model identifiers (e.g. `Mac17,5`) to marketing names.
///
/// Lookup order:
/// 1. Latest catalog fetched from AppleDB and cached on disk (refreshed weekly).
/// 2. Catalog bundled at build time by `Scripts/fetch-appledb.sh` (always present).
/// 3. The raw identifier itself, when nothing matches.
enum DeviceName {
    @MainActor
    static func friendly(_ raw: String) -> String {
        let key = raw.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return raw }
        return DeviceCatalog.shared.name(for: key) ?? raw
    }
}

@MainActor
final class DeviceCatalog {
    static let shared = DeviceCatalog()

    private static let remoteURL = URL(string: "https://api.appledb.dev/device/main.json")!
    private static let cacheTTL: TimeInterval = 7 * 24 * 60 * 60
    private static let keepTypes: Set<String> = [
        "iPhone", "iPad", "iPad Air", "iPad Pro", "iPad mini", "iPod touch",
        "MacBook", "MacBook Air", "MacBook Pro", "MacBook Neo",
        "Mac mini", "Mac Pro", "Mac Studio", "iMac",
        "Apple Watch", "Apple TV", "HomePod", "Headset",
    ]

    private var map: [String: String]
    private var refreshing = false

    init() {
        self.map = Self.loadMap(from: Self.cacheURL)
            ?? Self.loadMap(from: Bundle.main.url(forResource: "AppleDevices", withExtension: "json"))
            ?? [:]
        refreshIfStale()
    }

    func name(for identifier: String) -> String? {
        map[identifier]
    }

    func refreshIfStale() {
        guard !refreshing, Self.cacheIsStale() else { return }
        refreshing = true
        Task.detached(priority: .utility) { [weak self] in
            let fresh = await Self.fetchRemote()
            await self?.applyRefresh(fresh)
        }
    }

    private func applyRefresh(_ fresh: [String: String]?) {
        if let fresh {
            Self.writeCache(fresh)
            map = fresh
        }
        refreshing = false
    }

    // MARK: - Loading

    private static func loadMap(from url: URL?) -> [String: String]? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    private static func cacheIsStale() -> Bool {
        guard let url = cacheURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date else { return true }
        return Date().timeIntervalSince(modified) > cacheTTL
    }

    private static func writeCache(_ map: [String: String]) {
        guard let url = cacheURL else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try? JSONEncoder().encode(map)
        try? data?.write(to: url, options: .atomic)
    }

    private static var cacheURL: URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .cachesDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true) else { return nil }
        return base.appendingPathComponent("AppleDevices.json")
    }

    // MARK: - Remote

    private struct RemoteDevice: Decodable {
        let name: String?
        let identifier: [String]?
        let type: String?
    }

    private static func fetchRemote() async -> [String: String]? {
        let request = URLRequest(url: remoteURL, timeoutInterval: 30)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let devices = try? JSONDecoder().decode([RemoteDevice].self, from: data)
        else { return nil }

        var out: [String: String] = [:]
        out.reserveCapacity(devices.count)
        for d in devices {
            guard let type = d.type, keepTypes.contains(type),
                  let name = d.name, let ids = d.identifier else { continue }
            for id in ids where !id.isEmpty { out[id] = name }
        }
        return out.isEmpty ? nil : out
    }
}

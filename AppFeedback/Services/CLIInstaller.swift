#if os(macOS)
import Foundation
import AppKit

/// Installs the CLI and the AI skill as symlinks.
///
/// Symlink, never copy: the app's restricted entitlements (keychain-access-groups) validate
/// against the signature and provisioning inside the .app, so a copied binary loses keychain
/// access — and a copied skill silently drifts from the CLI it documents.
enum CLIInstaller {

    enum InstallStatus: Equatable {
        case notInstalled
        case installed(URL)
        case brokenLink(URL)
        /// Something we didn't install sits at the path — a user's own script, folder or link.
        /// Never touched without an explicit button press.
        case occupied(URL)
    }

    static var defaultCandidates: [URL] {
        [URL(filePath: "/usr/local/bin"),
         URL.homeDirectory.appending(path: ".local/bin")]
    }

    /// The running app's executable, resolved through any symlink so re-installing points at
    /// the real app. `nil` when it can't be trusted, in which case we refuse to install.
    ///
    /// Derived from the bundle, never from argv[0]: a bare `appfeedback` with no subcommand is
    /// not a CLI invocation, so it falls through to the GUI — and a PATH lookup passes just the
    /// command name, which `resolvingSymlinksInPath()` would resolve against the shell's
    /// working directory. `refreshInstalledLinks()` would then re-point the user's PATH symlink
    /// at a file that doesn't exist in whatever directory they happened to be standing in.
    static var binaryURL: URL? {
        let candidates = [CLIBranding.appBundle.executableURL,
                          Bundle.main.executablePath.map { URL(filePath: $0) }]
        for candidate in candidates.compactMap({ $0 }) {
            let resolved = candidate.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix("/"), isInsideAppBundle(resolved) else { continue }
            return resolved
        }
        return nil
    }

    /// A binary worth symlinking lives inside a `.app` — anything else means we misresolved
    /// ourselves and would install a link to nowhere.
    private static func isInsideAppBundle(_ url: URL) -> Bool {
        url.pathComponents.dropLast().contains { $0.hasSuffix(".app") }
    }

    /// The skill folder inside the app bundle. Resolved via `CLIBranding.appBundle` so it is
    /// still correct when the binary was exec'd through the installed symlink.
    static var skillSourceURL: URL? {
        CLIBranding.appBundle.resourceURL?.appending(path: "Skill/\(CLIBranding.skillFolderName)")
    }

    static var skillDestinationURL: URL {
        URL.homeDirectory.appending(path: ".claude/skills/\(CLIBranding.skillFolderName)")
    }

    // MARK: - Status

    static func cliStatus(searchPaths: [URL] = defaultCandidates) -> InstallStatus {
        status(of: searchPaths.map { $0.appending(path: CLIBranding.commandName) },
               expecting: binaryURL)
    }

    static func skillStatus() -> InstallStatus {
        status(of: [skillDestinationURL], expecting: skillSourceURL)
    }

    /// `expecting` is what *we* would install here; anything else at the path is the user's.
    private static func status(of links: [URL], expecting source: URL?) -> InstallStatus {
        let manager = FileManager.default
        for link in links {
            guard let target = try? manager.destinationOfSymbolicLink(atPath: link.path) else {
                // A real file or directory — a hand-written wrapper script, say. Reporting it as
                // installed would let the next launch quietly replace it.
                if manager.fileExists(atPath: link.path) { return .occupied(link) }
                continue
            }
            let resolved = target.hasPrefix("/")
                ? target
                : link.deletingLastPathComponent().appending(path: target).path
            guard isOurs(target: resolved, source: source) else { return .occupied(link) }
            return manager.fileExists(atPath: resolved) ? .installed(link) : .brokenLink(link)
        }
        return .notInstalled
    }

    /// A link is ours when it points at what we install. Matched by file name as well as by
    /// full path, because the whole point of the refresh is to fix links left dangling by a
    /// moved or rebuilt app — those no longer resolve to the current bundle path.
    private static func isOurs(target: String, source: URL?) -> Bool {
        guard let source else { return true }   // can't tell; don't cry wolf over our own link
        return target == source.path
            || URL(filePath: target).lastPathComponent == source.lastPathComponent
    }

    // MARK: - Install

    @discardableResult
    static func installCLI(candidates: [URL] = defaultCandidates,
                           binary: URL? = nil) throws -> URL {
        guard let source = binary ?? binaryURL else { throw CocoaError(.fileNoSuchFile) }
        return try link(source: source, intoFirstWritable: candidates,
                        named: CLIBranding.commandName)
    }

    @discardableResult
    static func installSkill(source: URL? = skillSourceURL,
                             destination: URL = skillDestinationURL) throws -> URL {
        guard let source, FileManager.default.fileExists(atPath: source.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try replaceSymlink(at: destination, pointingTo: source)
        return destination
    }

    /// Re-points links we installed ourselves so a moved or rebuilt app self-heals. Never
    /// installs something the user hasn't asked for, never touches a path occupied by something
    /// we didn't install, and never throws — this runs at launch.
    static func refreshInstalledLinks() {
        switch cliStatus() {
        case .installed, .brokenLink: try? installCLI()
        case .notInstalled, .occupied: break
        }
        switch skillStatus() {
        case .installed, .brokenLink: try? installSkill()
        case .notInstalled, .occupied: break
        }
    }

    static func revealSkillInFinder() {
        guard let source = skillSourceURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([source])
    }

    // MARK: - Helpers

    private static func link(source: URL, intoFirstWritable candidates: [URL],
                             named name: String) throws -> URL {
        let manager = FileManager.default
        var lastError: Error = CocoaError(.fileWriteNoPermission)
        for directory in candidates {
            guard manager.fileExists(atPath: directory.path),
                  manager.isWritableFile(atPath: directory.path) else { continue }
            do {
                let destination = directory.appending(path: name)
                try replaceSymlink(at: destination, pointingTo: source)
                return destination
            } catch { lastError = error }
        }
        throw lastError
    }

    private static func replaceSymlink(at destination: URL, pointingTo source: URL) throws {
        let manager = FileManager.default
        if (try? manager.destinationOfSymbolicLink(atPath: destination.path)) != nil {
            try manager.removeItem(at: destination)     // a link — ours to re-point
        } else if manager.fileExists(atPath: destination.path) {
            // A real file or folder: a hand-written skill with the user's notes in it, or their
            // own wrapper script. Deleting it would be unrecoverable, so move it aside instead.
            try manager.moveItem(at: destination, to: backupURL(for: destination))
        }
        try manager.createSymbolicLink(at: destination, withDestinationURL: source)
    }

    /// `appfeedback.backup-2026-07-27`, numbered if the user installs twice in one day.
    private static func backupURL(for destination: URL) -> URL {
        let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let directory = destination.deletingLastPathComponent()
        let base = "\(destination.lastPathComponent).backup-\(stamp)"
        var candidate = directory.appending(path: base)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: "\(base)-\(suffix)")
            suffix += 1
        }
        return candidate
    }
}
#endif

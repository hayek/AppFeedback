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
    }

    static var defaultCandidates: [URL] {
        [URL(filePath: "/usr/local/bin"),
         URL.homeDirectory.appending(path: ".local/bin")]
    }

    /// The running binary, resolved through any symlink so re-installing points at the real app.
    static var binaryURL: URL {
        URL(filePath: CommandLine.arguments.first ?? Bundle.main.executablePath ?? "")
            .resolvingSymlinksInPath()
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
        status(of: searchPaths.map { $0.appending(path: CLIBranding.commandName) })
    }

    static func skillStatus() -> InstallStatus { status(of: [skillDestinationURL]) }

    private static func status(of links: [URL]) -> InstallStatus {
        let manager = FileManager.default
        for link in links {
            guard let target = try? manager.destinationOfSymbolicLink(atPath: link.path) else {
                if manager.fileExists(atPath: link.path) { return .installed(link) }  // real file, not a link
                continue
            }
            let resolved = target.hasPrefix("/")
                ? target
                : link.deletingLastPathComponent().appending(path: target).path
            return manager.fileExists(atPath: resolved) ? .installed(link) : .brokenLink(link)
        }
        return .notInstalled
    }

    // MARK: - Install

    @discardableResult
    static func installCLI(candidates: [URL] = defaultCandidates,
                           binary: URL = binaryURL) throws -> URL {
        try link(source: binary, intoFirstWritable: candidates, named: CLIBranding.commandName)
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

    /// Re-points whatever is already installed so a moved or rebuilt app self-heals. Never
    /// installs something the user hasn't asked for, and never throws — this runs at launch.
    static func refreshInstalledLinks() {
        if case .notInstalled = cliStatus() {} else { try? installCLI() }
        if case .notInstalled = skillStatus() {} else { try? installSkill() }
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
        if manager.fileExists(atPath: destination.path)
            || (try? manager.destinationOfSymbolicLink(atPath: destination.path)) != nil {
            try manager.removeItem(at: destination)
        }
        try manager.createSymbolicLink(at: destination, withDestinationURL: source)
    }
}
#endif

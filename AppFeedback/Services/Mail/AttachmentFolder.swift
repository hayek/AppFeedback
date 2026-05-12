import Foundation
#if os(macOS)
import AppKit
#endif

enum AttachmentFolder {
    /// Resolves the destination directory for downloaded attachments.
    /// On macOS: tries to resolve `account.attachmentFolderBookmark` (security-scoped).
    /// On iOS: same idea (UIKit-side bookmark resolution).
    /// Falls back to `~/Downloads` (mac) / `Documents/Attachments` (iOS).
    /// Caller is responsible for `startAccessingSecurityScopedResource` / stopAccessing if true is returned.
    /// Returns: (url, didStartScopedAccess)
    static func resolveDestination(bookmarkData: Data?) -> (url: URL, didStartScoped: Bool) {
        if let bookmarkData, !bookmarkData.isEmpty {
            #if os(macOS)
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), !stale {
                let started = url.startAccessingSecurityScopedResource()
                return (url, started)
            }
            #else
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), !stale {
                return (url, false)
            }
            #endif
        }
        return (defaultDestination(), false)
    }

    static func defaultDestination() -> URL {
        #if os(macOS)
        return FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        #else
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("Attachments", isDirectory: true)
        #endif
    }

    /// Make sure the directory exists. Returns true on success.
    @discardableResult
    static func ensureExists(_ url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }
}

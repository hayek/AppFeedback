#if os(macOS)
import Foundation
import SwiftData
import SQLite3

/// Read-only access to the app's two SwiftData stores.
///
/// Deliberately does NOT reuse the app's stores (ProductStore and friends): those are
/// built to write — seeding defaults, running migrations, saving on read — which an
/// `allowsSave: false` container rejects.
///
/// The schema lists must stay identical to `AppFeedbackApp.init`. If they drift,
/// SwiftData attempts an in-place migration, which fails on a read-only store — a loud
/// failure mapped to exit 3, which is the behaviour we want.
struct CLIStore {

    struct Paths {
        let local: URL
        let cloud: URL

        static var `default`: Paths {
            let base = URL.applicationSupportDirectory
            return Paths(local: base.appending(path: "local.store"),
                         cloud: base.appending(path: "cloud.store"))
        }
    }

    /// One container spanning both stores, exactly as the app builds it. Core Data routes each
    /// fetch to the store that owns the entity, so a single context serves both; `local` and
    /// `cloud` are named views onto it purely for call-site clarity.
    let context: ModelContext
    var local: ModelContext { context }
    var cloud: ModelContext { context }

    static let localTypes: [any PersistentModel.Type] = [
        CachedIssue.self, MailAttachmentLocal.self, MailAccountLocalState.self,
        RepoFetchState.self, FeedbackAttachmentLocal.self, TriageVerdictRecord.self,
    ]
    static let cloudTypes: [any PersistentModel.Type] = [
        Product.self, Repo.self, SeenIssue.self, MailAccount.self,
        GitHubAccount.self, MailSettings.self, MailThread.self, MailMessage.self,
        MailAttachment.self, IssueTranslation.self, IssueSummaryCache.self,
        ProjectVersion.self, SentReleaseNotification.self, ReplyTemplate.self,
        RepoFilterPreference.self, AppStoreReviewMirror.self,
    ]
    static var localSchema: Schema { Schema(localTypes) }
    static var cloudSchema: Schema { Schema(cloudTypes) }

    static func open(paths: Paths = .default) throws -> CLIStore {
        // Existence check first: a ModelContainer pointed at a missing file CREATES one,
        // which is a write and would mask the "app never launched" condition.
        for url in [paths.local, paths.cloud] where !FileManager.default.fileExists(atPath: url.path) {
            throw CLIError.noLocalData(
                message: "No local feedback data at \(url.path).",
                hint: "Launch AppFeedback once so it can sync, then re-run.")
        }
        do {
            return CLIStore(context: ModelContext(try container(paths: paths)))
        } catch {
            throw CLIError.noLocalData(
                message: "Could not read the local store: \(error.localizedDescription)",
                hint: "This usually means the CLI and the installed app were built from "
                    + "different schemas. Rebuild or reinstall the app.")
        }
    }

    /// Mirrors `AppFeedbackApp.init`'s container: the SAME two named configurations over the
    /// SAME combined schema. Core Data records a store's compatibility against the whole model
    /// it was created with — open it with a narrower or differently-named configuration and it
    /// decides a migration is due, which fails on a read-only store.
    private static func container(paths: Paths) throws -> ModelContainer {
        let cloudConfig = ModelConfiguration("cloud", schema: cloudSchema, url: paths.cloud,
                                             allowsSave: false, cloudKitDatabase: .none)
        let localConfig = ModelConfiguration("local", schema: localSchema, url: paths.local,
                                             allowsSave: false, cloudKitDatabase: .none)
        return try ModelContainer(for: Schema(cloudTypes + localTypes),
                                  configurations: cloudConfig, localConfig)
    }

    /// Consistent point-in-time copy via SQLite's `VACUUM INTO`. Copying `.store`/`-wal`/`-shm`
    /// by hand is not atomic against a live writer; this is.
    static func snapshot(of source: URL, into directory: URL) throws -> URL {
        let destination = directory.appending(path: "snapshot-\(UUID().uuidString).store")
        var handle: OpaquePointer?
        guard sqlite3_open_v2(source.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            throw CLIError.noLocalData(
                message: "Could not open \(source.lastPathComponent) for snapshot.", hint: nil)
        }
        defer { sqlite3_close(handle) }
        let escaped = destination.path.replacingOccurrences(of: "'", with: "''")
        guard sqlite3_exec(handle, "VACUUM INTO '\(escaped)'", nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle))
            throw CLIError.noLocalData(message: "Snapshot failed: \(message)", hint: nil)
        }
        return destination
    }
}
#endif

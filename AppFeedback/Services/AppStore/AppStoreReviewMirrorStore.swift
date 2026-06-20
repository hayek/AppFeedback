import Foundation
import SwiftData
import Observation

/// @Observable store over `AppStoreReviewMirror`. Bumps `version` on every local write AND on
/// CloudKit remote-change / import so cross-device dedup state surfaces without a relaunch
/// (mirrors `MailThreadStore`'s pattern). All reads/writes are synchronous on the MainActor.
///
/// `AppStoreReviewMirror` has NO unique constraint (CloudKit forbids them on synced models), so two
/// devices can independently create a row for the same `reviewId`. `mirror(reviewId:)` returns the
/// first match; the coordinator's reconcile collapses dupes, deleting the extra row by its specific
/// `(productID, issueNumber)` via `deleteByIssue` so the kept row is never touched.
@MainActor
@Observable
final class AppStoreReviewMirrorStore {
    private let context: ModelContext
    private(set) var version: Int = 0

    private var remoteChangeTask: Task<Void, Never>?
    private var cloudKitImportTask: Task<Void, Never>?

    init(context: ModelContext) {
        self.context = context
        remoteChangeTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .NSPersistentStoreRemoteChange) {
                self?.version &+= 1
            }
        }
        cloudKitImportTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.cloudKitImportSucceeded {
                self?.version &+= 1
            }
        }
    }

    isolated deinit {
        remoteChangeTask?.cancel()
        cloudKitImportTask?.cancel()
    }

    // MARK: - Reads

    /// reviewId is globally unique in ASC, so no product scoping is needed. Returns the
    /// lowest-issueNumber row when cross-device dupes exist (deterministic "kept" row).
    func mirror(reviewId: String) -> AppStoreReviewMirror? {
        let d = FetchDescriptor<AppStoreReviewMirror>(
            predicate: #Predicate { $0.reviewId == reviewId },
            sortBy: [SortDescriptor(\.issueNumber, order: .forward)])
        return (try? context.fetch(d))?.first
    }

    func mirror(productID: UUID, issueNumber: Int) -> AppStoreReviewMirror? {
        var d = FetchDescriptor<AppStoreReviewMirror>(
            predicate: #Predicate { $0.productID == productID && $0.issueNumber == issueNumber })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    func allFor(productID: UUID) -> [AppStoreReviewMirror] {
        let d = FetchDescriptor<AppStoreReviewMirror>(predicate: #Predicate { $0.productID == productID })
        return (try? context.fetch(d)) ?? []
    }

    /// All mirror rows for a product that point at a given issue number (used by reconcile).
    func allFor(productID: UUID, issueNumber: Int) -> [AppStoreReviewMirror] {
        let d = FetchDescriptor<AppStoreReviewMirror>(
            predicate: #Predicate { $0.productID == productID && $0.issueNumber == issueNumber })
        return (try? context.fetch(d)) ?? []
    }

    // MARK: - Writes

    @discardableResult
    func upsert(reviewId: String, productID: UUID, issueNumber: Int, contentHash: String) -> AppStoreReviewMirror {
        if let existing = mirror(reviewId: reviewId) {
            existing.issueNumber = issueNumber
            existing.contentHash = contentHash
            save()
            return existing
        }
        let row = AppStoreReviewMirror(reviewId: reviewId, productID: productID,
                                       issueNumber: issueNumber, contentHash: contentHash)
        context.insert(row)
        save()
        return row
    }

    /// CANONICAL response setter — keyed on the globally-unique reviewId, no productID. Phase 4
    /// calls this exact shape after a successful `createOrUpdateResponse`.
    func setResponse(reviewId: String, responseId: String?, state: String?) {
        guard let row = mirror(reviewId: reviewId) else { return }
        row.responseId = responseId
        row.responseState = state
        save()
    }

    func clearResponse(reviewId: String) {
        guard let row = mirror(reviewId: reviewId) else { return }
        row.responseId = nil
        row.responseState = nil
        save()
    }

    /// Deletes the SPECIFIC row identified by `(productID, issueNumber)`. Reconcile uses this to drop
    /// a duplicate row while leaving the kept (lowest-issueNumber) row intact.
    func deleteByIssue(productID: UUID, issueNumber: Int) {
        for row in allFor(productID: productID, issueNumber: issueNumber) {
            context.delete(row)
        }
        save()
    }

    // MARK: - Test seam

    /// Inserts a raw row WITHOUT upsert collapse, so tests can simulate cross-device duplicate rows
    /// (two rows, same reviewId) that only appear after CloudKit sync.
    func insertRawForTest(reviewId: String, productID: UUID, issueNumber: Int, contentHash: String) {
        context.insert(AppStoreReviewMirror(reviewId: reviewId, productID: productID,
                                            issueNumber: issueNumber, contentHash: contentHash))
        save()
    }

    private func save() {
        do { try context.save(); version &+= 1 }
        catch { assertionFailure("AppStoreReviewMirrorStore save failed: \(error)") }
    }
}

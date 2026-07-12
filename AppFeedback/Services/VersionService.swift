import Foundation

/// Orchestrates version writes: creates the GitHub milestone (and optional draft release) for a
/// new `ProjectVersion`, edits the changelog, and performs the release (close milestone + publish
/// release). Keeps the local `ProjectVersion` in sync via `VersionStore`. Requires online.
@MainActor
final class VersionService {
    enum ServiceError: LocalizedError {
        case noToken
        case noCommitForRelease
        case duplicateName(String)
        case alreadyPublished
        var errorDescription: String? {
            switch self {
            case .noToken: return "No GitHub token for this repo. Re-authenticate in Settings."
            case .noCommitForRelease: return "The target repo has no commit to tag. The version was released as a milestone only."
            case .duplicateName(let name): return "GitHub already has a milestone named “\(name)”."
            case .alreadyPublished: return "This version is already released, so it can't be renamed — its git tag and release emails are public."
            }
        }
    }

    private let client: GitHubMilestoneReleaseClient
    private let store: VersionStore

    init(store: VersionStore, client: GitHubMilestoneReleaseClient = GitHubMilestoneReleaseClient()) {
        self.store = store
        self.client = client
    }

    /// Creates a milestone for `version` and stores its number. Call right after `store.create`.
    func provisionMilestone(repo: ProductConfig, version: ProjectVersion) async throws {
        guard let token = KeychainService.loadSync(for: repo) else { throw ServiceError.noToken }
        let ms = try await client.createMilestone(owner: repo.owner, repo: repo.repo,
            title: version.name, description: version.changelog, token: token)
        version.milestoneNumber = ms.number
        store.saveAndReload()
    }

    /// Updates the release title and changelog. The milestone description mirrors the changelog;
    /// the release title is local until the version is published (it becomes the GitHub Release name).
    func updateDetails(repo: ProductConfig, version: ProjectVersion, title: String, changelog: String) async throws {
        guard let token = KeychainService.loadSync(for: repo) else { throw ServiceError.noToken }
        version.releaseTitle = title
        version.changelog = changelog
        store.saveAndReload()
        if let number = version.milestoneNumber {
            _ = try await client.updateMilestone(owner: repo.owner, repo: repo.repo, number: number,
                description: changelog, token: token)
        }
    }

    /// Renames a version: validates, PATCHes the GitHub milestone title, then commits locally and
    /// cascades the local copies of the old name.
    ///
    /// GitHub goes **first**, inverting `updateDetails`'s local-then-remote order. That matters here:
    /// `TaskItem.milestoneTitle` is sourced *from* GitHub, so a local-first rename that then failed
    /// remotely would be silently reverted by the next sync — and every task would detach from the
    /// version in the meantime. Committing locally only after GitHub accepts keeps the two in step.
    ///
    /// Blocked once the version is published: the git tag and the release emails are already public,
    /// and a published Release's name cannot be PATCHed by this client anyway. That block *throws*
    /// rather than returning: a caller that got a silent `return` would report "renamed!" with
    /// nothing renamed. Unreachable from the UI — `VersionDetailView` makes the name field
    /// read-only once published, and every caller commits its pending rename *before* releasing.
    func rename(repo: ProductConfig, version: ProjectVersion, to proposed: String,
                cascade: VersionRenameCascade) async throws {
        guard !version.releasePublished else { throw ServiceError.alreadyPublished }

        let existing = store.versions(owner: version.repoOwner, repo: version.repoName)
        let newName = try VersionNameValidator.validate(proposed, existing: existing, renaming: version)

        let oldName = version.name
        guard newName != oldName else { return }

        // A version whose milestone was never provisioned (offline create, or a failed provision)
        // has nothing to PATCH — the rename is a pure local edit.
        if let number = version.milestoneNumber {
            guard let token = KeychainService.loadSync(for: repo) else { throw ServiceError.noToken }
            do {
                _ = try await client.updateMilestone(owner: repo.owner, repo: repo.repo, number: number,
                                                     title: newName, token: token)
            } catch GitHubMilestoneReleaseClient.ClientError.apiError(422, _) {
                throw ServiceError.duplicateName(newName)
            } catch GitHubMilestoneReleaseClient.ClientError.apiError(404, let message) {
                // A 404 here is ambiguous: GitHub returns it both when the milestone was deleted
                // (nothing left to PATCH — safe to fall through to a local-only rename) AND when
                // the token can no longer see the repo at all (lapsed PAT scope, revoked access —
                // the milestone is still there, under its old title). Treating every 404 as
                // "deleted" would commit `store.rename` + `cascade.apply` in the second case too,
                // and that's exactly the hazard the GitHub-first ordering above exists to avoid:
                // once access is restored, the next reconcile rewrites `CachedIssue.milestoneTitle`
                // back to the old name and every task silently detaches from the renamed version.
                //
                // Disambiguate by re-querying the milestone list: a repo-invisible token 404s that
                // call too, so its failure means "can't confirm deletion" — rethrow the original
                // error rather than guess. Only a successful list that plainly omits this milestone
                // number confirms a genuine deletion.
                let originalError = GitHubMilestoneReleaseClient.ClientError.apiError(404, message: message)
                guard let milestones = try? await client.listMilestones(owner: repo.owner, repo: repo.repo, token: token),
                      !milestones.contains(where: { $0.number == number }) else {
                    throw originalError
                }
                // Confirmed gone from GitHub's own list — fall through to the local-only rename
                // below. The stale number is deliberately *not* cleared here either way: GitHub
                // also 404s an invisible repo, so clearing on an auth blip would be unrecoverable.
            }
        }

        store.rename(version, to: newName)
        cascade.apply(owner: version.repoOwner, repo: version.repoName, from: oldName, to: newName)
    }

    /// Deletes the version: removes the GitHub milestone (if any) and the local record.
    func deleteVersion(repo: ProductConfig, version: ProjectVersion) async throws {
        guard let token = KeychainService.loadSync(for: repo) else { throw ServiceError.noToken }
        if let number = version.milestoneNumber {
            try await client.deleteMilestone(owner: repo.owner, repo: repo.repo, number: number, token: token)
        }
        store.delete(version)
    }

    /// Closes the milestone and (best-effort) publishes a GitHub Release. Marks the local version
    /// released even if the Release step fails for lack of a commit (milestone-only release).
    /// Returns whether a Release object was created.
    @discardableResult
    func release(repo: ProductConfig, version: ProjectVersion, tag: String, target: String?, publishRelease: Bool, now: Date) async throws -> Bool {
        guard let token = KeychainService.loadSync(for: repo) else { throw ServiceError.noToken }
        if let number = version.milestoneNumber {
            _ = try await client.updateMilestone(owner: repo.owner, repo: repo.repo, number: number, state: "closed", token: token)
        }
        var createdRelease = false
        if publishRelease {
            let owner = version.connectedRepoOwner ?? repo.connectedRepoOwner ?? repo.owner
            let name = version.connectedRepoName ?? repo.connectedRepoName ?? repo.repo
            let releaseName = version.releaseTitle.isEmpty ? version.name : version.releaseTitle
            do {
                _ = try await client.createRelease(owner: owner, repo: name, tag: tag, name: releaseName,
                    body: version.changelog, draft: false, target: target, token: token)
                version.releaseTag = tag
                createdRelease = true
            } catch GitHubMilestoneReleaseClient.ClientError.apiError(422, _) {
                // No commit to tag → milestone-only release. Surfaced to the UI by the caller.
            }
        }
        version.releasePublished = true
        version.releasedAt = now
        store.saveAndReload()
        return createdRelease
    }
}

import Foundation

/// Orchestrates version writes: creates the GitHub milestone (and optional draft release) for a
/// new `ProjectVersion`, edits the changelog, and performs the release (close milestone + publish
/// release). Keeps the local `ProjectVersion` in sync via `VersionStore`. Requires online.
@MainActor
final class VersionService {
    enum ServiceError: LocalizedError {
        case noToken
        case noCommitForRelease
        var errorDescription: String? {
            switch self {
            case .noToken: return "No GitHub token for this repo. Re-authenticate in Settings."
            case .noCommitForRelease: return "The target repo has no commit to tag. The version was released as a milestone only."
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
    func provisionMilestone(repo: RepoConfig, version: ProjectVersion) async throws {
        guard let token = KeychainService.loadSync(for: repo) else { throw ServiceError.noToken }
        let ms = try await client.createMilestone(owner: repo.owner, repo: repo.repo,
            title: version.name, description: version.changelog, token: token)
        version.milestoneNumber = ms.number
        store.saveAndReload()
    }

    /// Updates the release title and changelog. The milestone description mirrors the changelog;
    /// the release title is local until the version is published (it becomes the GitHub Release name).
    func updateDetails(repo: RepoConfig, version: ProjectVersion, title: String, changelog: String) async throws {
        guard let token = KeychainService.loadSync(for: repo) else { throw ServiceError.noToken }
        version.releaseTitle = title
        version.changelog = changelog
        store.saveAndReload()
        if let number = version.milestoneNumber {
            _ = try await client.updateMilestone(owner: repo.owner, repo: repo.repo, number: number,
                description: changelog, token: token)
        }
    }

    /// Deletes the version: removes the GitHub milestone (if any) and the local record.
    func deleteVersion(repo: RepoConfig, version: ProjectVersion) async throws {
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
    func release(repo: RepoConfig, version: ProjectVersion, tag: String, target: String?, publishRelease: Bool, now: Date) async throws -> Bool {
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

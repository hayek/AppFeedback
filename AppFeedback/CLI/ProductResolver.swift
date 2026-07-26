#if os(macOS)
import Foundation
import SwiftData

enum ProductResolver {

    static func products(cloud: ModelContext) -> [Product] {
        (try? cloud.fetch(FetchDescriptor<Product>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    /// UUID → display name (case-insensitive) → owner/repo. Ambiguity is an error, never a guess.
    static func resolve(_ query: String, cloud: ModelContext) throws -> ProductConfig {
        let all = products(cloud: cloud)
        guard !all.isEmpty else {
            throw CLIError.notFound(code: "no_products",
                                    message: "No products are configured.",
                                    hint: "Add one in AppFeedback's Settings.")
        }
        func describe(_ product: Product) -> String {
            "\(product.displayName) (\(product.owner)/\(product.repo)) \(product.id.uuidString)"
        }

        if let uuid = UUID(uuidString: query), let match = all.first(where: { $0.id == uuid }) {
            return config(from: match)
        }
        let byName = all.filter { $0.displayName.compare(query, options: .caseInsensitive) == .orderedSame }
        if byName.count == 1 { return config(from: byName[0]) }
        if byName.count > 1 {
            throw CLIError.notFound(code: "product_ambiguous",
                                    message: "'\(query)' matches \(byName.count) products by name.",
                                    hint: "Use the product id instead.",
                                    candidates: byName.map(describe))
        }
        let byRepo = all.filter { "\($0.owner)/\($0.repo)".compare(query, options: .caseInsensitive) == .orderedSame }
        if byRepo.count == 1 { return config(from: byRepo[0]) }
        if byRepo.count > 1 {
            throw CLIError.notFound(
                code: "product_ambiguous",
                message: "\(byRepo.count) products share the repo '\(query)'. They see identical feedback.",
                hint: "Use the product id, or pick either and scope with --app.",
                candidates: byRepo.map(describe))
        }
        throw CLIError.notFound(code: "product_not_found",
                                message: "No product matches '\(query)'.",
                                hint: "Run `\(CLIBranding.commandName) products` to list them.",
                                candidates: all.map(describe))
    }

    static func all(cloud: ModelContext, local: ModelContext) -> [ProductSummary] {
        products(cloud: cloud).map { product in
            let owner = product.owner, repo = product.repo
            let cached = (try? local.fetch(FetchDescriptor<CachedIssue>(predicate: #Predicate {
                $0.repoOwner == owner && $0.repoName == repo
            }))) ?? []
            let open = cached.filter { $0.state == IssueState.open.rawValue }
            let split = partition(open)

            let hidden = hiddenApps(owner: owner, repo: repo, cloud: cloud)
            let counts = Dictionary(grouping: split.feedback.compactMap(\.appName).filter { !$0.isEmpty },
                                    by: { $0 }).mapValues(\.count)
            let apps = counts.keys.sorted().map {
                AppSummary(name: $0, count: counts[$0] ?? 0, hidden: hidden.contains($0))
            }

            let versions = ((try? cloud.fetch(FetchDescriptor<ProjectVersion>(predicate: #Predicate {
                $0.repoOwner == owner && $0.repoName == repo
            }))) ?? [])
                .sorted { $0.createdAt > $1.createdAt }
                .map { VersionSummary(name: $0.name, milestoneNumber: $0.milestoneNumber,
                                      released: $0.releasePublished) }

            return ProductSummary(
                id: product.id.uuidString,
                displayName: product.displayName,
                repo: "\(owner)/\(repo)",
                connectedRepo: product.connectedRepoOwner.flatMap { connectedOwner in
                    product.connectedRepoName.map { "\(connectedOwner)/\($0)" }
                },
                apps: apps,
                versions: versions,
                sources: SourceFlags(sdk: true,
                                     appStore: product.appStoreAppAppleID != nil,
                                     email: product.feedbackInboxAccountID != nil),
                feedbackCount: split.feedback.count,
                taskCount: split.tasks.count,
                lastFetchedAt: lastFetchedAt(local: local, owner: owner, repo: repo))
        }
    }

    /// Splits cached rows into (tasks, feedback) by the `appfeedback:task` label.
    static func partition(_ rows: [CachedIssue]) -> (tasks: [CachedIssue], feedback: [CachedIssue]) {
        var tasks: [CachedIssue] = [], feedback: [CachedIssue] = []
        for row in rows {
            if labelNames(of: row).contains(AppFeedbackLabels.task) { tasks.append(row) } else { feedback.append(row) }
        }
        return (tasks, feedback)
    }

    static func labelNames(of row: CachedIssue) -> [String] {
        row.toFeedbackIssue().labels.map(\.name)
    }

    static func hiddenApps(owner: String, repo: String, cloud: ModelContext) -> Set<String> {
        let rows = (try? cloud.fetch(FetchDescriptor<HiddenApp>(predicate: #Predicate {
            $0.repoOwner == owner && $0.repoName == repo
        }))) ?? []
        return Set(rows.map(\.appName))
    }

    static func lastFetchedAt(local: ModelContext, owner: String, repo: String) -> Date? {
        var descriptor = FetchDescriptor<RepoFetchState>(predicate: #Predicate {
            $0.repoOwner == owner && $0.repoName == repo
        })
        descriptor.fetchLimit = 1
        return (try? local.fetch(descriptor))?.first?.lastFetchedAt
    }

    static func config(from product: Product) -> ProductConfig {
        ProductConfig(
            id: product.id, displayName: product.displayName, owner: product.owner, repo: product.repo,
            mirrorEmailsToGitHub: product.mirrorEmailsToGitHub,
            redactEmailAddresses: product.redactEmailAddresses,
            connectedRepoOwner: product.connectedRepoOwner, connectedRepoName: product.connectedRepoName,
            colorHex: product.colorHex, appStoreIssuerID: product.appStoreIssuerID,
            appStoreKeyID: product.appStoreKeyID, appStoreAppAppleID: product.appStoreAppAppleID,
            feedbackInboxAccountID: product.feedbackInboxAccountID)
    }

    static func ref(_ config: ProductConfig) -> ProductRef {
        ProductRef(id: config.id.uuidString, displayName: config.displayName,
                   repo: "\(config.owner)/\(config.repo)")
    }
}
#endif

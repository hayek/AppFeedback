import SwiftUI

/// Lists repositories grouped into one collapsible section per connected GitHub account.
/// Each section loads its repos lazily on first expansion using that account's token.
@MainActor
struct AccountRepoPicker: View {
    let accounts: [GitHubAccount]
    let accountStore: GitHubAccountStore
    /// "owner/name" (lowercased) of repos already added to the app — shown dimmed as "Added".
    let existingRepoKeys: Set<String>
    /// "owner/name" (lowercased) of the currently selected repo — gets a checkmark.
    let selectedKey: String?
    let onSelect: (GitHubAccount, GitHubRepo) -> Void
    let onConnectAnother: () -> Void

    @State private var searchText = ""
    @State private var states: [UUID: AccountRepoState] = [:]
    @State private var expanded: Set<UUID> = []

    enum AccountRepoState {
        case loading
        case loaded([GitHubRepo])
        case failed(String)
        case expired
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            ForEach(accounts, id: \.id) { account in
                accountSection(account)
                Divider().padding(.leading, 12)
            }
            connectAnotherRow
        }
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .onAppear {
            if expanded.isEmpty, let first = accounts.first {
                expanded.insert(first.id)
                loadRepos(for: first)
            }
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
            TextField("Search repositories…", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(8)
    }

    // MARK: - Account section

    @ViewBuilder
    private func accountSection(_ account: GitHubAccount) -> some View {
        VStack(spacing: 0) {
            sectionHeader(account)
            if expanded.contains(account.id) {
                sectionBody(account)
            }
        }
    }

    private func sectionHeader(_ account: GitHubAccount) -> some View {
        HStack(spacing: 8) {
            Button {
                toggle(account)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded.contains(account.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    avatar(account)
                    Text("@\(account.login)")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                if case .expired? = states[account.id] {
                    Button("Reconnect") { onConnectAnother() }
                }
                Button("Disconnect", role: .destructive) {
                    Task {
                        await accountStore.deleteWithCredentials(account)
                        states[account.id] = nil
                        expanded.remove(account.id)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func sectionBody(_ account: GitHubAccount) -> some View {
        switch states[account.id] ?? .loading {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text("Loading repositories…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.bottom, 10)
        case .loaded(let repos):
            repoList(account, repos)
        case .failed(let message):
            sectionMessage(message, actionTitle: "Retry") { loadRepos(for: account) }
        case .expired:
            sectionMessage("Session expired — reconnect to continue.", actionTitle: "Reconnect", action: onConnectAnother)
        }
    }

    private func sectionMessage(_ message: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button(actionTitle, action: action)
                .buttonStyle(.borderless)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func repoList(_ account: GitHubAccount, _ repos: [GitHubRepo]) -> some View {
        let filtered = repos.filter {
            searchText.isEmpty || $0.fullName.localizedCaseInsensitiveContains(searchText)
        }
        if filtered.isEmpty {
            Text(repos.isEmpty ? "No repositories for this account." : "No results.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(filtered) { (repo: GitHubRepo) in
                    repoRow(account, repo)
                }
            }
        }
    }

    private func repoRow(_ account: GitHubAccount, _ repo: GitHubRepo) -> some View {
        let key = "\(repo.owner.login)/\(repo.name)".lowercased()
        let alreadyAdded = existingRepoKeys.contains(key)
        return Button {
            onSelect(account, repo)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(repo.fullName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(alreadyAdded ? .secondary : .primary)
                    if repo.isPrivate {
                        Label("Private", systemImage: "lock")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if alreadyAdded {
                    Text("Added")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else if selectedKey == key {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.leading, 32)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(alreadyAdded)
    }

    // MARK: - Connect another

    private var connectAnotherRow: some View {
        Button(action: onConnectAnother) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                Text("Connect another account")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Avatar

    @ViewBuilder
    private func avatar(_ account: GitHubAccount) -> some View {
        if let urlStr = account.avatarURL, let url = URL(string: urlStr) {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.secondary.opacity(0.2)
            }
            .frame(width: 18, height: 18)
            .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
        }
    }

    // MARK: - Actions

    private func toggle(_ account: GitHubAccount) {
        if expanded.contains(account.id) {
            expanded.remove(account.id)
        } else {
            expanded.insert(account.id)
            if states[account.id] == nil { loadRepos(for: account) }
        }
    }

    private func loadRepos(for account: GitHubAccount) {
        states[account.id] = .loading
        Task {
            guard let token = accountStore.token(for: account) else {
                states[account.id] = .expired
                return
            }
            do {
                let repos = try await GitHubAuthService().listRepos(token: token)
                states[account.id] = .loaded(repos)
            } catch GitHubAuthService.AuthError.apiError(let code) where code == 401 || code == 403 {
                states[account.id] = .expired
            } catch {
                states[account.id] = .failed(error.localizedDescription)
            }
        }
    }
}

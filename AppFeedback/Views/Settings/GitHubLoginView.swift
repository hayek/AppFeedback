import SwiftUI

@MainActor
struct GitHubLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Bindable var store: RepoStore
    var onCompleted: (() -> Void)? = nil

    @State private var authState: AuthState = .requestingCode
    @State private var oauthToken = ""
    @State private var searchText = ""
    @State private var selectedRepo: GitHubRepo?
    @State private var displayName = ""
    @State private var pollTask: Task<Void, Never>?
    @State private var isSaving = false
    @State private var didCopyCode = false

    private let service = GitHubAuthService()

    enum AuthState {
        case requestingCode
        case waitingForUser(DeviceCodeResponse)
        case fetchingRepos
        case pickingRepo([GitHubRepo])
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 380)
        #endif
        .task { startDeviceFlow() }
        .onDisappear { pollTask?.cancel() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sign in with GitHub")
                    .font(.system(size: 13, weight: .semibold))
                Text("Authorize AppFeedback to access your repositories")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { pollTask?.cancel(); dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch authState {
        case .requestingCode:
            centeredProgress("Connecting to GitHub…")
        case .waitingForUser(let response):
            waitingView(response)
        case .fetchingRepos:
            centeredProgress("Loading your repositories…")
        case .pickingRepo(let repos):
            repoPickerView(repos)
        case .failed(let message):
            failedView(message)
        }
    }

    private func waitingView(_ response: DeviceCodeResponse) -> some View {
        VStack(spacing: 20) {
            Text("Enter this code at GitHub")
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 10) {
                Text(response.userCode)
                    .font(.system(size: 30, weight: .bold).monospaced())
                    .textSelection(.enabled)
                Button {
                    copyCode(response.userCode)
                } label: {
                    Image(systemName: didCopyCode ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help(didCopyCode ? "Copied" : "Copy code")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            Button("Open GitHub") {
                if let url = URL(string: response.verificationUri) { openURL(url) }
            }
            .buttonStyle(.borderedProminent)
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("Waiting for authorization…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func repoPickerView(_ repos: [GitHubRepo]) -> some View {
        RepoPickerContent(
            repos: repos,
            searchText: $searchText,
            selectedRepo: $selectedRepo,
            displayName: $displayName,
            onSave: { Task { await saveSelectedRepo() } }
        )
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button("Try Again") { startDeviceFlow() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func centeredProgress(_ label: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func copyCode(_ code: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        #else
        UIPasteboard.general.string = code
        #endif
        didCopyCode = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            didCopyCode = false
        }
    }

    private func startDeviceFlow() {
        authState = .requestingCode
        pollTask?.cancel()
        pollTask = Task {
            do {
                let codeResponse = try await service.requestDeviceCode()
                authState = .waitingForUser(codeResponse)
                let token = try await service.pollForToken(
                    deviceCode: codeResponse.deviceCode,
                    interval: codeResponse.interval
                )
                oauthToken = token
                authState = .fetchingRepos
                let repos = try await service.listRepos(token: token)
                authState = .pickingRepo(repos)
            } catch is CancellationError {
                // user dismissed — do nothing
            } catch {
                authState = .failed(error.localizedDescription)
            }
        }
    }

    private func saveSelectedRepo() async {
        guard !isSaving, let selected = selectedRepo, !oauthToken.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }

        let trimName = displayName.trimmingCharacters(in: .whitespaces)
        let config = RepoConfig(
            displayName: trimName.isEmpty ? selected.name : trimName,
            owner: selected.owner.login,
            repo: selected.name
        )
        // Save token first so SettingsView's tokens dictionary doesn't briefly show "no token".
        await KeychainService.save(token: oauthToken, for: config)
        store.add(config)
        onCompleted?()
        dismiss()
    }
}

// MARK: - Repo Picker Sub-view

@MainActor
private struct RepoPickerContent: View {
    let repos: [GitHubRepo]
    @Binding var searchText: String
    @Binding var selectedRepo: GitHubRepo?
    @Binding var displayName: String
    let onSave: () -> Void

    var filtered: [GitHubRepo] {
        repos.filter {
            searchText.isEmpty || $0.fullName.localizedCaseInsensitiveContains(searchText)
        }
    }

    @ViewBuilder
    var repoList: some View {
        if filtered.isEmpty {
            Text(repos.isEmpty
                 ? "No repositories found.\nCheck that your OAuth app has repo scope."
                 : "No results.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { (repo: GitHubRepo) in
                        Button {
                            selectedRepo = repo
                            displayName = repo.name
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(repo.fullName)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.primary)
                                    if repo.isPrivate {
                                        Label("Private", systemImage: "lock")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if selectedRepo?.id == repo.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Search repositories…", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            repoList

            if selectedRepo != nil {
                Divider()
                HStack(spacing: 10) {
                    TextField("Display name", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") { onSave() }
                        .disabled(displayName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .buttonStyle(.borderedProminent)
                }
                .padding(12)
            }
        }
    }
}

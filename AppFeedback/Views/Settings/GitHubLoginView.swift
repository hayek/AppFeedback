import SwiftUI

@MainActor
struct GitHubLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    var accountStore: GitHubAccountStore
    @State private var authState: AuthState = .requestingCode
    @State private var pollTask: Task<Void, Never>?
    @State private var didCopyCode = false

    private let service = GitHubAuthService()

    enum AuthState {
        case requestingCode
        case waitingForUser(DeviceCodeResponse)
        case finalizing
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
                Text("Authorize Feedbeek to access your repositories")
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
        case .finalizing:
            centeredProgress("Finishing sign-in…")
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
                authState = .finalizing
                let user = try await service.fetchCurrentUser(token: token)
                _ = await accountStore.add(login: user.login, avatarURL: user.avatarURL, token: token)
                dismiss()
            } catch is CancellationError {
                // user dismissed — do nothing
            } catch {
                authState = .failed(error.localizedDescription)
            }
        }
    }
}

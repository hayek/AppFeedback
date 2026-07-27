#if os(macOS)
import SwiftUI

struct CLISettingsView: View {
    @State private var cliStatus = CLIInstaller.cliStatus()
    @State private var skillStatus = CLIInstaller.skillStatus()
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Command Line") {
                statusRow(cliStatus, missing: "Not installed")
                Button("Install Command Line Tool") { installCLI() }
                if case .installed(let url) = cliStatus,
                   !isOnPath(url.deletingLastPathComponent()) {
                    Label("\(url.deletingLastPathComponent().path) isn't on your PATH — "
                          + "call it by full path, or add it.",
                          systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("Symlinks this app's binary so `\(CLIBranding.commandName)` works in any "
                     + "terminal. The link points at the app, so moving the app re-links on "
                     + "next launch.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("AI Skill") {
                statusRow(skillStatus, missing: "Not installed")
                HStack {
                    Button("Install for Claude Code") { installSkill() }
                    Button("Show in Finder") { CLIInstaller.revealSkillInFinder() }
                }
                Text("Installs into ~/.claude/skills so any project can read your feedback. "
                     + "For another AI tool, reveal the folder and copy it wherever that tool "
                     + "expects its skills.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("CLI & AI Skill")
        .onAppear(perform: refresh)
    }

    @ViewBuilder
    private func statusRow(_ status: CLIInstaller.InstallStatus, missing: String) -> some View {
        switch status {
        case .installed(let url):
            Label("Installed at \(url.path)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .brokenLink(let url):
            Label("Broken link at \(url.path) — reinstall", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .occupied(let url):
            // Left alone until the user presses Install, so nothing they wrote disappears on a
            // plain app launch.
            Label("\(url.path) already exists and wasn't installed by this app. Installing moves "
                  + "it aside to \(url.lastPathComponent).backup-<date> first.",
                  systemImage: "hand.raised.fill")
                .foregroundStyle(.orange)
        case .notInstalled:
            Label(missing, systemImage: "circle.dashed").foregroundStyle(.secondary)
        }
    }

    private func isOnPath(_ directory: URL) -> Bool {
        (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").contains { $0 == directory.path }
    }

    private func refresh() {
        cliStatus = CLIInstaller.cliStatus()
        skillStatus = CLIInstaller.skillStatus()
    }

    private func installCLI() {
        errorMessage = nil
        do {
            _ = try CLIInstaller.installCLI()
        } catch {
            errorMessage = "Could not install the tool: \(error.localizedDescription). "
                         + "Create ~/.local/bin and try again."
        }
        refresh()
    }

    private func installSkill() {
        errorMessage = nil
        do {
            _ = try CLIInstaller.installSkill()
        } catch {
            errorMessage = "Could not install the skill: \(error.localizedDescription)"
        }
        refresh()
    }
}
#endif

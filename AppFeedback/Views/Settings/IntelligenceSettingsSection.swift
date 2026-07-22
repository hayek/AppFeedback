import SwiftUI

struct IntelligenceSettingsSection: View {
    @Bindable var settings: IntelligenceSettings
    let availability: IntelligenceAvailability
    var onOpenSystemSettings: () -> Void = {}
    @Bindable var triageSettings: TriageSettings
    /// DEBUG-only triage re-test hooks; buttons render only when non-nil.
    var onClearPendingTriage: (() -> Void)? = nil
    var onClearAllTriage: (() -> Void)? = nil

    var body: some View {
        Form {
            // Apple Intelligence status gates ONLY summaries now — translation runs through
            // the Translation framework with no AI dependency — so the status row lives
            // inside Summaries rather than reading as a global "intelligence is broken" banner.
            Section("Summaries") {
                HStack(spacing: 8) {
                    Image(systemName: availability.systemImageName)
                        .foregroundStyle(availability.isReady ? .green : .orange)
                    Text(availability.statusText)
                        .font(.system(size: 13))
                    Spacer()
                    if availability == .appleIntelligenceNotEnabled {
                        Button("Open System Settings") { onOpenSystemSettings() }
                    }
                }
                Toggle(isOn: $settings.summariesEnabled) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Summarize unread feedback")
                        Text("Show an AI-generated rollup of the last 30 days of replies.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!availability.isReady)
            }
            Section("Translation") {
                Toggle("Translate non-English issues", isOn: $settings.translationEnabled)
                Picker("Target language", selection: $settings.targetLanguageCode) {
                    ForEach(IntelligenceSettings.pickerOptions, id: \.code) { option in
                        Text(option.displayName).tag(option.code)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!settings.translationEnabled)
                Text("Uses Apple's on-device translation — no Apple Intelligence required. Each language downloads the first time it's needed. Changing the target re-translates issues as you view them.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section("Feedback Triage") {
                Picker("Auto-triage new feedback", selection: $triageSettings.mode) {
                    ForEach(TriageMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!availability.isReady)
                Text("On-device AI decides whether new feedback is task-worthy, then assigns it to an existing task or proposes a new one. Nothing leaves this device until a task is created or assigned.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                #if DEBUG
                if let onClearPendingTriage, let onClearAllTriage {
                    HStack {
                        Button("Clear Pending Suggestions", action: onClearPendingTriage)
                        Button("Clear All Triage Verdicts", role: .destructive, action: onClearAllTriage)
                    }
                    Text("Debug: forgets AI triage verdicts so feedback gets triaged again.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                #endif
            }
        }
        .formStyle(.grouped)
    }
}

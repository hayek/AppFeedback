import SwiftUI

struct IntelligenceSettingsSection: View {
    @Bindable var settings: IntelligenceSettings
    let availability: IntelligenceAvailability
    var onOpenSystemSettings: () -> Void = {}

    var body: some View {
        Form {
            Section("Status") {
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
            }
            Section("Summaries") {
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
                    .disabled(!availability.isReady)
                Picker("Target language", selection: $settings.targetLanguageCode) {
                    ForEach(IntelligenceSettings.pickerOptions, id: \.code) { option in
                        Text(option.displayName).tag(option.code)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!availability.isReady || !settings.translationEnabled)
                Text("Changing the target language re-translates issues as you view them.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

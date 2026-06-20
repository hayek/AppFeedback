import SwiftUI

/// Pure, testable helpers for the App Store response panel (button titles, status text) —
/// separated from the View so the label logic is unit-testable without UI rendering.
enum AppStoreResponsePanelModel {
    static func primaryTitle(for mode: AppStoreResponseController.Mode) -> String {
        switch mode {
        case .noResponse, .disabledReadOnly: return "Submit Response"
        case .hasResponse:                    return "Update Response"
        }
    }

    static func errorText(_ error: AppStoreResponseController.SubmitError?) -> String? {
        switch error {
        case .none: return nil
        case .tooLong(let over): return "Response is \(over) character\(over == 1 ? "" : "s") over the limit."
        case .conflict: return "A response is already being processed. Try again in a moment."
        case .validation(let message): return message
        case .api(let code, let message?): return "App Store error \(code): \(message)"
        case .api(let code, nil): return "App Store error \(code)."
        case .network(let message): return "Couldn't reach App Store Connect: \(message)"
        }
    }

    static func stateLabel(_ state: String?) -> String? {
        switch state {
        case "PENDING_PUBLISH": return "Pending publish"
        case "PUBLISHED": return "Published"
        default: return nil
        }
    }
}

/// The "Respond on App Store" panel rendered inside a feedback card whose source is the
/// App Store. A text editor with a live character counter, a Submit/Update button, and (when
/// a response already exists) a Delete button. A read-only ASC key shows an explanatory note
/// instead of the editor controls.
struct AppStoreResponsePanel: View {
    @State var controller: AppStoreResponseController
    var accent: Color = .accentColor

    init(controller: AppStoreResponseController, accent: Color = .accentColor) {
        self._controller = State(initialValue: controller)
        self.accent = accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "apple.logo").font(.system(size: 11, weight: .semibold))
                Text("Respond on App Store").font(.system(size: 12, weight: .semibold))
                if let state = AppStoreResponsePanelModel.stateLabel(controller.responseState) {
                    Text(state)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(accent.opacity(0.15), in: Capsule())
                        .foregroundStyle(accent)
                }
                Spacer()
            }
            .foregroundStyle(.secondary)

            if controller.mode == .disabledReadOnly {
                Text("This App Store Connect key is read-only. Use an Admin, App Manager, or Customer Support key to post developer responses.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                TextEditor(text: $controller.draft)
                    .font(.system(size: 12))
                    .frame(minHeight: 64, maxHeight: 140)
                    .padding(6)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(controller.overLimit ? Color.red.opacity(0.6) : accent.opacity(0.25), lineWidth: 1))

                HStack {
                    Text("\(controller.remainingChars)")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(controller.overLimit ? Color.red : Color.secondary)
                    Spacer()
                    if controller.canDelete {
                        Button(role: .destructive) {
                            Task { await controller.delete() }
                        } label: { Text("Delete").font(.system(size: 11, weight: .semibold)) }
                        .buttonStyle(.bordered)
                        .disabled(controller.isBusy)
                    }
                    Button {
                        Task { await controller.submit() }
                    } label: {
                        if controller.isBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(AppStoreResponsePanelModel.primaryTitle(for: controller.mode))
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .disabled(!controller.canSubmit)
                }

                if let error = AppStoreResponsePanelModel.errorText(controller.lastError) {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .padding(.top, 8)
    }
}

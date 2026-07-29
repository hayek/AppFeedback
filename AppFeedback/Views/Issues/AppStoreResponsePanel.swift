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
/// App Store. Wears the same chrome as the email composer (`InlineReplyView` +
/// `ComposeFormCore`) — header strip, divider-separated rows, plain body editor, trailing
/// button row — so a reply reads the same whichever source it answers. A text editor with a
/// live character counter, a Submit/Update button, and (when a response already exists) a
/// Delete button. A read-only ASC key shows an explanatory note instead of the editor controls.
struct AppStoreResponsePanel: View {
    @State var controller: AppStoreResponseController

    init(controller: AppStoreResponseController) {
        self._controller = State(initialValue: controller)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerStrip
            Divider()
            if controller.mode == .disabledReadOnly {
                Text("This App Store Connect key is read-only. Use an Admin, App Manager, or Customer Support key to post developer responses.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
            } else {
                TextEditor(text: $controller.draft)
                    .font(.body)
                    .scrollDisabled(true)
                    .frame(minHeight: 120)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                Divider()
                footerButtons
                if let error = AppStoreResponsePanelModel.errorText(controller.lastError) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.bottom, 6)
                }
            }
        }
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.secondary.opacity(0.25), lineWidth: 1)
        )
        .padding(.top, 6)
    }

    // MARK: - Header strip

    private var headerStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "apple.logo")
                .foregroundStyle(.secondary)
            Text("Respond on App Store")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let state = AppStoreResponsePanelModel.stateLabel(controller.responseState) {
                Text(state)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    // MARK: - Buttons

    /// Mirrors `ComposeFormCore.footerButtons`: a leading affordance, then the secondary and
    /// prominent actions. The character counter takes the paperclip's slot.
    private var footerButtons: some View {
        HStack {
            Text("\(controller.remainingChars)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(controller.overLimit ? Color.red : Color.secondary)
            Spacer()
            if controller.canDelete {
                Button("Delete", role: .destructive) {
                    Task { await controller.delete() }
                }
                .disabled(controller.isBusy)
            }
            Button {
                Task { await controller.submit() }
            } label: {
                if controller.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Text(AppStoreResponsePanelModel.primaryTitle(for: controller.mode))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!controller.canSubmit)
        }
        .padding(12)
    }
}

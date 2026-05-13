#if canImport(SwiftMail)
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Shared body of any compose surface (windowed, sheeted, inline). Renders the From / To /
/// Subject rows, header/footer template previews, the body editor, and a Send button.
/// The host owns the view model and is responsible for the surrounding chrome.
struct ComposeFormCore: View {
    @Bindable var vm: ComposeMailViewModel
    let headerPreview: String
    let footerPreview: String
    var sendLabel: String = "Send"
    var onSend: () -> Void
    var onDiscard: (() -> Void)? = nil
    var discardLabel: String = "Cancel"
    var bodyFocus: FocusState<Bool>.Binding? = nil

    @Environment(MailAccountStore.self) private var store
    @Environment(SettingsNavigation.self) private var settingsNavigation
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            fromRow
            Divider()
            recipientRow
            Divider()
            subjectRow
            Divider()
            templateRow(label: "Header", text: headerPreview)
            Divider()
            Group {
                if let bodyFocus {
                    TextEditor(text: Binding(
                        get: { vm.body.string },
                        set: { vm.body = NSAttributedString(string: $0) }
                    ))
                    .focused(bodyFocus)
                } else {
                    TextEditor(text: Binding(
                        get: { vm.body.string },
                        set: { vm.body = NSAttributedString(string: $0) }
                    ))
                }
            }
            .font(.body)
            .scrollDisabled(true)
            .frame(minHeight: 200)
            .padding(.horizontal, 8).padding(.vertical, 4)
            Divider()
            templateRow(label: "Footer", text: footerPreview)
            Divider()
            footerButtons
        }
    }

    private var fromRow: some View {
        HStack {
            Text("From:").foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            if let acc = store.account(id: vm.senderAccountID) {
                Text(acc.smtpUsername).fontWeight(.medium)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var recipientRow: some View {
        HStack {
            Text("To:").foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            Text(vm.recipient).fontWeight(.medium)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var subjectRow: some View {
        HStack {
            Text("Subject:").foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            TextField("", text: $vm.subject)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func templateRow(label: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(label):")
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Group {
                if text.isEmpty {
                    Text("Not set").foregroundStyle(.tertiary).italic()
                } else {
                    Text(text)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            #if os(macOS)
            Button {
                settingsNavigation.selectedTab = .email
                openWindow(id: "settings")
            } label: {
                Label("Edit", systemImage: "pencil").labelStyle(.titleAndIcon)
            }
            .controlSize(.small)
            #endif
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var footerButtons: some View {
        HStack {
            Spacer()
            if let onDiscard {
                Button(discardLabel) { onDiscard() }
            }
            Button(sendLabel) { onSend() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!vm.canSend)
        }
        .padding(12)
    }
}
#endif

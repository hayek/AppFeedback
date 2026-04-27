#if os(macOS)
import SwiftUI
import AppKit

struct EmailSettingsView: View {
    @Environment(MailSettings.self) private var settings
    @Environment(ActivityLog.self) private var activityLog

    @State private var preset: SMTPCredentials.Preset = .gmail
    @State private var host: String = ""
    @State private var port: String = "587"
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var senderName: String = ""

    @State private var saveStatus: String?

    @State private var headerAttributed = NSAttributedString(string: "")
    @State private var footerAttributed = NSAttributedString(string: "")
    @State private var testStatus: String?

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Preset", selection: $preset) {
                    ForEach(SMTPCredentials.Preset.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .onChange(of: preset) { _, new in applyPresetDefaults(new) }
            }

            Section("Credentials") {
                TextField("Host", text: $host)
                    .disabled(preset != .custom)
                TextField("Port", text: $port)
                    .disabled(preset != .custom)
                TextField("Username / from address", text: $username)
                SecureField("App password", text: $password)
                TextField("Sender display name", text: $senderName)
            }

            Section("Header") {
                RichTextToolbar()
                RichTextEditor(attributedText: $headerAttributed, minHeight: 120)
                    .frame(minHeight: 120)
            }

            Section("Footer") {
                RichTextToolbar()
                RichTextEditor(attributedText: $footerAttributed, minHeight: 120)
                    .frame(minHeight: 120)
            }

            Section("Tools") {
                HStack {
                    Button("Test Connection") { testConnection() }
                        .disabled(username.isEmpty || host.isEmpty || password.isEmpty)
                    Button("Preview") { showPreview() }
                    Spacer()
                    if let testStatus { Text(testStatus).foregroundStyle(.secondary) }
                }
            }

            Section {
                HStack {
                    Button("Save") { save() }
                    Spacer()
                    if let saveStatus { Text(saveStatus).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
        .task { await loadFromSettings() }
    }

    private func applyPresetDefaults(_ p: SMTPCredentials.Preset) {
        let d = SMTPCredentials.defaults(for: p)
        host = d.host
        port = String(d.port)
    }

    private func loadFromSettings() async {
        if let creds = settings.credentials {
            preset = creds.preset
            host = creds.host
            port = String(creds.port)
            username = creds.username
            senderName = creds.senderName
        } else {
            applyPresetDefaults(preset)
        }
        if let pw = await KeychainService.loadSMTPPassword() {
            password = pw
        }
        let headerHTML = settings.template.headerHTML
        let footerHTML = settings.template.footerHTML
        if let data = headerHTML.data(using: .utf8),
           let attr = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.html],
               documentAttributes: nil) {
            headerAttributed = attr
        }
        if let data = footerHTML.data(using: .utf8),
           let attr = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.html],
               documentAttributes: nil) {
            footerAttributed = attr
        }
    }

    private func save() {
        let headerHTML = htmlString(from: headerAttributed)
        let footerHTML = htmlString(from: footerAttributed)
        settings.template = MailTemplate(headerHTML: headerHTML, footerHTML: footerHTML)
        let creds = SMTPCredentials(
            preset: preset,
            host: host,
            port: Int(port) ?? 587,
            username: username,
            senderName: senderName
        )
        settings.credentials = creds
        Task {
            let ok = await KeychainService.saveSMTPPassword(password)
            saveStatus = ok ? "Saved" : "Saved settings, but Keychain failed"
        }
    }

    // MARK: - Helpers

    private func htmlString(from attr: NSAttributedString) -> String {
        let opts: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let data = try? attr.data(
                from: NSRange(location: 0, length: attr.length),
                documentAttributes: opts),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    // MARK: - Test Connection

    private func testConnection() {
        let freshCreds = SMTPCredentials(
            preset: preset,
            host: host,
            port: Int(port) ?? 587,
            username: username,
            senderName: senderName
        )
        let id = activityLog.start(kind: .testConnection, title: "\(freshCreds.host):\(freshCreds.port)")
        Task {
            #if canImport(SwiftMail)
            do {
                let sender = MailSender()
                try await sender.testConnection(freshCreds, password: password)
                activityLog.finish(id, status: .success, detail: "Login OK")
                testStatus = "Connection OK"
            } catch {
                activityLog.finish(id, status: .failure, detail: error.localizedDescription)
                testStatus = "Failed: \(error.localizedDescription)"
            }
            #else
            activityLog.finish(id, status: .failure, detail: "SwiftMail not available")
            #endif
        }
    }

    // MARK: - Preview

    private func showPreview() {
        #if canImport(SwiftMail)
        let composer = MailComposer()
        let creds = settings.credentials ?? SMTPCredentials.defaults(for: .gmail)
        let context = PlaceholderContext(
            sender: creds,
            recipient: "preview@example.com",
            appName: "Preview App",
            issueTitle: "Sample issue",
            issueURL: URL(string: "https://github.com/example/repo/issues/1"),
            date: Date()
        )
        let template = MailTemplate(
            headerHTML: htmlString(from: headerAttributed),
            footerHTML: htmlString(from: footerAttributed)
        )
        let draft = DraftMessage(
            recipient: "preview@example.com",
            subject: "Preview",
            body: NSAttributedString(string: "[Body goes here]")
        )
        let email = composer.compose(draft: draft, context: context, template: template)
        if let html = email.htmlBody, let url = writePreviewHTML(html) {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    private func writePreviewHTML(_ html: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppFeedback-Preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("preview-\(UUID().uuidString).html")
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
#endif

import Foundation
#if canImport(SwiftMail)
import SwiftMail

protocol MailSending: Sendable {
    func send(_ email: SwiftMail.Email, using credentials: SMTPCredentials, password: String) async throws
    func testConnection(_ credentials: SMTPCredentials, password: String) async throws
}

actor MailSender: MailSending {

    func send(_ email: SwiftMail.Email, using credentials: SMTPCredentials, password: String) async throws {
        let server = SMTPServer(host: credentials.host, port: credentials.port)
        try await server.connect()
        try await server.login(username: credentials.username, password: password)
        do {
            try await server.sendEmail(email)
        } catch {
            try? await server.disconnect()
            throw error
        }
        try? await server.disconnect()
    }

    func testConnection(_ credentials: SMTPCredentials, password: String) async throws {
        let server = SMTPServer(host: credentials.host, port: credentials.port)
        try await server.connect()
        try await server.login(username: credentials.username, password: password)
        try? await server.disconnect()
    }
}
#endif

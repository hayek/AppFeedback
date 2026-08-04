import Foundation
#if canImport(SwiftMail)
import SwiftMail

protocol MailSending: Sendable {
    func send(_ email: SwiftMail.Email, using credentials: SMTPCredentials, password: String) async throws
    func testConnection(_ credentials: SMTPCredentials, password: String) async throws
}

/// A failure talking to the SMTP server, restated with the server we were talking to and what we
/// were doing. NIO's own errors bridge to "The operation couldn't be completed. (NIOCore.ChannelError
/// error 0.)" — which is what the Failed badge used to show, and it names neither the host nor the
/// problem.
struct SMTPTransportError: LocalizedError {
    enum Stage: String {
        case connect = "connect to"
        case login = "sign in to"
        case send = "send through"
    }

    let host: String
    let port: Int
    let stage: Stage
    let underlying: Error

    var errorDescription: String? {
        "Couldn't \(stage.rawValue) \(host):\(port) — \(underlyingText)"
    }

    /// SwiftMail's own errors carry a written-out message; NIO's don't, and their bridged
    /// `localizedDescription` is the useless one — for those the enum case (`connectTimeout(…)`)
    /// is far more informative.
    private var underlyingText: String {
        if let described = (underlying as? LocalizedError)?.errorDescription { return described }
        return String(describing: underlying)
    }
}

actor MailSender: MailSending {

    func send(_ email: SwiftMail.Email, using credentials: SMTPCredentials, password: String) async throws {
        let server = SMTPServer(host: credentials.host, port: credentials.port)
        defer { Self.park(server) }

        try await connectAndLogin(server, credentials: credentials, password: password)
        do {
            try await server.sendEmail(email)
        } catch {
            try? await server.disconnect()
            throw SMTPTransportError(host: credentials.host, port: credentials.port,
                                     stage: .send, underlying: error)
        }
        try? await server.disconnect()
    }

    func testConnection(_ credentials: SMTPCredentials, password: String) async throws {
        let server = SMTPServer(host: credentials.host, port: credentials.port)
        defer { Self.park(server) }

        try await connectAndLogin(server, credentials: credentials, password: password)
        try? await server.disconnect()
    }

    private func connectAndLogin(
        _ server: SMTPServer,
        credentials: SMTPCredentials,
        password: String
    ) async throws {
        do {
            try await server.connect()
        } catch {
            throw SMTPTransportError(host: credentials.host, port: credentials.port,
                                     stage: .connect, underlying: error)
        }
        do {
            try await server.login(username: credentials.username, password: password)
        } catch {
            try? await server.disconnect()
            throw SMTPTransportError(host: credentials.host, port: credentials.port,
                                     stage: .login, underlying: error)
        }
    }

    /// Holds `server` alive for a while after we're finished with it, then drops it on a GCD thread.
    ///
    /// `SMTPServer.deinit` shuts its `MultiThreadedEventLoopGroup` down with
    /// `syncShutdownGracefully()`, which *traps* if it runs on one of that group's own event-loop
    /// threads — `try?` cannot catch a precondition. After a failed connect, NIO's resolver and
    /// connector teardown (a late DNS answer resolving a promise, say) can be the last owner and
    /// release the server exactly there, crashing the app. Outliving that teardown makes this the
    /// last reference, so the group is always shut down from a thread that isn't its own.
    ///
    /// The delay costs one idle event-loop thread per send until it elapses; sends are rare and
    /// user-initiated, and NIO's connect and resolution timeouts are well inside it.
    private static func park(_ server: SMTPServer) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + parkInterval) {
            withExtendedLifetime(server) {}
        }
    }

    private static let parkInterval: TimeInterval = 30
}
#endif

#if os(macOS)
import Foundation
import SwiftData

/// App-side half of the CLI channel. Observes request pings, runs the handler on the main
/// actor (every app service it calls is @MainActor), and writes the reply back.
///
/// Registration uses the SELECTOR-based API deliberately: it is the only
/// `DistributedNotificationCenter` overload that accepts a suspension behavior, and
/// `.deliverImmediately` is mandatory here — AppKit suspends delivery while the app is
/// inactive, which it always is when an agent drives a terminal, so the block-based API
/// would leave every request unanswered until the app next came forward.
final class CLIRequestResponder: NSObject {

    static let suspensionBehavior: DistributedNotificationCenter.SuspensionBehavior = .deliverImmediately

    typealias Handler = @MainActor (CLIRequest) async throws -> CLIResponse

    private let directory: URL
    private let handler: Handler

    init(directory: URL = CLIIPCTransport.directory, handler: @escaping Handler) {
        self.directory = directory
        self.handler = handler
        super.init()
    }

    func start() {
        CLIIPCTransport.sweep(in: directory)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleNotification(_:)),
            name: Notification.Name(CLIBranding.requestNotification),
            object: nil, suspensionBehavior: Self.suspensionBehavior)
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func handleNotification(_ notification: Notification) {
        guard let raw = notification.userInfo?["id"] as? String,
              let id = UUID(uuidString: raw) else { return }
        Task { @MainActor [weak self] in await self?.handle(requestID: id) }
    }

    /// Reads the request, runs the handler, writes the response, pings back.
    /// A request this app has already consumed reads as missing and is ignored.
    @MainActor
    func handle(requestID: UUID) async {
        guard let request = try? CLIIPCTransport.readRequest(id: requestID, in: directory) else { return }
        var response: CLIResponse
        do {
            response = try await handler(request)
        } catch let error as CLIError {
            response = CLIResponse(id: requestID, ok: false, errorCode: error.code,
                                   errorMessage: error.message, errorHint: error.hint)
        } catch {
            response = CLIResponse(id: requestID, ok: false, errorCode: "remote_failure",
                                   errorMessage: error.localizedDescription)
        }
        try? CLIIPCTransport.write(response: response, in: directory)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(CLIBranding.responseNotification),
            object: nil, userInfo: ["id": requestID.uuidString], deliverImmediately: true)
    }
}

/// Executes each CLI request by calling exactly what the app's own UI calls.
@MainActor
enum CLIRequestHandlers {

    struct Dependencies {
        let registry: IssueLoaderRegistry
    }

    static func handle(_ request: CLIRequest, deps: Dependencies) async throws -> CLIResponse {
        switch request.kind {
        case .refresh:
            if let raw = request.payload["productID"], let id = UUID(uuidString: raw) {
                await deps.registry.load(productID: id)   // scoped to the product being asked about
            } else {
                await deps.registry.loadAll()
            }
            return CLIResponse(id: request.id, ok: true)

        default:
            throw CLIError.remote(message: "\(request.kind.rawValue) is not implemented yet.")
        }
    }
}
#endif

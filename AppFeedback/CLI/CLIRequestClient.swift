#if os(macOS)
import Foundation
import AppKit

enum CLIRequestClient {

    static func isAppRunning(bundleIdentifier: String = CLIBranding.bundleIdentifier) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    /// Writes the request, pings the app, and waits for its reply. Throws `.appNotRunning`
    /// up front and `.remote` on timeout.
    static func send(_ request: CLIRequest, timeout: TimeInterval) async throws -> CLIResponse {
        guard isAppRunning() else { throw CLIError.appNotRunning }

        let directory = CLIIPCTransport.directory
        try CLIIPCTransport.write(request: request, in: directory)

        let center = DistributedNotificationCenter.default()
        let response: CLIResponse? = await withCheckedContinuation { continuation in
            let state = ContinuationState(continuation: continuation, center: center)

            state.observer = center.addObserver(
                forName: Notification.Name(CLIBranding.responseNotification),
                object: nil, queue: .main
            ) { notification in
                guard let raw = notification.userInfo?["id"] as? String,
                      UUID(uuidString: raw) == request.id else { return }   // ignore other CLIs' replies
                state.finish(try? CLIIPCTransport.readResponse(id: request.id, in: directory))
            }

            // deliverImmediately is load-bearing: AppKit suspends delivery to an inactive app,
            // and an app being driven from a terminal is always inactive.
            center.postNotificationName(Notification.Name(CLIBranding.requestNotification),
                                        object: nil, userInfo: ["id": request.id.uuidString],
                                        deliverImmediately: true)

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { state.finish(nil) }
        }

        guard let response else {
            throw CLIError.remote(
                message: "AppFeedback did not answer within \(Int(timeout))s.",
                hint: "The app is running but busy. For a write the outcome is unknown — "
                    + "check the app before retrying.")
        }
        return response
    }

    /// Fire-and-forget nudge: used after a write so the app refreshes without the CLI waiting.
    static func post(_ request: CLIRequest) {
        guard isAppRunning(), (try? CLIIPCTransport.write(request: request,
                                                          in: CLIIPCTransport.directory)) != nil
        else { return }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(CLIBranding.requestNotification), object: nil,
            userInfo: ["id": request.id.uuidString], deliverImmediately: true)
    }

    /// Guards the continuation so the observer and the timeout can race safely — resuming a
    /// checked continuation twice traps.
    private final class ContinuationState {
        private let continuation: CheckedContinuation<CLIResponse?, Never>
        private let center: DistributedNotificationCenter
        private let lock = NSLock()
        private var finished = false
        var observer: NSObjectProtocol?

        init(continuation: CheckedContinuation<CLIResponse?, Never>,
             center: DistributedNotificationCenter) {
            self.continuation = continuation
            self.center = center
        }

        func finish(_ value: CLIResponse?) {
            lock.lock()
            guard !finished else { return lock.unlock() }
            finished = true
            let observer = self.observer
            lock.unlock()
            if let observer { center.removeObserver(observer) }
            continuation.resume(returning: value)
        }
    }
}
#endif

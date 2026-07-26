import SwiftUI

/// Process entry point. On macOS a recognised subcommand runs the CLI and exits before
/// SwiftUI is touched; everything else — including Finder's `-psn_*` and Xcode's launch
/// arguments — falls through to the GUI.
@main
enum AppFeedbackMain {
    static func main() {
        #if os(macOS)
        // XCTest drives this binary with its own argv. Check before matching subcommands so a
        // test argument shaped like one can never divert into the CLI.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
           let invocation = CLIInvocation.parse(CommandLine.arguments) {
            CLIRunner.run(invocation: invocation)
        }
        #endif
        AppFeedbackApp.main()
    }
}

import Foundation

/// Single source of truth for every user-visible CLI name. The product name is
/// temporary — renaming later should touch this file and nothing else.
enum CLIBranding {
    static let commandName = "appfeedback"
    static let skillFolderName = "appfeedback"
    static let ipcPrefix = "com.amirhayek.AppFeedback.cli"
    static let bundleIdentifier = "com.amirhayek.AppFeedback"

    static var requestNotification: String { "\(ipcPrefix).request" }
    static var responseNotification: String { "\(ipcPrefix).response" }

    #if os(macOS)
    /// The app bundle, resolved through any symlink.
    ///
    /// `Bundle.main` is wrong when the binary is exec'd via the installed
    /// `~/.local/bin/appfeedback` symlink: the process path is the symlink, so Bundle.main
    /// points at that directory and finds no Info.plist (version reads as "?").
    ///
    /// `Bundle.main.executablePath` is the path actually exec'd — the symlink — and resolving
    /// it lands on `…/AppFeedback.app/Contents/MacOS/AppFeedback`, three levels below the
    /// bundle. argv[0] is NOT usable here: a PATH lookup passes just the bare command name.
    static var appBundle: Bundle {
        let candidates = [Bundle.main.executablePath, CommandLine.arguments.first]
            .compactMap { $0 }
            .filter { $0.contains("/") }
        for path in candidates {
            let bundleURL = URL(filePath: path)
                .resolvingSymlinksInPath()
                .deletingLastPathComponent()      // MacOS
                .deletingLastPathComponent()      // Contents
                .deletingLastPathComponent()      // .app
            if bundleURL.pathExtension == "app", let bundle = Bundle(url: bundleURL) { return bundle }
        }
        return .main
    }
    #endif
}

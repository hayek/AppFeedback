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
}

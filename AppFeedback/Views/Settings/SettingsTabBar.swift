#if os(macOS)
import SwiftUI
import AppKit

/// Installs a real `NSToolbar` on the host window with `toolbarStyle = .preference`,
/// giving us the System Settings / Xcode Preferences look: SF Symbol stacked above a
/// label, centered in the title bar, with native selected-state highlighting.
///
/// SwiftUI's TabView in a regular Window scene renders `.tabItem` as a text-only top
/// tab bar — there's no SwiftUI API to get the `.preference` toolbar style. Bridging
/// to AppKit is the canonical fix used by macOS apps that ship outside the
/// `Settings { }` scene (e.g. sindresorhus/Settings, SettingsKit).
struct SettingsToolbarAccessor: NSViewRepresentable {
    @Binding var selection: SettingsTab
    let hasNotifications: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let window = v.window else { return }
            context.coordinator.attach(to: window)
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncSelectionToToolbar()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, NSToolbarDelegate {
        var parent: SettingsToolbarAccessor
        private weak var window: NSWindow?
        private weak var toolbar: NSToolbar?

        init(parent: SettingsToolbarAccessor) {
            self.parent = parent
        }

        func attach(to window: NSWindow) {
            guard window.toolbar == nil else {
                // Already installed (e.g., re-entry on view re-creation). Resync only.
                self.window = window
                self.toolbar = window.toolbar
                syncSelectionToToolbar()
                return
            }
            let toolbar = NSToolbar(identifier: "AppFeedback.SettingsToolbar")
            toolbar.delegate = self
            toolbar.displayMode = .iconAndLabel
            toolbar.allowsUserCustomization = false
            toolbar.autosavesConfiguration = false
            toolbar.selectedItemIdentifier = identifier(for: parent.selection)
            window.toolbar = toolbar
            window.toolbarStyle = .preference
            window.titleVisibility = .visible
            window.title = "Settings"
            self.window = window
            self.toolbar = toolbar
        }

        func detach() {
            // Leave the toolbar in place; the window will tear it down on close.
            window = nil
            toolbar = nil
        }

        func syncSelectionToToolbar() {
            guard let toolbar else { return }
            let id = identifier(for: parent.selection)
            if toolbar.selectedItemIdentifier != id {
                toolbar.selectedItemIdentifier = id
            }
        }

        // MARK: - Identifiers

        private func identifier(for tab: SettingsTab) -> NSToolbarItem.Identifier {
            NSToolbarItem.Identifier(rawValue: tab.rawValue)
        }

        private func tab(for identifier: NSToolbarItem.Identifier) -> SettingsTab? {
            SettingsTab(rawValue: identifier.rawValue)
        }

        private func allTabIdentifiers() -> [NSToolbarItem.Identifier] {
            var ids: [NSToolbarItem.Identifier] = [
                identifier(for: .products),
                identifier(for: .email),
                identifier(for: .intelligence),
            ]
            if parent.hasNotifications {
                ids.append(identifier(for: .notifications))
            }
            return ids
        }

        // MARK: - NSToolbarDelegate

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            allTabIdentifiers()
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            allTabIdentifiers()
        }

        func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            allTabIdentifiers()
        }

        func toolbar(
            _ toolbar: NSToolbar,
            itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
            willBeInsertedIntoToolbar flag: Bool
        ) -> NSToolbarItem? {
            guard let tab = tab(for: itemIdentifier) else { return nil }
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = tab.displayName
            item.paletteLabel = tab.displayName
            item.toolTip = tab.displayName
            item.image = NSImage(
                systemSymbolName: tab.systemImageName,
                accessibilityDescription: tab.displayName
            )
            item.target = self
            item.action = #selector(itemTapped(_:))
            return item
        }

        @objc private func itemTapped(_ sender: NSToolbarItem) {
            guard let tab = tab(for: sender.itemIdentifier) else { return }
            // Bridge selection change back to SwiftUI state.
            parent.selection = tab
        }
    }
}

private extension SettingsTab {
    var displayName: String {
        switch self {
        case .products:      return "Products"
        case .email:         return "Email"
        case .intelligence:  return "Intelligence"
        case .notifications: return "Notifications"
        }
    }

    var systemImageName: String {
        switch self {
        case .products:      return "folder"
        case .email:         return "envelope"
        case .intelligence:  return "sparkles"
        case .notifications: return "bell"
        }
    }
}
#endif

import Foundation
import Observation
import QuickLook
#if os(macOS)
import AppKit
import QuickLookUI
#else
import UIKit
import SwiftUI
#endif

@MainActor
@Observable
final class QuickLookPresenter {
    private(set) var items: [URL] = []
    private(set) var startIndex: Int = 0
    var isPresented: Bool = false

    func present(urls: [URL], startingAt index: Int = 0) {
        guard !urls.isEmpty else { return }
        self.items = urls
        self.startIndex = max(0, min(index, urls.count - 1))
        self.isPresented = true
        #if os(macOS)
        showMacPanel()
        #endif
    }

    func dismiss() {
        isPresented = false
        #if os(macOS)
        QLPreviewPanel.shared().close()
        #endif
    }

    #if os(macOS)
    private var dataSource: MacDataSource?
    private func showMacPanel() {
        let ds = MacDataSource(urls: items, startIndex: startIndex)
        self.dataSource = ds
        let panel = QLPreviewPanel.shared()!
        panel.dataSource = ds
        panel.delegate = ds
        panel.currentPreviewItemIndex = startIndex
        panel.makeKeyAndOrderFront(nil)
    }
    #endif
}

#if os(macOS)
final class MacDataSource: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let urls: [URL]
    var startIndex: Int

    init(urls: [URL], startIndex: Int) {
        self.urls = urls
        self.startIndex = startIndex
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }
}
#endif

#if !os(macOS)
import SwiftUI

struct QuickLookHost: View {
    @Environment(QuickLookPresenter.self) private var presenter

    var body: some View {
        Color.clear
            .fullScreenCover(isPresented: Binding(
                get: { presenter.isPresented },
                set: { if !$0 { presenter.dismiss() } }
            )) {
                QLPreviewControllerRepresentable(urls: presenter.items, startIndex: presenter.startIndex)
            }
    }
}

private struct QLPreviewControllerRepresentable: UIViewControllerRepresentable {
    let urls: [URL]
    let startIndex: Int

    func makeUIViewController(context: Context) -> QLPreviewController {
        let vc = QLPreviewController()
        vc.dataSource = context.coordinator
        vc.currentPreviewItemIndex = startIndex
        return vc
    }
    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(urls: urls) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let urls: [URL]
        init(urls: [URL]) { self.urls = urls }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { urls.count }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            urls[index] as NSURL
        }
    }
}
#endif

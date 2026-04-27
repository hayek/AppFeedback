#if os(macOS)
import SwiftUI
import AppKit

struct RichTextEditor: NSViewRepresentable {
    @Binding var attributedText: NSAttributedString
    var minHeight: CGFloat = 120

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFontPanel = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.textStorage?.setAttributedString(attributedText)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.attributedString() != attributedText {
            textView.textStorage?.setAttributedString(attributedText)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        init(_ parent: RichTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.attributedText = textView.attributedString()
        }
    }
}

/// Lightweight toolbar with Bold / Italic / Underline buttons that send
/// NSResponder action messages — the system routes them to the focused
/// NSTextView (which understands `toggleBold:`, `toggleItalic:`, `toggleUnderline:`).
struct RichTextToolbar: View {
    var body: some View {
        HStack(spacing: 4) {
            toolbarButton(systemName: "bold") {
                NSApp.sendAction(NSSelectorFromString("toggleBold:"), to: nil, from: nil)
            }
            toolbarButton(systemName: "italic") {
                NSApp.sendAction(NSSelectorFromString("toggleItalic:"), to: nil, from: nil)
            }
            toolbarButton(systemName: "underline") {
                NSApp.sendAction(NSSelectorFromString("toggleUnderline:"), to: nil, from: nil)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    private func toolbarButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName).frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
    }
}
#endif

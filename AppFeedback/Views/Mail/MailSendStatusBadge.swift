import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum MailSendState: Equatable {
    case sending
    case sent
    case failed(String)
}

struct MailSendStatusBadge: View {
    let state: MailSendState
    /// Re-runs the SMTP send for this message. Nil where no retry is wired up — the failure
    /// menu then only explains what went wrong.
    var onRetry: (() -> Void)? = nil

    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        Group {
            switch state {
            case .sending:
                row(icon: "paperplane", color: .tertiary) {
                    ShimmerText("Sending…")
                }
            case .sent:
                row(icon: "checkmark", color: .tertiary) { Text("Sent") }
            case .failed(let reason):
                failedBadge(reason: reason)
            }
        }
        .font(.system(size: 11))
        .animation(.easeInOut(duration: 0.25), value: state)
    }

    /// Tapping "Failed" opens a menu rather than a window: the retry is the thing you almost
    /// always want, and the reason — previously a macOS-only tooltip — reads as its header.
    private func failedBadge(reason: String) -> some View {
        Menu {
            Section(header: Text(headline(for: reason))) {
                if let onRetry {
                    Button("Retry Send", systemImage: "arrow.clockwise", action: onRetry)
                }
                Button("Copy Error", systemImage: "doc.on.doc") { copy(reason) }
                #if os(macOS)
                Button("Show Activity", systemImage: "list.bullet.rectangle") {
                    openWindow(id: "activity")
                }
                #endif
            }
        } label: {
            row(icon: "exclamationmark.triangle.fill", color: .red) { Text("Failed") }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(reason)
    }

    /// A menu header is one unwrapped line, so collapse newlines and cap the length — a verbose
    /// SMTP error would otherwise stretch the menu across the screen. The full text stays on the
    /// tooltip and behind Copy Error.
    private func headline(for reason: String) -> String {
        let single = reason
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard single.count > 120 else { return single }
        return single.prefix(119) + "…"
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    @ViewBuilder
    private func row<Label: View, S: ShapeStyle>(
        icon: String,
        color: S,
        @ViewBuilder label: () -> Label
    ) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            label()
        }
        .foregroundStyle(color)
        .transition(.opacity.combined(with: .scale))
    }
}

/// A label whose text has a soft highlight sweeping across it left-to-right, forever.
/// Conveys an in-flight action — used for the mail "Sending…" badge and the
/// task "Creating…" badge (see `CreationBadge`).
struct ShimmerText: View {
    let text: String
    @State private var phase: CGFloat = -1

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .overlay(
                LinearGradient(
                    colors: [.clear, .white.opacity(0.85), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 60)
                .offset(x: phase * 120)
                .blendMode(.plusLighter)
                .mask(Text(text))
            )
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

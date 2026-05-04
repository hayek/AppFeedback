import SwiftUI

enum MailSendState: Equatable {
    case sending
    case sent
    case failed(String)
}

struct MailSendStatusBadge: View {
    let state: MailSendState

    @State private var showFailureAlert: Bool = false

    var body: some View {
        Group {
            switch state {
            case .sending:
                row(icon: "paperplane", color: .tertiary) {
                    SendingShimmerText("Sending…")
                }
            case .sent:
                row(icon: "checkmark", color: .tertiary) { Text("Sent") }
            case .failed(let reason):
                Button { showFailureAlert = true } label: {
                    row(icon: "exclamationmark.triangle.fill", color: .red) { Text("Failed") }
                }
                .buttonStyle(.plain)
                .alert("Failed to send", isPresented: $showFailureAlert) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(reason)
                }
            }
        }
        .font(.system(size: 11))
        .animation(.easeInOut(duration: 0.25), value: state)
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

private struct SendingShimmerText: View {
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

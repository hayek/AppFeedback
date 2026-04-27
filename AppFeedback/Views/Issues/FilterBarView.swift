import SwiftUI

struct FilterBarView: View {
    @Bindable var viewModel: IssueListViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.allowsAppFilter {
                pillRow(label: "App", values: viewModel.uniqueAppNames,
                        binding: $viewModel.appFilter)
            }
            pillRow(label: "Version", values: viewModel.uniqueValues(for: \.appVersion),
                    binding: binding(for: \.appVersion))
            pillRow(label: "Device",  values: viewModel.uniqueValues(for: \.device),
                    binding: binding(for: \.device))
            pillRow(label: "OS",      values: viewModel.uniqueValues(for: \.osVersion),
                    binding: binding(for: \.osVersion))
        }
        .padding(12)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    }

    @ViewBuilder
    private func pillRow(label: String, values: [String], binding: Binding<String?>) -> some View {
        if !values.isEmpty {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(.tertiary)
                    .frame(width: 52, alignment: .leading)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(values, id: \.self) { value in
                            PillButton(
                                title: value,
                                isActive: binding.wrappedValue == value
                            ) {
                                binding.wrappedValue = binding.wrappedValue == value ? nil : value
                            }
                        }
                    }
                }
            }
        }
    }

    private func binding(for keyPath: WritableKeyPath<IssueListViewModel.ActiveFilters, String?>) -> Binding<String?> {
        Binding(
            get: { viewModel.filters[keyPath: keyPath] },
            set: { viewModel.filters[keyPath: keyPath] = $0 }
        )
    }
}

private struct PillButton: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    isActive ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.08),
                    in: Capsule()
                )
                .overlay(Capsule().stroke(
                    isActive ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.15),
                    lineWidth: 1
                ))
        }
        .buttonStyle(.plain)
    }
}

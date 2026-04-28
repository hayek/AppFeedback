import SwiftUI

struct FilterBarView: View {
    @Bindable var viewModel: IssueListViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.allowsAppFilter {
                pillRow(label: "App", values: viewModel.uniqueAppNames,
                        binding: $viewModel.appFilter)
            }
            typeRow()
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
    private func typeRow() -> some View {
        let types = viewModel.uniqueIssueTypes
        if !types.isEmpty {
            HStack(spacing: 8) {
                Text("Type")
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(.tertiary)
                    .frame(width: 52, alignment: .leading)

                HStack(spacing: 6) {
                    ForEach(types, id: \.self) { type in
                        TypePillButton(
                            type: type,
                            isActive: viewModel.filters.issueType == type
                        ) {
                            viewModel.filters.issueType = viewModel.filters.issueType == type ? nil : type
                        }
                    }
                }
            }
        }
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
                    .padding(.horizontal, 12)
                }
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .black, location: 0.04),
                            .init(color: .black, location: 0.96),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .padding(.horizontal, -12)
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

private struct TypePillButton: View {
    let type: IssueType
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: type.systemImage)
                    .font(.system(size: 10, weight: isActive ? .semibold : .regular))
                Text(type.displayName)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
            }
            .foregroundStyle(isActive ? AnyShapeStyle(Color.primary.opacity(0.85)) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Color.primary.opacity(isActive ? 0.1 : 0.05),
                in: Capsule()
            )
            .overlay(Capsule().stroke(
                Color.primary.opacity(isActive ? 0.25 : 0.1),
                lineWidth: 1
            ))
        }
        .buttonStyle(.plain)
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

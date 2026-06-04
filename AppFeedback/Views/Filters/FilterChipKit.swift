import SwiftUI

// MARK: - Generic multi-select filter chip

/// A reusable multi-select filter chip: a menu trigger ("Label : All ▾") plus inline removable
/// sub-pills for each selected value. Renders nothing when `values` is empty. Used by both the
/// feedback filter bar and the inspector's task/version filter bars.
struct MultiSelectFilterChip<Value: Hashable>: View {
    let label: String
    let values: [Value]
    @Binding var selection: Set<Value>
    var display: (Value) -> String
    /// Optional SF Symbol per value; when present the menu shows it (or a checkmark when selected)
    /// and the sub-pill carries it as a leading glyph.
    var symbol: ((Value) -> String)? = nil
    var accent: Color = .accentColor

    var body: some View {
        if !values.isEmpty {
            FilterChipContainer(isActive: !selection.isEmpty, accent: accent) {
                Menu {
                    if !selection.isEmpty {
                        Button("Clear \(label)") { selection = [] }
                        Divider()
                    }
                    ForEach(values, id: \.self) { value in
                        Button {
                            if selection.contains(value) { selection.remove(value) }
                            else { selection.insert(value) }
                        } label: {
                            let isSelected = selection.contains(value)
                            if let sym = symbol?(value) {
                                Label(display(value), systemImage: isSelected ? "checkmark" : sym)
                            } else if isSelected {
                                Label(display(value), systemImage: "checkmark")
                            } else {
                                Text(display(value))
                            }
                        }
                    }
                } label: {
                    FilterTitleSegment(label: label, showsAll: selection.isEmpty)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()

                ForEach(selection.sorted { display($0) < display($1) }, id: \.self) { value in
                    SubPill(text: display(value), leadingSymbol: symbol?(value), accent: accent) {
                        selection.remove(value)
                    }
                }
            }
        }
    }
}

// MARK: - Expandable search field

/// A magnifier button that expands into an inline text field with a clear/collapse control.
/// Stays expanded while it holds text; collapses when emptied and unfocused.
/// Shared widget: used by the inspector's task/version filter bars (and any future filter bar).
struct ExpandableSearchField: View {
    @Binding var text: String
    var prompt: String = "Search"
    var accent: Color = .accentColor
    @State private var expanded = false
    @FocusState private var focused: Bool

    private var isOpen: Bool { expanded || !text.isEmpty }

    var body: some View {
        Group {
            if isOpen {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField(prompt, text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($focused)
                        .frame(width: 150)
                        #if os(iOS)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        #endif
                    Button {
                        text = ""
                        focused = false
                        withAnimation(.easeInOut(duration: 0.18)) { expanded = false }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.secondary.opacity(0.10)))
                // `accent` only tints the active (non-empty) border; search is otherwise styled
                // neutrally so it doesn't read as an active filter chip.
                .overlay(Capsule().stroke(accent.opacity(text.isEmpty ? 0 : 0.28), lineWidth: 1))
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded = true }
                    // Focus on the next runloop tick, once the TextField exists in the hierarchy.
                    // Deliberately NOT via the field's .onAppear: that would re-raise the keyboard
                    // if the enclosing List row re-appears while already expanded.
                    DispatchQueue.main.async { focused = true }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.secondary.opacity(0.08)))
                        .overlay(Capsule().stroke(Color.secondary.opacity(0.18), lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Search")
            }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused && text.isEmpty {
                withAnimation(.easeInOut(duration: 0.18)) { expanded = false }
            }
        }
    }
}

// MARK: - Clear button

/// The trailing "clear filters" pill shown when any filter is active.
struct ClearFiltersButton: View {
    var title: String = "Clear All"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .help("Clear all filters")
    }
}

// MARK: - Shared chip pieces

/// Outer rounded capsule that contains the title segment + sub-pills as one unit.
struct FilterChipContainer<Content: View>: View {
    let isActive: Bool
    var accent: Color = .accentColor
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 4) {
            content
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(
            isActive ? accent.opacity(0.08) : Color.secondary.opacity(0.06),
            in: Capsule()
        )
        .overlay(
            Capsule().stroke(
                isActive ? accent.opacity(0.28) : Color.secondary.opacity(0.18),
                lineWidth: 1
            )
        )
    }
}

/// The "Title :" / "Title : All" portion that opens the menu.
struct FilterTitleSegment: View {
    let label: String
    let showsAll: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(":")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            if showsAll {
                Text("All")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 8)
        .padding(.trailing, showsAll ? 8 : 6)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

/// Removable sub-pill rendered inline inside the outer chip.
struct SubPill: View {
    let text: String
    var leadingSymbol: String? = nil
    var accent: Color = .accentColor
    let onRemove: () -> Void

    var body: some View {
        Button(action: onRemove) {
            HStack(spacing: 3) {
                if let leadingSymbol {
                    Image(systemName: leadingSymbol)
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(text)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(accent.opacity(0.7))
            }
            .foregroundStyle(accent)
            .padding(.leading, 7)
            .padding(.trailing, 5)
            .padding(.vertical, 3)
            .background(accent.opacity(0.18), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Remove \(text)")
    }
}

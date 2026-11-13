import SwiftUI
import AppKit

// MARK: - Quick Open (⌘K, the Spotlight-style key jump)

/// Spotlight-style palette over the currently loaded keys. Liquid Glass panel
/// on macOS 26+, thin material below it. Arrow keys move, Enter opens, Esc
/// dismisses — the same interaction language as Xcode's "Open Quickly".
struct QuickOpenSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    @State private var selection = 0

    /// Cap the rendered rows: a 3000-key database must not build 3000 views.
    private let maxRows = 40

    private var results: [String] {
        guard !query.isEmpty else { return Array(store.keys.prefix(maxRows)) }
        return Array(store.keys.filter { $0.localizedCaseInsensitiveContains(query) }.prefix(maxRows))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(L10n("Jump to key…"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: ARDMFont.title))
                    .onSubmit { open(selection) }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .accessibilityIdentifier("quickopen.field")
                Text("esc")
                    .font(.system(size: ARDMFont.micro))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.14)))
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            Divider().opacity(0.5)

            if results.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: store.keys.isEmpty ? "cylinder.questionmark" : "magnifyingglass")
                        .font(.system(size: ARDMIcon.emptyState))
                        .foregroundStyle(.tertiary)
                    Text(store.keys.isEmpty ? L10n("Load keys first") : L10n("No matches"))
                        .font(.system(size: ARDMFont.body))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element) { index, key in
                                row(index: index, key: key)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: selection) { _, newValue in
                        if let key = results[safe: newValue] {
                            proxy.scrollTo(key, anchor: .center)
                        }
                    }
                }
            }

            Divider().opacity(0.5)
            HStack {
                Text("\(results.count) / \(store.keys.count) " + L10n("keys"))
                    .font(.system(size: ARDMFont.micro))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Spacer()
                Text("↑↓ 选择 · ↩ 打开")
                    .font(.system(size: ARDMFont.micro))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 24)
        }
        .frame(width: 520, height: results.isEmpty ? 160 : 380)
        .ardmGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(20)
        .onAppear { selection = 0 }
    }

    private func row(index: Int, key: String) -> some View {
        let active = index == selection
        let meta = store.keyMeta[key]
        return HStack(spacing: 8) {
            if let meta {
                ARDMTypeBadge(type: meta.type)
            } else {
                ARDMTypeBadge(type: .string, dimmed: true)
            }
            Text(key)
                .font(.system(size: ARDMFont.monoRow, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let meta, meta.ttl > 0 {
                Text(ARDMFormat.ttl(meta.ttl))
                    .font(.system(size: ARDMFont.micro))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(active ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovering in if hovering { selection = index } }
        .onTapGesture { open(index) }
        .id(key)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityLabel(key)
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = max(0, min(results.count - 1, selection + delta))
    }

    private func open(_ index: Int) {
        guard let key = results[safe: index] else { return }
        store.selectKey(key)
        dismiss()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

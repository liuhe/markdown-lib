import SwiftUI

public struct FindBar: View {
    @ObservedObject public var bridge: EditorBridge

    /// Focus routing for the two text fields.
    private enum Field: Hashable { case find, replace }
    @FocusState private var focused: Field?

    public init(bridge: EditorBridge) { self.bridge = bridge }

    public var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find", text: $bridge.query)
                    .textFieldStyle(.plain)
                    .focused($focused, equals: .find)
                    .onSubmit { bridge.findNext() }
                    .frame(minWidth: 140)
                Text(matchLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))

            Button(action: { bridge.findPrev() }) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(bridge.matchCount == 0)
            .help("Previous (⇧⌘G)")

            Button(action: { bridge.findNext() }) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(bridge.matchCount == 0)
            .help("Next (⌘G)")

            Divider().frame(height: 18)

            TextField("Replace", text: $bridge.replacement)
                .textFieldStyle(.roundedBorder)
                .focused($focused, equals: .replace)
                .frame(minWidth: 120)

            Button("Replace") { bridge.replaceCurrent() }
                .disabled(bridge.matchCount == 0)

            Button("All") { bridge.replaceAll() }
                .disabled(bridge.matchCount == 0)

            Spacer()

            Button("Done") { bridge.hideFind() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(Divider(), alignment: .bottom)
        .onAppear { focused = .find }
        .onChange(of: bridge.searchVisible) { _, visible in
            if visible { focused = .find }
        }
        .onChange(of: bridge.query) { _, _ in
            bridge.performSearch(scrollToFirst: true)
        }
    }

    private var matchLabel: String {
        if bridge.query.isEmpty { return "" }
        if bridge.matchCount == 0 { return "no matches" }
        return "\(bridge.currentIndex) of \(bridge.matchCount)"
    }
}

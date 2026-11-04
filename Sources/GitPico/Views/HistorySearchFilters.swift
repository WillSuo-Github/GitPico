import GitCore
import SwiftUI

struct SearchScopeBar: View {
    let title: String
    let query: String
    var clear: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: "line.3.horizontal.decrease")
            Spacer(minLength: 4)
            Button(action: clear) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
        }.font(.caption).foregroundStyle(.secondary).help(query)
            .accessibilityElement(children: .contain)
    }
}

struct HistorySearchFilters: View {
    @Bindable var store: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var author = ""
    @State private var path = ""
    @State private var content = ""
    @State private var after = ""
    @State private var before = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search Commit History").font(.headline)
            Text("Searches commits reachable from the selected history scope, including older commits that have not been loaded.")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                field("Message / existing query", value: $query, prompt: "Message, hash or search terms")
                field("Author", value: $author, prompt: "Name or email")
                field("File path", value: $path, prompt: "Sources/File.swift")
                field("Changed code", value: $content, prompt: "Literal text added or removed")
                field("After", value: $after, prompt: "yyyy-MM-dd")
                field("Before", value: $before, prompt: "yyyy-MM-dd")
            }.textFieldStyle(.roundedBorder)
            Text("Changed code finds commits where the number of occurrences of this text changed.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(Pico.deletion) }
            HStack {
                Button("Clear Filters") { query = ""; author = ""; path = ""; content = ""; after = ""; before = "" }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Search") {
                    let value = Self.query(existing: query, author: author, path: path, content: content, after: after, before: before)
                    do { _ = try HistoryQuery(value); store.search = value; dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 510).onAppear { query = store.search }
    }
    private func field(_ title: LocalizedStringKey, value: Binding<String>, prompt: LocalizedStringKey) -> some View {
        GridRow { Text(title); TextField(title, text: value, prompt: Text(prompt)) }
    }
    nonisolated static func query(existing: String, author: String, path: String, content: String, after: String, before: String) -> String {
        var terms = [existing]
        for (key, value) in [("author", author), ("path", path), ("content", content), ("after", after), ("before", before)] where !value.isEmpty {
            terms.append(key + ":\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"")
        }
        return terms.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

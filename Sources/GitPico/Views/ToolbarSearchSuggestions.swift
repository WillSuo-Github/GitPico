import SwiftUI

struct ToolbarSearchSuggestions: View {
    @Bindable var session: ToolbarSearchSession
    var body: some View {
        let state = session.presentation
        VStack(spacing: 0) {
            HStack {
                SectionCaption(session.actionsOnly ? "Actions" : "Search & Quick Actions")
                Spacer()
                if state.loading { ProgressView().controlSize(.mini) }
            }.foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        if let title = state.contextTitle {
                            suggestion(title: title, subtitle: "Filter this view · Return", icon: "magnifyingglass", selected: state.selection == nil, action: session.filterCurrentView)
                            Divider().padding(.horizontal, 8)
                        }
                        ForEach(state.results) { item in
                            suggestion(title: item.title, subtitle: item.subtitle, icon: item.icon, selected: state.selection == item.id) { _ = session.submit(item) }.id(item.id)
                        }
                        if state.results.isEmpty {
                            Text(state.loading ? "Searching…" : "No matching files, branches or actions")
                                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(18)
                        }
                    }.padding(.horizontal, 5).padding(.bottom, 5)
                }
                .onChange(of: state.selection) { if let id = state.selection { proxy.scrollTo(id) } }
            }
            if let failure = state.failure {
                HStack { Text(failure).lineLimit(1); Spacer(); Button("Retry", action: session.retry) }.font(.caption).foregroundStyle(.secondary).padding(8)
            }
            Divider()
            HStack(spacing: 10) { keycap("↑↓", "Select"); keycap("↩", "Run"); keycap("esc", "Close"); Spacer(); keycap(">", "Actions") }.padding(.horizontal, 12).padding(.vertical, 7)
        }.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    private func keycap(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10, weight: .semibold, design: .rounded)).padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
        }.font(.caption2).foregroundStyle(.secondary)
    }
    private func suggestion(title: String, subtitle: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(selected ? Color.white : Color.accentColor)
                    .frame(width: 26, height: 26).background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.accentColor.opacity(0.12)), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 9).frame(height: 46).contentShape(Rectangle())
                .background(selected ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }.buttonStyle(.plain).accessibilityLabel(title + ", " + subtitle)
    }
}

import AppKit
import GitCore
import SwiftUI

struct ContentView: View {
    @Bindable var store: RepositoryStore
    var showsSidebar = true
    var body: some View {
        Group {
            if store.snapshot == nil || store.isChoosingRepository {
                if let workspace = store.workspace, let tab = workspace.tab(for: store) {
                    RepositoryPickerView(workspace: workspace, tab: tab, showsSidebar: showsSidebar)
                } else { WelcomeView(store: store) }
            } else if showsSidebar {
                NavigationSplitView {
                    SidebarView(store: store)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 359, max: 450)
                        .toolbar { ToolbarItem { RepositoryMenu(store: store) } }
                } detail: { RepositoryDetailView(store: store) }
            } else { RepositoryDetailView(store: store) }
        }
        .frame(minWidth: showsSidebar ? 1080 : 0, minHeight: showsSidebar ? 680 : 0)
        .navigationTitle(store.isChoosingRepository ? String(localized: "Repositories") : store.title)
        .navigationSubtitle(store.isChoosingRepository ? String(localized: "Choose a repository") : store.navigationSubtitle)
        .toolbar { if store.workspace == nil { RepositoryToolbar(store: store) } }
        .safeAreaInset(edge: .bottom, spacing: 0) { if showsSidebar { RepositoryStatusBar(store: store) } }
        .safeAreaInset(edge: .top, spacing: 0) { if !store.isChoosingRepository { VStack(spacing: 0) { UpstreamRecoveryBanner(store: store); AutomaticStashBanner(store: store); GitFlowOperationBanner(store: store); if store.destination != .workingCopy { OperationBanner(store: store) } } } }
        .task(id: store.search) { await store.searchHistory() }
        .modifier(RepositoryPresentations(store: store))
    }


}

struct InputSheet: View {
    let title: LocalizedStringResource
    let caption: LocalizedStringResource
    let placeholder: LocalizedStringResource
    let button: LocalizedStringResource
    let action: (String) -> Void
    @State private var value = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title)
            Text(caption).foregroundStyle(.secondary)
            TextField(placeholder, text: $value).textFieldStyle(.roundedBorder).onSubmit(submit)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(button, action: submit).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 450)
    }
    func submit() { guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }; action(value); dismiss() }
}

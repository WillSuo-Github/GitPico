import SwiftUI

struct RepositoryWorkspaceView: View {
    @Bindable var workspace: RepositoryWorkspace
    @Bindable var tab: RepositoryTab
    var presentsAlerts: Bool
    var descriptorChanged: () -> Void
    init(workspace: RepositoryWorkspace, tab: RepositoryTab? = nil, presentsAlerts: Bool = true, descriptorChanged: @escaping () -> Void = {}) {
        self.workspace = workspace
        self.tab = tab ?? workspace.activeTab
        self.presentsAlerts = presentsAlerts
        self.descriptorChanged = descriptorChanged
    }
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Group {
                    if tab.showsRepositoryPicker || tab.store.snapshot == nil {
                        RepositoryPickerSidebarView(workspace: workspace, tab: tab)
                    } else {
                        SidebarView(store: tab.store)
                    }
                }
                    .safeAreaPadding(.bottom, RepositoryStatusBar.height)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
            .toolbar {
                ToolbarItemGroup {
                    if tab.showsRepositoryPicker, tab.root != nil {
                        Button { workspace.returnToRepository(from: tab.store) } label: { Label("Back to Repository", systemImage: "chevron.left") }
                            .help("Return to " + (tab.root.map { workspace.library.displayName(for: $0.path) } ?? "repository"))
                    }
                    RepositoryMenu(store: tab.store)
                }
            }
        } detail: {
            VStack(spacing: 0) {
                if let warning = workspace.draftSaveWarning {
                    NoticeBanner(icon: "exclamationmark.triangle.fill", title: "Commit drafts could not be saved", message: warning) {
                        Button("Retry", action: workspace.flushDrafts)
                    }
                }
                if let warning = workspace.sessionSaveWarning {
                    NoticeBanner(icon: "exclamationmark.triangle.fill", title: "Workspace could not be saved", message: warning) {
                        Button("Retry", action: workspace.retrySessionSave)
                    }
                }
                ContentView(store: tab.store, showsSidebar: false)
            }
            // The split view's columns ignore the window-level inset; keep fixed bottom controls above the status bar.
            .safeAreaPadding(.bottom, RepositoryStatusBar.height)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1080, minHeight: 680)
        .disabled(tab.isOpening)
        .toolbar { RepositoryToolbar(store: tab.store) }
        .toolbar(removing: .title)
        .safeAreaInset(edge: .bottom, spacing: 0) { RepositoryStatusBar(store: tab.store) }
        .onChange(of: tab.title, initial: true) { descriptorChanged() }
        .onChange(of: tab.isBusy) { descriptorChanged() }
        .onChange(of: tab.store.snapshot == nil) { descriptorChanged() }
        .onChange(of: tab.showsRepositoryPicker) { descriptorChanged() }
        .alert("Repository Tabs", isPresented: Binding(get: { presentsAlerts && workspace.selectedID == tab.id && workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button("OK") { workspace.error = nil }
        } message: { Text(workspace.error ?? "") }
    }
}

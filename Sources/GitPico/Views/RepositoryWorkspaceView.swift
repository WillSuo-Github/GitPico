import SwiftUI

struct RepositoryWorkspaceView: View {
    @Bindable var workspace: RepositoryWorkspace
    @Bindable var tab: RepositoryTab
    var presentsAlerts: Bool
    var descriptorChanged: () -> Void
    private var showsRepository: Bool { !tab.showsRepositoryPicker && tab.store.snapshot != nil }
    private var statusBarInset: CGFloat { showsRepository ? RepositoryStatusBar.height : 0 }
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
                    if showsRepository {
                        SidebarView(store: tab.store)
                            .environment(\.repositoryStatusBarInset, statusBarInset)
                    } else {
                        RepositoryPickerSidebarView(workspace: workspace, tab: tab)
                    }
                }
                .safeAreaPadding(.bottom, showsRepository ? 0 : RepositoryStatusBar.height)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
            .toolbar {
                ToolbarItemGroup {
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
                ContentView(store: tab.store, showsSidebar: false, statusBarInset: statusBarInset)
            }
            .safeAreaPadding(.bottom, showsRepository ? 0 : RepositoryStatusBar.height)
            .overlay(alignment: .bottom) {
                if showsRepository {
                    RepositoryStatusBarBackground(
                        isRunning: tab.store.isPerformingActivity,
                        featherHeight: RepositoryStatusBarBackground.featherHeight
                    )
                    .frame(height: statusBarInset + RepositoryStatusBarBackground.featherHeight)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background {
            if showsRepository { Rectangle().fill(.windowBackground).ignoresSafeArea(.container, edges: .top) }
        }
        .frame(minWidth: 1080, minHeight: 680)
        .disabled(tab.isOpening)
        .toolbar { RepositoryToolbar(store: tab.store) }
        .toolbar(removing: .title)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !showsRepository { RepositoryStatusBar(store: tab.store) }
        }
        .overlay(alignment: .bottom) {
            if showsRepository { RepositoryStatusBar(store: tab.store, showsBackground: false) }
        }
        .onChange(of: tab.title, initial: true) { descriptorChanged() }
        .onChange(of: tab.isBusy) { descriptorChanged() }
        .onChange(of: tab.showsActivitySpinner) { descriptorChanged() }
        .onChange(of: tab.store.snapshot == nil) { descriptorChanged() }
        .onChange(of: tab.showsRepositoryPicker) { descriptorChanged() }
        .alert("Repository Tabs", isPresented: Binding(get: { presentsAlerts && workspace.selectedID == tab.id && workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button("OK") { workspace.error = nil }
        } message: { Text(workspace.error ?? "") }
    }
}

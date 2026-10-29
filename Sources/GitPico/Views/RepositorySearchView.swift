import SwiftUI

struct RepositorySearchView: View {
    @Bindable var store: RepositoryStore
    @State private var session: ToolbarSearchSession
    @State private var actionFocusRequest: UUID?
    init(store: RepositoryStore) {
        self.store = store
        _session = State(initialValue: ToolbarSearchSession(store: store))
    }
    var body: some View {
        ToolbarSearchField(text: Binding(get: { session.text }, set: { session.updateText($0) }), placeholder: store.destination.searchWithActionsPlaceholder, focusRequest: $store.searchFocusRequest, selectAllOnFocus: !session.actionsOnly, session: session, presentation: session.presentation)
            .disabled(!store.canUseRepository && !store.isFetching)
            .help("Search this view, files, branches, commits and actions. Type > for actions. ⌘F to search; ⌘⇧A for actions.")
            .onChange(of: store.searchActionsRequest, initial: true) {
                guard store.searchActionsRequest != nil, store.canUseRepository else { return }
                store.searchActionsRequest = nil
                session.beginActions()
                let request = UUID(); actionFocusRequest = request; store.searchFocusRequest = request
            }
            .onChange(of: store.searchFocusRequest) {
                guard let request = store.searchFocusRequest, request != actionFocusRequest else { return }
                session.beginContextSearch()
            }
            .onChange(of: store.search) { session.externalQueryChanged() }
            .onChange(of: store.destination) { session.contextChanged() }
            .onChange(of: store.lastUpdated) { session.invalidate() }
            .onChange(of: store.showIgnoredFiles) { session.invalidate() }
            .onChange(of: store.repositoryToken) { session.invalidate() }
            .onChange(of: store.canUseRepository) { if !store.canUseRepository && !store.isFetching { session.endEditing() } }
    }
}

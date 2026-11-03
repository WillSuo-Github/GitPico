import GitCore
import SwiftUI
import UniformTypeIdentifiers

struct AccountRepositoriesView: View {
    let workspace: RepositoryWorkspace
    let store: RepositoryStore
    let account: AuthenticationProfile
    let provider: OAuthProvider

    @State private var repositories: [AccountRepository]?
    @State private var loadError: String?
    @State private var localIndex: [HostedRepositoryKey: Set<String>] = [:]
    @State private var indexedRequest: IndexRequest?
    @State private var refreshID = UUID()
    @State private var query = ""
    @State private var searchFocused = false
    @State private var selection: Int64?
    @State private var locating: AccountRepository?
    @State private var showsFolderPicker = false
    @State private var checkingFolder = false

    private struct IndexRequest: Equatable {
        let paths: Set<String>
        let refreshID: UUID
    }

    private struct LoadRequest: Equatable {
        let revision: Int
        let refreshID: UUID
    }

    private var indexRequest: IndexRequest {
        IndexRequest(paths: Set(workspace.library.document.repositories.map(\.path)), refreshID: refreshID)
    }

    private var indexReady: Bool { indexedRequest == indexRequest }
    private var visibleRepositories: [AccountRepository] {
        let terms = query.split(whereSeparator: \.isWhitespace)
        return (repositories ?? []).filter { repo in
            terms.allSatisfy { repo.fullName.localizedStandardContains(String($0)) }
        }
    }
    private var selectedRepository: AccountRepository? { visibleRepositories.first { $0.id == selection } }
    private var savedByPath: [String: SavedRepository] {
        Dictionary(uniqueKeysWithValues: workspace.library.document.repositories.map { ($0.path, $0) })
    }

    var body: some View {
        let loadRequest = LoadRequest(revision: workspace.authentication.revision, refreshID: refreshID)
        let indexRequest = indexRequest
        VStack(alignment: .leading, spacing: 18) {
            header
            if let loadError {
                VStack {
                    Spacer()
                    Label("Failed", systemImage: "exclamationmark.icloud").font(.headline)
                    Text(loadError).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Authentication…") { store.showingAuthentication = true }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let repositories {
                repositoryList
                HStack {
                    if !indexReady {
                        ProgressView().controlSize(.small)
                        Text("Checking repository…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("\(repositories.count) repositories").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if indexReady, let repository = selectedRepository {
                        Button(copies(for: repository, in: savedByPath).isEmpty ? "Clone" : "Open Local") { activate(repository) }
                            .buttonStyle(.borderedProminent)
                            .disabled(checkingFolder)
                    }
                }
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: 920, maxHeight: .infinity)
        .padding(.horizontal, 36).padding(.top, 28).padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LinearGradient(stops: [.init(color: Pico.brandTop.opacity(0.10), location: 0), .init(color: .clear, location: 0.32)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(.container, edges: .top).allowsHitTesting(false)
        }
        .safeAreaPadding(.bottom)
        .task(id: loadRequest) { await load() }
        .task(id: indexRequest) {
            let index = await LocalHostedRepositoryIndex.load(paths: indexRequest.paths, provider: provider)
            guard !Task.isCancelled else { return }
            localIndex = index
            indexedRequest = indexRequest
        }
        .onChange(of: visibleRepositories.map(\.id)) { _, ids in
            if selection.map(ids.contains) != true { selection = ids.first }
        }
        .fileImporter(isPresented: $showsFolderPicker, allowedContentTypes: [.folder]) { result in
            guard let repository = locating else { return }
            locating = nil
            switch result {
            case .success(let url): openLocal(url, for: repository, locating: true)
            case .failure(let error): store.error = error.localizedDescription
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "cloud")
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Pico.brand, in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 3) {
                Text(account.provider.title).font(.system(size: 26, weight: .bold, design: .rounded))
                Text(account.username + " @ " + account.host).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button {
                refreshID = UUID()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .help("Refresh")
            .disabled(repositories == nil && loadError == nil || checkingFolder)
        }
    }

    private var repositoryList: some View {
        let savedByPath = savedByPath
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionCaption("Repositories")
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    RepositoryPickerSearchField(text: $query, isFocused: $searchFocused, submit: activateSelection,
                                                placeholder: String(localized: "Search in \(String(localized: "Repositories"))"))
                }
                .padding(.horizontal, 10).frame(width: 270, height: 28)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(searchFocused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: searchFocused ? 1.5 : 0.5))
            }
            List(selection: $selection) {
                ForEach(visibleRepositories) { repository in
                    let local = copies(for: repository, in: savedByPath)
                    HStack(spacing: 12) {
                        RepositoryGlyph(name: repository.name, size: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(repository.fullName).fontWeight(.semibold).lineLimit(1)
                                if repository.isRestricted {
                                    Image(systemName: "lock").accessibilityHidden(true)
                                }
                            }
                            if let copy = local.first {
                                Text(Pico.abbreviated(copy.path)).font(.caption).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 8)
                        if !local.isEmpty {
                            Label("Local", systemImage: "checkmark.circle").font(.caption)
                        }
                        if indexReady {
                            Button(local.isEmpty ? "Clone" : "Open Local") { activate(repository) }
                                .buttonStyle(.borderless)
                                .disabled(checkingFolder)
                        }
                    }
                    .padding(.vertical, 6)
                    .tag(repository.id)
                    .contextMenu {
                        ForEach(local) { copy in
                            Button(Pico.abbreviated(copy.path)) { openLocal(URL(fileURLWithPath: copy.path), for: repository) }
                        }
                        Button("Locate Repository…") {
                            locating = repository
                            showsFolderPicker = true
                        }
                        .disabled(checkingFolder)
                    }
                }
            }
            .listStyle(.inset).scrollContentBackground(.hidden)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5).allowsHitTesting(false))
            .contextMenu(forSelectionType: Int64.self) { _ in } primaryAction: { ids in
                if let repository = visibleRepositories.first(where: { ids.contains($0.id) }) { activate(repository) }
            }
            .onKeyPress(.return) {
                guard !searchFocused, selectedRepository != nil else { return .ignored }
                activateSelection()
                return .handled
            }
            .overlay {
                if visibleRepositories.isEmpty {
                    EmptyPane(title: query.isEmpty ? String(localized: "No repositories here yet") : String(localized: "No matches"),
                              subtitle: query.isEmpty ? "" : String(localized: "No repositories match this search."),
                              icon: query.isEmpty ? "tray" : "magnifyingglass")
                }
            }
        }
    }

    private func copies(for repository: AccountRepository, in savedByPath: [String: SavedRepository]) -> [SavedRepository] {
        guard indexReady else { return [] }
        let paths = repository.keys.reduce(into: Set<String>()) { paths, key in
            if let matches = localIndex[key] { paths.formUnion(matches) }
        }
        return paths.compactMap { savedByPath[$0] }.sorted {
            let left = $0.lastOpened ?? .distantPast, right = $1.lastOpened ?? .distantPast
            return left == right ? $0.path < $1.path : left > right
        }
    }

    private func load() async {
        repositories = nil
        loadError = nil
        do {
            let vault = workspace.authentication.vault
            let id = account.id
            let credential = account.isOAuth ? try await OAuthCredentialRefresher.shared.credential(id) : try await Task.detached { try vault.read(id) }.value
            let result = try await AccountRepositoryClient.list(account, credential: credential)
            guard !Task.isCancelled else { return }
            repositories = result
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
        }
    }

    private func activateSelection() {
        if let selectedRepository { activate(selectedRepository) }
    }

    private func activate(_ repository: AccountRepository) {
        guard indexReady, !checkingFolder, !store.isBusy, workspace.authentication.profiles.contains(account) else { return }
        if let copy = copies(for: repository, in: savedByPath).first {
            openLocal(URL(fileURLWithPath: copy.path), for: repository)
        } else {
            store.creationRequest = RepositoryCreationRequest(clone: true, source: repository.cloneURL.absoluteString,
                                                              name: repository.name, profileID: account.id)
        }
    }

    private func openLocal(_ location: URL, for repository: AccountRepository, locating: Bool = false) {
        guard !checkingFolder, !store.isBusy else { return }
        checkingFolder = true
        Task {
            defer { checkingFolder = false }
            do {
                let (root, keys) = try await LocalHostedRepositoryIndex.keys(at: location, provider: provider, requireExactRoot: !locating)
                guard workspace.tab(for: store)?.pickerFilter == .account(account.id),
                      workspace.authentication.profiles.contains(account) else { return }
                guard !keys.isDisjoint(with: repository.keys) else {
                    throw appFailure("This folder’s Git remote does not match the selected repository.")
                }
                // Opening registers the repository in the library, including
                // folders previously cloned outside GitPico.
                await store.open(root)
            } catch {
                guard workspace.tab(for: store)?.pickerFilter == .account(account.id) else { return }
                store.error = error.localizedDescription
                if !locating { refreshID = UUID() }
            }
        }
    }
}

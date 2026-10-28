import GitCore
import SwiftUI

struct BranchCreateSheet: View {
    let store: RepositoryStore
    @State var revision: String
    let upstream: String?
    @State private var name = ""
    @State private var checkout = true
    @State private var tracking = ""
    @State private var commit: Commit?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetTitle("Create New Branch")
            Text("Creates a local branch at the selected revision.").foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $name)
                LabeledContent("Revision") { RevisionField(store: store, value: $revision) }
                if let commit { LabeledContent("Commit", value: commit.shortHash + " · " + commit.subject).font(.caption).lineLimit(2) }
                Picker("Track upstream", selection: $tracking) {
                    Text("No Tracking").tag("")
                    ForEach((store.snapshot?.references ?? []).filter { !$0.isTag && !$0.name.hasSuffix("/HEAD") }) { Text($0.name).tag($0.fullName) }
                }
                Toggle("Check Out New Branch", isOn: $checkout)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            ManagementFooter(title: "Create Branch", disabled: name.isEmpty || commit == nil || store.isBusy) {
                guard let hash = commit?.hash else { return }
                let value = name, checkout = checkout, upstream = tracking.isEmpty ? nil : tracking
                store.protectedPerform("Creating branch…", protect: checkout, refresh: checkout ? .workingTree : .full) { try await $0.createBranch(value, at: hash, checkout: checkout, upstream: upstream) }; dismiss()
            }
        }.padding(24).frame(width: 540)
        .onAppear { tracking = upstream ?? ""; if let upstream { name = upstream.replacingOccurrences(of: "refs/remotes/", with: "").split(separator: "/").dropFirst().joined(separator: "/") } }
        .task(id: revision) { commit = nil; error = nil; do { let value = try await store.repository?.commit(at: revision); guard !Task.isCancelled else { return }; commit = value } catch { if !Task.isCancelled { self.error = error.localizedDescription } } }
    }
}

struct TagCreateSheet: View {
    let store: RepositoryStore
    @State var revision: String
    @State private var name = ""
    @State private var message = ""
    @State private var annotated = false
    @State private var sign = false
    @State private var key = ""
    @State private var commit: Commit?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetTitle("Create New Tag")
            Text("Creates a local tag pointing at the selected revision.").foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $name)
                LabeledContent("Revision") { RevisionField(store: store, value: $revision) }
                if let commit { LabeledContent("Commit", value: commit.shortHash + " · " + commit.subject).font(.caption).lineLimit(2) }
                Toggle("Annotated Tag", isOn: $annotated)
                TextField("Message", text: $message, axis: .vertical).lineLimit(3...6)
                Toggle("Sign Tag", isOn: $sign)
                if sign {
                    TextField("Signing Key (optional)", text: $key)
                    Text("Uses your existing Git GPG or SSH signing setup.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            ManagementFooter(title: "Create Tag", disabled: name.isEmpty || commit == nil || store.isBusy) {
                guard let hash = commit?.hash else { return }
                let name = name, message = message, annotated = annotated, sign = sign, key = key
                store.perform("Creating tag…") { try await $0.createTag(name, at: hash, message: message, annotated: annotated, sign: sign, signingKey: key) }; dismiss()
            }
        }.padding(24).frame(width: 540)
        .task(id: revision) { commit = nil; error = nil; do { let value = try await store.repository?.commit(at: revision); guard !Task.isCancelled else { return }; commit = value } catch { if !Task.isCancelled { self.error = error.localizedDescription } } }
    }
}

struct ReferenceEditSheet: View {
    enum Action { case rename, delete, upstream }
    let store: RepositoryStore
    let reference: Reference
    let action: Action
    @State private var name = ""
    @State private var force = false
    @Environment(\.dismiss) private var dismiss
    var noun: LocalizedStringResource { reference.isTag ? "Tag" : "Branch" }
    var title: LocalizedStringResource {
        switch action {
        case .upstream: "Track Upstream Branch"
        case .rename: reference.isTag ? "Rename Tag" : "Rename Branch"
        default: reference.isTag ? "Delete Tag" : "Delete Branch"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetTitle(title)
            LabeledContent(String(localized: noun), value: reference.name).textSelection(.enabled)
            LabeledContent("Object", value: String(reference.hash.prefix(12))).font(.system(size: 11, design: .monospaced))
            if action == .rename {
                TextField("New name", text: $name)
                if reference.isTag { Text("Preserves the tag object, annotation and signature. An annotated tag's embedded name is unchanged.").font(.caption).foregroundStyle(.secondary) }
            } else if action == .upstream {
                Picker("Track", selection: $name) {
                    Text("No Tracking").tag("")
                    ForEach((store.snapshot?.references ?? []).filter { !$0.isTag && $0.id != reference.id && !$0.name.hasSuffix("/HEAD") }) { Text($0.name).tag($0.fullName) }
                }
            } else {
                Text("The local reference will be removed. Its object is retained in Recover Deleted Items. Remote references are unaffected.").foregroundStyle(.secondary)
                if reference.isLocal { Toggle("Allow Deleting an Unmerged Branch", isOn: $force) }
            }
            ManagementFooter(title: action == .upstream ? "Set Tracking" : title, disabled: store.isBusy || (action == .rename && (name.isEmpty || name == reference.name)), destructive: action == .delete) {
                let name = name, force = force, ref = reference, action = action
                store.perform("\(title)…") { repository in
                    switch action {
                    case .rename: if ref.isTag { try await repository.renameTag(ref, to: name) } else { try await repository.renameBranch(ref, to: name) }
                    case .delete: if ref.isTag { try await repository.deleteTag(ref) } else { try await repository.deleteBranch(ref, force: force) }
                    case .upstream: try await repository.setUpstream(ref, to: name.isEmpty ? nil : name)
                    }
                }; dismiss()
            }
        }.padding(24).frame(width: 520)
        .onAppear {
            if action == .rename { name = reference.name }
            else if action == .upstream { name = store.snapshot?.references.first(where: { $0.name == reference.upstream })?.fullName ?? "" }
        }
    }
}

struct TagInformationSheet: View {
    let store: RepositoryStore
    let reference: Reference
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetTitle("\(reference.name)", icon: "tag")
            Text(reference.hash).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            if let repository = store.repository { SignatureVerificationView(repository: repository, revision: reference.hash, tag: true) }
            ScrollView { Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 680, height: 450)
        .task { guard let repository = store.repository else { return }; do { text = try await GitProcess.run(["cat-file", "-p", reference.hash], at: repository.root).text } catch { text = error.localizedDescription } }
    }
}

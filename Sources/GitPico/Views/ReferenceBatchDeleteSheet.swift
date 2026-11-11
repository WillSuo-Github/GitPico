import GitCore
import SwiftUI

struct ReferenceBatchDeleteSheet: View {
    let store: RepositoryStore
    let references: [Reference]
    let repositoryToken: UUID
    @State private var force = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle("Delete Selected References")
            Text("\(references.count) selected")
            List(references) { ref in
                LabeledContent {
                    Text(String(ref.hash.prefix(12))).monospaced().foregroundStyle(.secondary)
                } label: { Label(ref.name, systemImage: ref.isTag ? "tag" : "arrow.triangle.branch") }
            }.frame(height: min(300, CGFloat(references.count) * 28 + 20))
            Text("The local reference will be removed. Its object is retained in Recover Deleted Items. Remote references are unaffected.")
                .font(.callout).foregroundStyle(.secondary)
            if references.contains(where: \.isLocal) { Toggle("Allow Deleting Unmerged Branches", isOn: $force) }
            ManagementFooter(title: "Delete Selected References", disabled: store.isBusy || references.isEmpty || repositoryToken != store.repositoryToken, destructive: true) {
                store.deleteSidebarReferences(references, force: force, repositoryToken: repositoryToken)
                dismiss()
            }
        }.padding(24).frame(width: 560)
    }
}

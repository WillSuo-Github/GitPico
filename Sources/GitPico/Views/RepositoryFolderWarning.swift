import SwiftUI

struct RepositoryFolderWarning: View {
    let state: RepositoryFolderState
    var isSelected = false
    var selectedText: Color?
    @Environment(\.controlActiveState) private var activeState

    private var tint: Color {
        guard isSelected else { return .orange }
        return selectedText ?? Color(nsColor: activeState == .key ? .alternateSelectedControlTextColor : .unemphasizedSelectedTextColor)
    }

    var body: some View {
        if let warning = state.warning {
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(tint.opacity(0.14), in: Capsule())
                .fixedSize()
                .help("Locate Repository…")
        }
    }
}

private struct RepositoryFolderMonitoring: ViewModifier {
    let library: RepositoryLibrary

    func body(content: Content) -> some View {
        content.task(id: library.document.repositories.map(\.path)) {
            // Recheck while the chooser is visible, including deletion/restoration in Finder.
            while !Task.isCancelled {
                await library.refreshFolderStates()
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
            }
        }
    }
}

extension View {
    func monitoringRepositoryFolders(in library: RepositoryLibrary) -> some View {
        modifier(RepositoryFolderMonitoring(library: library))
    }
}

import GitCore
import SwiftUI

/// A compact tool group with separate targets for generation, scope and description.
struct CommitComposerTools: View {
    let isGenerating: Bool
    let canGenerate: Bool
    let aiHelp: String
    @Binding var scope: AICommitScope
    @Binding var showBody: Bool
    let hasDescription: Bool
    let generate: () -> Void

    private var descriptionActive: Bool { showBody || hasDescription }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: generate) {
                HStack(spacing: 4) {
                    if isGenerating {
                        ProgressView().controlSize(.mini).scaleEffect(0.75).frame(width: 12, height: 12)
                        Text("Stop")
                    } else {
                        Image(systemName: "sparkles").font(.system(size: 11, weight: .medium))
                        Text("AI")
                    }
                }.padding(.horizontal, 8)
            }
            .buttonStyle(CommitToolButtonStyle(tint: .accentColor))
            .disabled(!isGenerating && !canGenerate)
            .help(aiHelp)
            .accessibilityLabel(isGenerating ? "Stop generating commit message" : "Generate commit message with AI")

            Menu {
                Picker("AI", selection: $scope) {
                    Text("Staged").tag(AICommitScope.staged)
                    Text("Staged and unstaged changes").tag(AICommitScope.allChanges)
                }.pickerStyle(.inline).disabled(isGenerating)
                Divider()
                AISettingsButton()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 22)
            }
            .menuStyle(.button).menuIndicator(.hidden)
            .buttonStyle(CommitToolButtonStyle(tint: scope == .allChanges ? .accentColor : .secondary, selected: scope == .allChanges))
            .help(scope == .staged ? String(localized: "Staged") : String(localized: "Staged and unstaged changes"))
            .accessibilityLabel("AI")
            .accessibilityValue(scope == .staged ? String(localized: "Staged") : String(localized: "Staged and unstaged changes"))

            separator
            Button { showBody.toggle() } label: {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 11, weight: .medium)).frame(width: 28)
            }
            .buttonStyle(CommitToolButtonStyle(tint: descriptionActive ? .accentColor : .secondary, selected: descriptionActive))
            .help(showBody ? "Hide description" : "Add a description")
            .accessibilityLabel(showBody ? "Hide description" : "Add a description")
        }
        .font(.system(size: 11, weight: .semibold))
        .fixedSize()
        .background(Color.primary.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5).allowsHitTesting(false)
        }
    }

    private var separator: some View {
        Color.primary.opacity(0.10).frame(width: 0.5, height: 12)
    }
}

private struct CommitToolButtonStyle: ButtonStyle {
    var tint: Color
    var selected = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(height: 24)
            .foregroundStyle(isEnabled ? tint : Color.secondary.opacity(0.45))
            .contentShape(Rectangle())
            .background(tint.opacity(isEnabled ? (configuration.isPressed ? 0.20 : hovered ? 0.12 : selected ? 0.09 : 0) : 0))
            .onHover { hovered = $0 }
    }
}

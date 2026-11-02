import GitCore
import SwiftUI

/// AI and its options share a light surface; description remains an independent editor control.
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
        HStack(spacing: 6) {
            aiControls
            Button { showBody.toggle() } label: {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 12, weight: .regular)).frame(width: 24)
            }
            .buttonStyle(CommitToolButtonStyle(tint: descriptionActive ? .accentColor : .secondary))
            .help(showBody ? "Hide description" : "Add a description")
            .accessibilityLabel(showBody ? "Hide description" : "Add a description")
        }
        .font(.system(size: 11, weight: .medium))
        .fixedSize()
    }

    private var aiControls: some View {
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
                }.padding(.leading, 7).padding(.trailing, 3)
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
                    .frame(width: 20)
            }
            .menuStyle(.button).menuIndicator(.hidden)
            .buttonStyle(CommitToolButtonStyle(tint: .secondary))
            .help(scope == .staged ? String(localized: "Staged") : String(localized: "Staged and unstaged changes"))
            .accessibilityLabel("AI")
            .accessibilityValue(scope == .staged ? String(localized: "Staged") : String(localized: "Staged and unstaged changes"))
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

private struct CommitToolButtonStyle: ButtonStyle {
    var tint: Color
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(height: 24)
            .foregroundStyle(isEnabled ? tint : Color.secondary.opacity(0.65))
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(tint.opacity(isEnabled ? (configuration.isPressed ? 0.16 : hovered ? 0.08 : 0) : 0))
            }
            .onHover { hovered = $0 }
    }
}

import AppKit
import SwiftUI

struct RepositoryPickerRow: View {
    let entry: SavedRepository
    let isOpen: Bool
    let isSelected: Bool
    var isEmphasized = true
    var open: () -> Void
    @Environment(\.controlActiveState) private var activeState

    private var selectedText: Color {
        Color(nsColor: isEmphasized && activeState == .key ? .alternateSelectedControlTextColor : .unemphasizedSelectedTextColor)
    }
    var body: some View {
        HStack(spacing: 12) {
            RepositoryGlyph(name: entry.name, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSelected ? selectedText : .primary)
                    if entry.favorite {
                        Image(systemName: "star.fill").font(.system(size: 10))
                            .foregroundStyle(isSelected ? selectedText : .yellow)
                    }
                    if isOpen {
                        Text("Open").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isSelected ? selectedText : Color.accentColor)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(isSelected ? selectedText.opacity(0.18) : Color.accentColor.opacity(0.12), in: Capsule())
                            .overlay(Capsule().strokeBorder(isSelected ? selectedText.opacity(0.35) : .clear, lineWidth: 0.5))
                    }
                }
                Text(Pico.abbreviated(entry.path)).font(.system(size: 11))
                    .foregroundStyle(isSelected ? selectedText.opacity(0.9) : .secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let opened = entry.lastOpened {
                Text(opened.picoRelative).font(.system(size: 11))
                    .foregroundStyle(isSelected ? selectedText.opacity(0.85) : .secondary)
            }
            Button(action: open) {
                Image(systemName: "arrow.right.circle.fill").font(.system(size: 18))
                    .foregroundStyle(isSelected ? selectedText : Color.accentColor)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Open \(entry.name)").accessibilityLabel("Open \(entry.name)")
        }
        .padding(.vertical, 7).padding(.horizontal, 4)
    }
}

import AppKit
import GitCore
import SwiftUI

struct DiffLayoutPicker: View {
    @State private var preferences = AppPreferences.shared
    var body: some View {
        Picker("Diff layout", selection: $preferences.splitDiff) {
            Image(systemName: "rectangle").accessibilityLabel("Unified").tag(false)
            Image(systemName: "rectangle.split.2x1").accessibilityLabel("Side by Side").tag(true)
        }.pickerStyle(.segmented).labelsHidden().fixedSize().help("Unified / side-by-side diff")
    }
}

struct SplitDiffView: View {
    let lines: [DiffLine]
    let fontSize: Double
    var preparedRows: [SplitDiffRow]? = nil
    var selected: Set<Int> = []
    var select: ((DiffLine) -> Void)?
    var minimumWidth: CGFloat = 700
    var body: some View {
        let rows = preparedRows ?? SplitDiffRow.align(lines)
        HStack(alignment: .top, spacing: 0) {
            pane(rows, right: false)
            Rectangle().fill(.separator).frame(width: 1)
            pane(rows, right: true)
        }.frame(minWidth: minimumWidth)
    }
    func pane(_ rows: [SplitDiffRow], right: Bool) -> some View {
        ScrollView(.horizontal) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    let line = right ? row.right : row.left
                    HStack(spacing: 0) {
                        if let line, let select, line.kind == .addition || line.kind == .deletion {
                            LineSelectionButton(line: line, selected: selected.contains(line.id), action: { select(line) })
                        } else if select != nil { Color.clear.frame(width: 25, height: 19) }
                        Text((right ? line?.newNumber : line?.oldNumber).map(String.init) ?? "")
                            .foregroundStyle(gutterStyle(line)).frame(width: 42, alignment: .trailing).padding(.trailing, 10)
                        Text(line.map { $0.text.isEmpty ? " " : ($0.kind == .context || $0.kind == .addition || $0.kind == .deletion ? String($0.text.dropFirst()) : $0.text) } ?? " ")
                            .textSelection(.enabled).fixedSize().padding(.trailing, 16)
                        Spacer(minLength: 0)
                    }.font(.system(size: fontSize, design: .monospaced)).frame(height: 21)
                        .frame(minWidth: max(0, (minimumWidth - 1) / 2), alignment: .leading)
                        .background(background(line))
                        .overlay(alignment: .leading) { if let line, line.kind == .addition || line.kind == .deletion { Rectangle().fill(line.kind == .addition ? Pico.addition : Pico.deletion).frame(width: 2) } }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(width: max(0, (minimumWidth - 1) / 2), alignment: .leading)
    }
    func background(_ line: DiffLine?) -> Color {
        guard let line else { return Color.secondary.opacity(0.05) }
        if selected.contains(line.id) { return Color.accentColor.opacity(0.25) }
        return line.kind == .addition ? Pico.addition.opacity(0.12) : line.kind == .deletion ? Pico.deletion.opacity(0.12) : .clear
    }
    func gutterStyle(_ line: DiffLine?) -> AnyShapeStyle {
        guard let line else { return AnyShapeStyle(.tertiary) }
        return line.kind == .addition ? AnyShapeStyle(Pico.addition) : line.kind == .deletion ? AnyShapeStyle(Pico.deletion) : AnyShapeStyle(.tertiary)
    }
}

struct LineSelectionButton: View {
    let line: DiffLine
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: selected ? "checkmark.square.fill" : "square")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.55)).font(.system(size: 10)).frame(width: 25, height: 19)
        }.buttonStyle(.plain)
            .accessibilityLabel("\(selected ? "Deselect" : "Select") \(line.kind == .addition ? "added" : "deleted") line \(line.newNumber ?? line.oldNumber ?? 0)")
            .help("Select line; Shift-click selects a range")
    }
}

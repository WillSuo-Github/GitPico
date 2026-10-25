import AppKit
import GitCore
import SwiftUI

struct DiffView: View {
    let text: String
    let title: String?
    var subtitle: String = ""
    var isLoading = false
    var showsHeader = true
    @State private var preferences = AppPreferences.shared

    var body: some View {
        VStack(spacing: 0) {
            if let title, showsHeader {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                    Text(title).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    DiffLayoutPicker()
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    Button {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy diff")
                }.font(.system(size: 12)).padding(.horizontal, 15).frame(height: 42).background(.bar)
                Divider()
            }
            if isLoading {
                ProgressView("Loading changes…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if title == nil {
                EmptyPane(title: "No file selected", subtitle: "Select a file to inspect its changes.", icon: "doc")
            } else if text.isEmpty {
                EmptyPane(title: "No textual changes", subtitle: "This file may have only metadata or conflict changes.", icon: "doc.text.magnifyingglass")
            } else {
                let document = DiffDocument(text)
                if preferences.splitDiff {
                    GeometryReader { geometry in
                        ScrollView(.vertical) {
                            SplitDiffView(lines: document.lines, fontSize: preferences.diffFontSize, minimumWidth: geometry.size.width)
                            if document.isTruncated { Text("Preview limited to 8,000 lines.").font(.caption).foregroundStyle(.secondary).padding(12) }
                        }
                    }
                } else { GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(document.lines) { line in
                                DiffLineView(line: line, fontSize: preferences.diffFontSize).frame(minWidth: geometry.size.width, alignment: .leading)
                            }
                            if document.isTruncated {
                                Text("Preview limited to 8,000 lines. Copy the diff to inspect the complete output.")
                                    .font(.caption).foregroundStyle(.secondary).padding(14)
                            }
                        }
                        .padding(.vertical, 7)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                    }
                    .defaultScrollAnchor(.topLeading)
                } }
            }
        }.background(.background)
    }
}

struct DiffLineView: View {
    let line: DiffLine
    let fontSize: Double
    var tint: Color {
        switch line.kind {
        case .addition: .green
        case .deletion: .red
        case .hunk: .blue
        default: .clear
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "").foregroundStyle(.tertiary).frame(width: 41, alignment: .trailing).padding(.trailing, 8)
            Text(line.newNumber.map(String.init) ?? "").foregroundStyle(.tertiary).frame(width: 41, alignment: .trailing).padding(.trailing, 12)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .metadata ? Color.secondary : line.kind == .hunk ? Color.blue : Color.primary)
                .textSelection(.enabled).fixedSize(horizontal: true, vertical: true).padding(.trailing, 20)
            Spacer(minLength: 0)
        }
        .font(.system(size: fontSize, design: .monospaced)).padding(.vertical, 2)
        .background(tint.opacity(line.kind == .hunk ? 0.07 : 0.10))
    }
}

struct EmptyPane: View {
    let title: String
    let subtitle: String
    let icon: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 48, weight: .ultraLight)).foregroundStyle(.tertiary)
            Text(title).font(.title3).foregroundStyle(.secondary)
            Text(subtitle).font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

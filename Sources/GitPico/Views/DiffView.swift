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
                FileTitleBar(path: title, subtitle: subtitle) {
                    DiffLayoutPicker()
                    Button { Pico.copy(text) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy diff")
                }
            }
            if isLoading {
                ProgressView("Loading changes…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if title == nil {
                EmptyPane(title: String(localized: "No file selected"), subtitle: String(localized: "Select a file to inspect its changes."), icon: "doc")
            } else if text.isEmpty {
                EmptyPane(title: String(localized: "No textual changes"), subtitle: String(localized: "This file may have only metadata or conflict changes."), icon: "doc.text.magnifyingglass")
            } else {
                let document = DiffDocument(text)
                let lines = document.lines.filter { !$0.isFileHeader }
                if preferences.splitDiff {
                    GeometryReader { geometry in
                        ScrollView(.vertical) {
                            SplitDiffView(lines: lines, fontSize: preferences.diffFontSize, minimumWidth: geometry.size.width)
                            if document.isTruncated { Text("Preview limited to 8,000 lines.").font(.caption).foregroundStyle(.secondary).padding(12) }
                        }
                    }
                } else { GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(lines) { line in
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
        case .addition: Pico.addition
        case .deletion: Pico.deletion
        case .hunk: .accentColor
        default: .clear
        }
    }
    var isChange: Bool { line.kind == .addition || line.kind == .deletion }
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(spacing: 0) {
                Text(line.oldNumber.map(String.init) ?? "").frame(width: 38, alignment: .trailing).padding(.trailing, 6)
                Text(line.newNumber.map(String.init) ?? "").frame(width: 38, alignment: .trailing).padding(.trailing, 8)
            }
            .foregroundStyle(isChange ? AnyShapeStyle(tint.opacity(0.9)) : AnyShapeStyle(.tertiary))
            .background(tint.opacity(isChange ? 0.10 : 0))
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .metadata ? Color.secondary : line.kind == .hunk ? Color.accentColor.opacity(0.9) : Color.primary)
                .textSelection(.enabled).fixedSize(horizontal: true, vertical: true).padding(.leading, 10).padding(.trailing, 20)
            Spacer(minLength: 0)
        }
        .font(.system(size: fontSize, design: .monospaced)).padding(.vertical, 1.5)
        .background(tint.opacity(line.kind == .hunk ? 0.06 : 0.11))
        .overlay(alignment: .leading) { if isChange { Rectangle().fill(tint).frame(width: 2) } }
        .environment(\.layoutDirection, .leftToRight)
    }
}

extension DiffLine {
    /// Raw `diff --git` / `index` / `---` / `+++` lines repeat what the title bar already shows.
    var isFileHeader: Bool {
        kind == .metadata && (text.hasPrefix("diff --git ") || text.hasPrefix("index ") || text.hasPrefix("--- ") || text.hasPrefix("+++ "))
    }
}

/// File name first, folder second; trailing slot for per-view controls.
struct FileTitleBar<Trailing: View>: View {
    let path: String
    var subtitle: String = ""
    var status: String? = nil
    @ViewBuilder var trailing: Trailing
    var folder: String { (path as NSString).deletingLastPathComponent }
    var body: some View {
        HStack(spacing: 9) {
            if let status { StatusBadge(status: status) } else { Image(systemName: "doc.text").foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                let detail = [folder, subtitle].filter { !$0.isEmpty }.joined(separator: "  ·  ")
                if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
            }.help(path)
            Spacer(minLength: 8)
            trailing
        }
        .font(.system(size: 12)).padding(.horizontal, 14).frame(height: Pico.headerHeight)
        .background(.bar).overlay(alignment: .bottom) { Divider() }
    }
}

struct EmptyPane: View {
    let title: String
    let subtitle: String
    let icon: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 26, weight: .regular)).foregroundStyle(.tint)
                .frame(width: 64, height: 64)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).multilineTextAlignment(.center)
            if !subtitle.isEmpty { Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320) }
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

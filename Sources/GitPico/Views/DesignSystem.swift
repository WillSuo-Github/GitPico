import AppKit
import SwiftUI

/// Shared visual language: brand colors, metrics and small reusable pieces used across panes.
enum Pico {
    static let brandTop = Color(red: 1.0, green: 0.604, blue: 0.302)
    static let brandBottom = Color(red: 0.910, green: 0.212, blue: 0.310)
    static let brand = LinearGradient(colors: [brandTop, brandBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let addition = Color(red: 0.20, green: 0.66, blue: 0.36)
    static let deletion = Color(red: 0.90, green: 0.27, blue: 0.27)
    static let modified = Color(red: 0.23, green: 0.51, blue: 0.96)
    static let warning = Color(red: 0.82, green: 0.58, blue: 0.0)
    static let headerHeight: CGFloat = 46
    static let barHeight: CGFloat = 30
    static let corner: CGFloat = 10
    static let laneColors: [Color] = [Color(red: 0.95, green: 0.42, blue: 0.27), Color(red: 0.22, green: 0.55, blue: 0.95), Color(red: 0.20, green: 0.70, blue: 0.47), Color(red: 0.62, green: 0.40, blue: 0.93), Color(red: 0.95, green: 0.70, blue: 0.18), Color(red: 0.13, green: 0.68, blue: 0.75), Color(red: 0.91, green: 0.33, blue: 0.62)]

    /// Curated identity colors for avatars and repository glyphs.
    static let identityPalette: [Color] = [
        Color(red: 0.93, green: 0.42, blue: 0.29), Color(red: 0.95, green: 0.62, blue: 0.20), Color(red: 0.30, green: 0.69, blue: 0.42),
        Color(red: 0.13, green: 0.64, blue: 0.64), Color(red: 0.20, green: 0.60, blue: 0.86), Color(red: 0.33, green: 0.45, blue: 0.90),
        Color(red: 0.55, green: 0.40, blue: 0.88), Color(red: 0.80, green: 0.36, blue: 0.70), Color(red: 0.89, green: 0.33, blue: 0.47),
        Color(red: 0.45, green: 0.52, blue: 0.60)
    ]
    /// Stable across launches, unlike `hashValue` (FNV-1a).
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.lowercased().utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return hash
    }
    static func tint(for text: String) -> Color { identityPalette[Int(stableHash(text) % UInt64(identityPalette.count))] }
    static func monogram(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "." }).filter { !$0.isEmpty }
        let letters = words.count > 1 ? words.prefix(2).compactMap(\.first) : Array(name.prefix(2))
        return String(letters).uppercased()
    }
    static func abbreviated(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
    static func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}

/// Colored initials circle; the hue follows the author's name so people stay recognizable across views.
struct AuthorAvatar: View {
    let name: String
    var size: CGFloat = 28
    var body: some View {
        let tint = Pico.tint(for: name)
        Text(Pico.monogram(name))
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .top, endPoint: .bottom), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// Rounded-square monogram for repositories.
struct RepositoryGlyph: View {
    let name: String
    var size: CGFloat = 34
    var body: some View {
        let tint = Pico.tint(for: name)
        Text(Pico.monogram(name))
            .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [tint.opacity(0.8), tint], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// Small capsule label for refs, states and counts.
struct Chip: View {
    let text: String
    var icon: String? = nil
    var tint: Color = .secondary
    var monospaced = false
    var filled = false
    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).imageScale(.small) }
            Text(text).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 10, weight: .semibold, design: monospaced ? .monospaced : .default))
        .foregroundStyle(filled ? AnyShapeStyle(.white) : AnyShapeStyle(tint))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(filled ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.14)), in: Capsule())
    }
}

/// Monospaced hash that copies itself when clicked.
struct HashChip: View {
    let hash: String
    var length = 8
    @State private var copied = false
    var body: some View {
        Button {
            Pico.copy(hash); copied = true
            Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "number").imageScale(.small)
                Text(String(hash.prefix(length)))
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(copied ? Color.green : .secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain).help("Copy " + hash).accessibilityLabel("Copy hash " + hash)
    }
}

/// Uppercase caption used above grouped content.
struct SectionCaption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
    }
}

/// Proportional +/- bar with counts, like a pull-request file header.
struct DiffStat: View {
    let additions: Int
    let deletions: Int
    var showsBar = true
    var body: some View {
        HStack(spacing: 6) {
            if additions > 0 || deletions == 0 { Text("+\(additions)").foregroundStyle(Pico.addition) }
            if deletions > 0 { Text("−\(deletions)").foregroundStyle(Pico.deletion) }
            if showsBar {
                let total = max(additions + deletions, 1)
                let green = Int((Double(additions) / Double(total) * 5).rounded())
                HStack(spacing: 1.5) {
                    ForEach(0..<5, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1).fill(index < green ? Pico.addition : (additions + deletions == 0 ? Color.secondary.opacity(0.25) : Pico.deletion)).frame(width: 6, height: 6)
                    }
                }
            }
        }.font(.system(size: 10, weight: .medium, design: .monospaced)).fixedSize()
    }
}

/// Consistent pane header: icon, title, optional subtitle and trailing controls.
struct PaneBar<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(.tint).frame(width: 18) }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                if let subtitle, !subtitle.isEmpty { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14).frame(height: Pico.headerHeight)
        .background(.bar).overlay(alignment: .bottom) { Divider() }
    }
}
extension PaneBar where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, icon: String? = nil) {
        self.init(title: title, subtitle: subtitle, icon: icon) { EmptyView() }
    }
}

/// Rounded content group for detail panes.
struct CardBackground: ViewModifier {
    var padding: CGFloat = 14
    func body(content: Content) -> some View {
        content.padding(padding)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: Pico.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Pico.corner, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
    }
}
extension View {
    func card(padding: CGFloat = 14) -> some View { modifier(CardBackground(padding: padding)) }
}

/// Compact "label  value" row for metadata grids.
struct MetadataRow: View {
    let label: String
    let value: String
    var monospaced = false
    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value.isEmpty ? "—" : value).font(.system(size: 11, design: monospaced ? .monospaced : .default)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 11))
    }
}

extension Date {
    /// "3 hours ago" for recent dates; a short date beyond a week.
    var picoRelative: String {
        let interval = Date().timeIntervalSince(self)
        if interval >= 0, interval < 7 * 86_400 { return formatted(.relative(presentation: .named)) }
        return formatted(date: .abbreviated, time: .omitted)
    }
}

/// Full-width notice under the toolbar for in-progress operations and recoverable warnings.
struct NoticeBanner<Actions: View>: View {
    let icon: String
    let title: String
    var message: String? = nil
    var tint: Color = Pico.warning
    @ViewBuilder var actions: Actions
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 26, height: 26).background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                if let message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            actions
        }
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(tint.opacity(0.07))
        .overlay(alignment: .bottom) { Rectangle().fill(tint.opacity(0.25)).frame(height: 0.5) }
    }
}

/// Sheet and pane title with a tinted symbol; the symbol is inferred from the title when not given.
struct SheetTitle: View {
    let title: String
    var icon: String? = nil
    init(_ title: String, icon: String? = nil) { self.title = title; self.icon = icon }
    var symbol: String {
        if let icon { return icon }
        let text = title.lowercased()
        let rules: [(String, String)] = [
            ("discard", "trash"), ("delete", "trash"), ("remove", "trash"), ("clear", "trash"),
            ("recover", "arrow.uturn.backward.circle"), ("undo", "arrow.uturn.backward.circle"), ("redo", "arrow.uturn.forward.circle"), ("restore", "clock.arrow.circlepath"),
            ("stash", "tray.and.arrow.down"), ("snapshot", "camera.aperture"),
            ("tag", "tag"), ("clone", "arrow.down.circle"), ("create git repository", "plus.square.dashed"),
            ("fetch", "arrow.down.circle"), ("push", "arrow.up.circle"), ("publish", "arrow.up.circle"), ("remote", "cloud"),
            ("merge", "arrow.triangle.merge"), ("rebase", "arrow.triangle.swap"), ("cherry", "arrow.right.doc.on.clipboard"), ("revert", "arrow.uturn.backward"),
            ("branch", "arrow.triangle.branch"), ("upstream", "arrow.triangle.branch"), ("track", "arrow.triangle.branch"),
            ("patch", "doc.badge.plus"), ("export", "square.and.arrow.up"), ("archive", "doc.zipper"), ("save", "square.and.arrow.down"),
            ("worktree", "folder.badge.gearshape"), ("submodule", "shippingbox"), ("lfs", "externaldrive"), ("flow", "arrow.triangle.branch"),
            ("external", "arrow.left.arrow.right.square"), ("file", "doc.text"), ("repositor", "square.stack"), ("rename", "pencil"), ("amend", "pencil")
        ]
        return rules.first { text.contains($0.0) }?.1 ?? "sparkles"
    }
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(.tint)
                .frame(width: 34, height: 34).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(title).font(.system(size: 19, weight: .bold, design: .rounded)).lineLimit(2)
        }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }
}

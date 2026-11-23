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

@MainActor enum DiffLayoutMetrics {
    private static var characterWidths: [Double: CGFloat] = [:]

    static func monospaceCharacterWidth(fontSize: Double) -> CGFloat {
        if let cached = characterWidths[fontSize] { return cached }
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let measured = ceil(("0" as NSString).size(withAttributes: [.font: font]).width * 10) / 10
        let width = max(5, measured)
        characterWidths[fontSize] = width
        return width
    }

    static func splitRowHeight(fontSize: Double) -> CGFloat {
        max(21, ceil(fontSize * 1.65))
    }

    static func unifiedRowHeight(fontSize: Double) -> CGFloat {
        max(21, ceil(fontSize * 1.65))
    }

    static func unifiedContentWidth(columns: Int, fontSize: Double, selectable: Bool, minimumWidth: CGFloat) -> CGFloat {
        let gutter: CGFloat = (selectable ? 25 : 0) + 90 + 40
        let estimated = gutter + CGFloat(columns) * monospaceCharacterWidth(fontSize: fontSize)
        return max(minimumWidth, estimated)
    }

    static func splitLayout(
        leftColumns: Int,
        rightColumns: Int,
        fontSize: Double,
        selectable: Bool,
        totalWidth: CGFloat
    ) -> (halfWidth: CGFloat, gutterWidth: CGFloat, maxLeftOffset: CGFloat, maxRightOffset: CGFloat) {
        let halfWidth = floor(max(0, (totalWidth - 1) / 2))
        let gutterWidth: CGFloat = (selectable ? 25 : 0) + 52
        let codeViewportWidth = max(0, halfWidth - gutterWidth)
        let charWidth = monospaceCharacterWidth(fontSize: fontSize)
        let leftContentWidth = CGFloat(leftColumns) * charWidth + 24
        let rightContentWidth = CGFloat(rightColumns) * charWidth + 24
        return (
            halfWidth: halfWidth,
            gutterWidth: gutterWidth,
            maxLeftOffset: max(0, leftContentWidth - codeViewportWidth),
            maxRightOffset: max(0, rightContentWidth - codeViewportWidth)
        )
    }

    static func rawFallbackPreview(_ text: String, limit: Int = 16_384) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n…"
    }
}

@Observable @MainActor final class UnifiedHorizontalScrollState {
    var offsetX: CGFloat = 0
}

struct PinnedHorizontalBar<Content: View>: View {
    let scrollState: UnifiedHorizontalScrollState
    let viewportWidth: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(width: viewportWidth, alignment: .leading)
            .offset(x: scrollState.offsetX)
    }
}

@Observable @MainActor final class SplitHorizontalScrollState {
    var leftOffset: CGFloat = 0
    var rightOffset: CGFloat = 0
    var leftFlashCount = 0
    var rightFlashCount = 0
    @ObservationIgnored var maxLeftOffset: CGFloat = 0
    @ObservationIgnored var maxRightOffset: CGFloat = 0

    func reset() {
        if leftOffset != 0 { leftOffset = 0 }
        if rightOffset != 0 { rightOffset = 0 }
    }

    func syncLimits(left: CGFloat, right: CGFloat) {
        maxLeftOffset = left
        maxRightOffset = right
        let clampedLeft = min(left, max(0, leftOffset))
        let clampedRight = min(right, max(0, rightOffset))
        if abs(leftOffset - clampedLeft) > 0.5 || abs(rightOffset - clampedRight) > 0.5 {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let targetLeft = min(self.maxLeftOffset, max(0, self.leftOffset))
                let targetRight = min(self.maxRightOffset, max(0, self.rightOffset))
                if abs(self.leftOffset - targetLeft) > 0.5 { self.leftOffset = targetLeft }
                if abs(self.rightOffset - targetRight) > 0.5 { self.rightOffset = targetRight }
            }
        }
    }

    func scrollBy(deltaX: CGFloat, isRight: Bool) -> Bool {
        let maxOffset = isRight ? maxRightOffset : maxLeftOffset
        guard maxOffset > 0 else { return false }
        let current = isRight ? rightOffset : leftOffset
        let next = min(maxOffset, max(0, current - deltaX))
        guard abs(next - current) > 0.01 else { return false }
        if isRight {
            rightOffset = next
            rightFlashCount += 1
        } else {
            leftOffset = next
            leftFlashCount += 1
        }
        return true
    }

    func setOffset(_ offset: CGFloat, isRight: Bool) {
        let maxOffset = isRight ? maxRightOffset : maxLeftOffset
        let clamped = min(maxOffset, max(0, offset))
        if isRight {
            if abs(rightOffset - clamped) > 0.25 { rightOffset = clamped }
        } else {
            if abs(leftOffset - clamped) > 0.25 { leftOffset = clamped }
        }
    }
}

/// Virtualized single row for side-by-side comparison. Placed directly inside a vertical LazyVStack
/// so off-screen rows are never materialized.
struct SplitDiffRowView: View, Equatable {
    let row: SplitDiffRow
    let fontSize: Double
    let halfWidth: CGFloat
    let rowHeight: CGFloat
    let leftCode: DiffCodeLine?
    let rightCode: DiffCodeLine?
    let leftSelected: Bool
    let rightSelected: Bool
    let leftFocused: Bool
    let rightFocused: Bool
    let leftQuery: String
    let rightQuery: String
    let showsSelectionSlot: Bool
    let scrollState: SplitHorizontalScrollState
    let select: ((DiffLine) -> Void)?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row &&
        lhs.fontSize == rhs.fontSize &&
        lhs.halfWidth == rhs.halfWidth &&
        lhs.rowHeight == rhs.rowHeight &&
        lhs.leftCode == rhs.leftCode &&
        lhs.rightCode == rhs.rightCode &&
        lhs.leftSelected == rhs.leftSelected &&
        lhs.rightSelected == rhs.rightSelected &&
        lhs.leftFocused == rhs.leftFocused &&
        lhs.rightFocused == rhs.rightFocused &&
        lhs.leftQuery == rhs.leftQuery &&
        lhs.rightQuery == rhs.rightQuery &&
        lhs.showsSelectionSlot == rhs.showsSelectionSlot &&
        lhs.scrollState === rhs.scrollState
    }

    var body: some View {
        HStack(spacing: 0) {
            SplitDiffSideCell(
                line: row.left,
                right: false,
                fontSize: fontSize,
                width: halfWidth,
                height: rowHeight,
                code: leftCode,
                selected: leftSelected,
                focused: leftFocused,
                query: leftQuery,
                showsSelectionSlot: showsSelectionSlot,
                scrollState: scrollState,
                select: select
            )
            Rectangle().fill(.separator).frame(width: 1, height: rowHeight)
            SplitDiffSideCell(
                line: row.right,
                right: true,
                fontSize: fontSize,
                width: halfWidth,
                height: rowHeight,
                code: rightCode,
                selected: rightSelected,
                focused: rightFocused,
                query: rightQuery,
                showsSelectionSlot: showsSelectionSlot,
                scrollState: scrollState,
                select: select
            )
        }
        .frame(height: rowHeight)
        .environment(\.layoutDirection, .leftToRight)
    }
}

private struct SplitDiffSideCell: View {
    let line: DiffLine?
    let right: Bool
    let fontSize: Double
    let width: CGFloat
    let height: CGFloat
    let code: DiffCodeLine?
    let selected: Bool
    let focused: Bool
    let query: String
    let showsSelectionSlot: Bool
    let scrollState: SplitHorizontalScrollState
    let select: ((DiffLine) -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            if let line, let select, showsSelectionSlot, line.kind == .addition || line.kind == .deletion {
                LineSelectionButton(line: line, selected: selected, action: { select(line) })
            } else if showsSelectionSlot {
                Color.clear.frame(width: 25, height: 19)
            }
            Text((right ? line?.newNumber : line?.oldNumber).map(String.init) ?? "")
                .foregroundStyle(gutterStyle(line))
                .frame(width: 42, alignment: .trailing)
                .padding(.trailing, 10)
            if let line {
                let resolved = code ?? DiffCodeLine(source: CodeHighlighting.source(line), path: "")
                SplitCodeViewport(line: resolved, query: query, scrollState: scrollState, isRight: right)
            } else {
                Text(" ")
                    .padding(.trailing, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: fontSize, design: .monospaced))
        .frame(width: width, height: height, alignment: .leading)
        .background(background(line))
        .overlay {
            if focused { Rectangle().strokeBorder(Color.accentColor, lineWidth: 1) }
        }
        .overlay(alignment: .leading) {
            if let line, line.kind == .addition || line.kind == .deletion {
                Rectangle().fill(line.kind == .addition ? Pico.addition : Pico.deletion).frame(width: 2)
            }
        }
    }

    private func background(_ line: DiffLine?) -> Color {
        guard let line else { return Color.secondary.opacity(0.05) }
        if selected { return Color.accentColor.opacity(0.25) }
        return line.kind == .addition ? Pico.addition.opacity(0.12) : line.kind == .deletion ? Pico.deletion.opacity(0.12) : .clear
    }

    private func gutterStyle(_ line: DiffLine?) -> AnyShapeStyle {
        guard let line else { return AnyShapeStyle(.tertiary) }
        return line.kind == .addition ? AnyShapeStyle(Pico.addition) : line.kind == .deletion ? AnyShapeStyle(Pico.deletion) : AnyShapeStyle(.tertiary)
    }
}

private struct SplitCodeViewport: View {
    let line: DiffCodeLine
    let query: String
    let scrollState: SplitHorizontalScrollState
    let isRight: Bool

    var body: some View {
        let offset = isRight ? scrollState.rightOffset : scrollState.leftOffset
        DiffCodeText(line: line, query: query)
            .equatable()
            .padding(.trailing, 16)
            .offset(x: -offset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
    }
}

struct UnifiedDiffLineRow: View, Equatable {
    let line: DiffLine
    let fontSize: Double
    let code: DiffCodeLine?
    let query: String
    let selected: Bool
    let focused: Bool
    let showsSelectionSlot: Bool
    let minimumWidth: CGFloat
    let select: (() -> Void)?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.line == rhs.line &&
        lhs.fontSize == rhs.fontSize &&
        lhs.code == rhs.code &&
        lhs.query == rhs.query &&
        lhs.selected == rhs.selected &&
        lhs.focused == rhs.focused &&
        lhs.showsSelectionSlot == rhs.showsSelectionSlot &&
        lhs.minimumWidth == rhs.minimumWidth
    }

    var body: some View {
        HStack(spacing: 0) {
            if showsSelectionSlot, let select, line.kind == .addition || line.kind == .deletion {
                LineSelectionButton(line: line, selected: selected, action: select)
            } else if showsSelectionSlot {
                Color.clear.frame(width: 25)
            }
            DiffLineView(line: line, fontSize: fontSize, code: code, query: query).equatable()
        }
        .frame(minWidth: minimumWidth, alignment: .leading)
        .overlay { if focused { Rectangle().strokeBorder(Color.accentColor, lineWidth: 1) } }
        .background(selected ? Color.accentColor.opacity(0.23) : .clear)
        .environment(\.layoutDirection, .leftToRight)
    }
}

struct SplitHorizontalWheelBridge: NSViewRepresentable {
    let scrollState: SplitHorizontalScrollState
    let maxLeftOffset: CGFloat
    let maxRightOffset: CGFloat

    func makeNSView(context: Context) -> WheelMonitorView {
        let view = WheelMonitorView()
        view.scrollState = scrollState
        scrollState.syncLimits(left: maxLeftOffset, right: maxRightOffset)
        return view
    }

    func updateNSView(_ view: WheelMonitorView, context: Context) {
        view.scrollState = scrollState
        scrollState.syncLimits(left: maxLeftOffset, right: maxRightOffset)
    }

    static func dismantleNSView(_ view: WheelMonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class WheelMonitorView: NSView {
        weak var scrollState: SplitHorizontalScrollState?
        nonisolated(unsafe) private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { startMonitoring() }
            else { stopMonitoring() }
        }

        private func startMonitoring() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, window.isVisible, event.window === window else { return event }
                let deltaX = event.scrollingDeltaX
                let deltaY = event.scrollingDeltaY
                guard deltaX != 0, abs(deltaX) > abs(deltaY) else { return event }
                let local = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(local) else { return event }
                let isRight = local.x >= self.bounds.midX
                let scaledDelta = event.hasPreciseScrollingDeltas ? deltaX : deltaX * 24
                if self.scrollState?.scrollBy(deltaX: scaledDelta, isRight: isRight) == true {
                    return nil
                }
                return event
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

struct SplitHorizontalScrollbarOverlay: View {
    let scrollState: SplitHorizontalScrollState
    let halfWidth: CGFloat
    let gutterWidth: CGFloat
    let maxLeftOffset: CGFloat
    let maxRightOffset: CGFloat
    let bottomInset: CGFloat

    var body: some View {
        if maxLeftOffset > 0 || maxRightOffset > 0 {
            let barHeight = max(12, NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay))
            let codeWidth = max(0, halfWidth - gutterWidth)
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: gutterWidth)
                    if maxLeftOffset > 0 {
                        NativeHorizontalScrollbar(
                            offset: scrollState.leftOffset,
                            maxOffset: maxLeftOffset,
                            viewportWidth: codeWidth,
                            flashCount: scrollState.leftFlashCount
                        ) { scrollState.setOffset($0, isRight: false) }
                    } else {
                        Color.clear
                    }
                }.frame(width: halfWidth)
                Color.clear.frame(width: 1)
                HStack(spacing: 0) {
                    Color.clear.frame(width: gutterWidth)
                    if maxRightOffset > 0 {
                        NativeHorizontalScrollbar(
                            offset: scrollState.rightOffset,
                            maxOffset: maxRightOffset,
                            viewportWidth: codeWidth,
                            flashCount: scrollState.rightFlashCount
                        ) { scrollState.setOffset($0, isRight: true) }
                    } else {
                        Color.clear
                    }
                }.frame(width: halfWidth)
            }
            .frame(height: barHeight)
            .padding(.bottom, bottomInset)
            .environment(\.layoutDirection, .leftToRight)
        }
    }
}

private struct NativeHorizontalScrollbar: NSViewRepresentable {
    let offset: CGFloat
    let maxOffset: CGFloat
    let viewportWidth: CGFloat
    let flashCount: Int
    let onChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let document = NSView(frame: NSRect(x: 0, y: 0, width: max(1, viewportWidth + maxOffset), height: 1))
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observe(scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.sync(scroll: scroll, offset: offset, contentWidth: max(1, viewportWidth + maxOffset), flashCount: flashCount)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    @MainActor final class Coordinator: NSObject {
        var onChange: (CGFloat) -> Void
        private var isSyncing = false
        private var lastFlashCount = 0
        nonisolated(unsafe) private var observer: NSObjectProtocol?

        init(onChange: @escaping (CGFloat) -> Void) {
            self.onChange = onChange
        }

        func observe(_ scroll: NSScrollView) {
            stopObserving()
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView,
                queue: .main
            ) { [weak self, weak scroll] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isSyncing, let scroll else { return }
                    self.onChange(scroll.contentView.bounds.origin.x)
                }
            }
        }

        func sync(scroll: NSScrollView, offset: CGFloat, contentWidth: CGFloat, flashCount: Int) {
            isSyncing = true
            defer { isSyncing = false }
            if let document = scroll.documentView, abs(document.frame.width - contentWidth) > 0.5 {
                document.setFrameSize(NSSize(width: contentWidth, height: 1))
            }
            if abs(scroll.contentView.bounds.origin.x - offset) > 0.25 {
                scroll.contentView.scroll(to: NSPoint(x: offset, y: 0))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            if flashCount != lastFlashCount {
                lastFlashCount = flashCount
                scroll.flashScrollers()
            }
        }

        func stopObserving() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
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
            .accessibilityLabel(accessibilityTitle(selected: selected, addition: line.kind == .addition, number: line.newNumber ?? line.oldNumber ?? 0))
            .help("Select line; Shift-click selects a range")
    }
    private func accessibilityTitle(selected: Bool, addition: Bool, number: Int) -> String {
        switch (selected, addition) {
        case (true, true): String(localized: "Deselect added line \(number)")
        case (true, false): String(localized: "Deselect deleted line \(number)")
        case (false, true): String(localized: "Select added line \(number)")
        case (false, false): String(localized: "Select deleted line \(number)")
        }
    }
}

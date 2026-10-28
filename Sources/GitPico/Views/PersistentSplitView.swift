import AppKit
import SwiftUI

// Explicit SwiftUI geometry keeps the content-list width stable as its selection changes.
struct PersistentSplitView<Leading: View, Trailing: View>: View {
    let name: String
    let leading: Leading
    let trailing: Trailing
    let minimum: CGFloat
    @State private var columnWidth: CGFloat
    @State private var dragStart: CGFloat?
    @GestureState private var isResizing = false
    @Namespace private var splitCoordinates
    @Environment(\.layoutDirection) private var layoutDirection

    init(name: String, width: CGFloat = 320, minimum: CGFloat = 270, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.name = name
        self.leading = leading()
        self.trailing = trailing()
        self.minimum = minimum
        _columnWidth = State(initialValue: AppPreferences.shared.width(for: "layout." + name) ?? width)
    }

    var body: some View {
        GeometryReader { geometry in
            let actual = min(max(columnWidth, minimum), max(minimum, geometry.size.width - 350))
            HStack(spacing: 0) {
                leading.frame(width: actual, height: geometry.size.height)
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
                    .overlay {
                        Color.clear.frame(width: 9).contentShape(Rectangle())
                            .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(splitCoordinates))
                                .updating($isResizing) { _, resizing, transaction in
                                    resizing = true; transaction.animation = nil
                                }
                                .onChanged { value in
                                    if dragStart == nil { dragStart = actual }
                                    columnWidth = splitColumnWidth(start: dragStart ?? actual, translation: value.translation.width, minimum: minimum, availableWidth: geometry.size.width, direction: layoutDirection)
                                }
                                .onEnded { _ in AppPreferences.shared.setWidth(columnWidth, for: "layout." + name); dragStart = nil })
                    }
                    .accessibilityLabel("Content list divider")
                    .accessibilityValue("\(Int(actual)) points")
                    .accessibilityAdjustableAction { direction in
                        columnWidth = min(max(actual + (direction == .increment ? 20 : -20), minimum), max(minimum, geometry.size.width - 350))
                        AppPreferences.shared.setWidth(columnWidth, for: "layout." + name)
                    }
                trailing.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // The divider moves during a drag; its own local coordinates cannot anchor translation.
        .coordinateSpace(name: splitCoordinates)
        .onChange(of: isResizing) { _, resizing in if !resizing { dragStart = nil } }
    }
}

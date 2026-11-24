import SwiftUI

/// The scroll viewport fills the pane. Insets keep the first and last rows
/// reachable while allowing intermediate rows to travel under the fixed bars.
struct PinnedScrollPane<Content: View, Top: View, Bottom: View>: View {
    var bottomIsFloating = false
    @ViewBuilder let content: (EdgeInsets) -> Content
    @ViewBuilder let top: () -> Top
    @ViewBuilder let bottom: () -> Bottom
    @Environment(\.repositoryStatusBarInset) private var statusBarInset
    @State private var topHeight: CGFloat = 0
    @State private var bottomHeight: CGFloat = 0

    var body: some View {
        let insets = EdgeInsets(top: topHeight, leading: 0, bottom: bottomHeight + statusBarInset, trailing: 0)
        content(insets)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                PinnedScrollBar(edge: .top, height: $topHeight, content: top)
            }
            .overlay(alignment: .bottom) {
                PinnedScrollBar(edge: .bottom, height: $bottomHeight, coveredBottom: statusBarInset, isFloating: bottomIsFloating, content: bottom)
            }
            // Nested previews have their own viewport within this pane.
            .environment(\.repositoryStatusBarInset, 0)
            .clipped()
    }
}

extension PinnedScrollPane where Bottom == EmptyView {
    init(@ViewBuilder content: @escaping (EdgeInsets) -> Content, @ViewBuilder top: @escaping () -> Top) {
        self.init(content: content, top: top, bottom: { EmptyView() })
    }
}

extension View {
    /// Apply to the actual SwiftUI List or ScrollView so the insets belong to that scroller.
    func pinnedScrollInsets(_ insets: EdgeInsets) -> some View {
        safeAreaPadding(insets)
            .scrollEdgeEffectHidden(true, for: .vertical)
    }
}

private struct PinnedScrollBar<Content: View>: View {
    let edge: VerticalEdge
    @Binding var height: CGFloat
    var coveredBottom: CGFloat = 0
    var isFloating = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        let overlap = height > 0 ? coveredBottom : 0
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = $0 }
            .background {
                if !isFloating {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {}
                        .accessibilityHidden(true)
                }
            }
            .padding(.bottom, overlap)
            .background {
                if !isFloating { ScrollBarBackdrop(edge: edge, coveredBottom: overlap) }
            }
    }
}

struct ScrollBarBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let edge: VerticalEdge
    var tint: Color = .clear
    var coveredBottom: CGFloat = 0
    var showsWindowSurface = true

    static let topBlurRadius: CGFloat = 10
    static let bottomBlurRadius: CGFloat = 10
    static let tintOpacity: Double = 0.90
    static let maxTransitionHeight: CGFloat = 48

    private var blurDirection: VariableBlurDirection {
        edge == .top ? .blurredTopClearBottom : .blurredBottomClearTop
    }

    private var blurRadius: CGFloat {
        edge == .top ? Self.topBlurRadius : Self.bottomBlurRadius
    }

    private func tintGradient(barHeight: CGFloat, transition: CGFloat) -> LinearGradient {
        let safeHeight = max(1, barHeight)
        let fadeFraction = min(1, transition / safeHeight)
        let solidEnd = max(0, 1 - fadeFraction)
        let alpha = Self.tintOpacity
        var stops: [Gradient.Stop] = [.init(color: .white.opacity(alpha), location: 0)]
        if solidEnd > 0 {
            stops.append(.init(color: .white.opacity(alpha), location: solidEnd))
        }
        stops.append(contentsOf: [
            .init(color: .white.opacity(alpha * 0.90), location: solidEnd + fadeFraction * 0.28),
            .init(color: .white.opacity(alpha * 0.64), location: solidEnd + fadeFraction * 0.52),
            .init(color: .white.opacity(alpha * 0.31), location: solidEnd + fadeFraction * 0.74),
            .init(color: .white.opacity(alpha * 0.08), location: solidEnd + fadeFraction * 0.90),
            .init(color: .clear, location: 1)
        ])
        return LinearGradient(
            gradient: Gradient(stops: stops),
            startPoint: edge == .top ? .top : .bottom,
            endPoint: edge == .top ? .bottom : .top
        )
    }

    private func tintMask(barHeight: CGFloat, transition: CGFloat) -> some View {
        VStack(spacing: 0) {
            tintGradient(barHeight: barHeight, transition: transition)
            // Continue the footer surface underneath the window status bar so
            // rows do not reappear at the junction between the two backgrounds.
            if coveredBottom > 0 {
                Color.white.opacity(Self.tintOpacity).frame(height: coveredBottom)
            }
        }
    }

    var body: some View {
        // The same surface runs through both edges so the fade adds no color over an empty pane.
        GeometryReader { geometry in
            let barHeight = max(0, geometry.size.height - coveredBottom)
            let transition = min(barHeight, Self.maxTransitionHeight)
            ZStack {
                if !reduceTransparency, barHeight > 0 {
                    VariableBlurView(
                        maxBlurRadius: blurRadius,
                        direction: blurDirection,
                        transitionHeight: transition
                    )
                }
                if showsWindowSurface {
                    Rectangle().fill(.windowBackground)
                        .background(.background)
                        .compositingGroup()
                        .overlay { tint }
                        .mask {
                            if reduceTransparency { Rectangle() }
                            else { tintMask(barHeight: barHeight, transition: transition) }
                        }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension EnvironmentValues {
    @Entry var repositoryStatusBarInset: CGFloat = 0
}

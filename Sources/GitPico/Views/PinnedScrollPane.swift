import SwiftUI
import Variablur

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
    @Namespace private var viewport

    var body: some View {
        let insets = EdgeInsets(top: topHeight, leading: 0, bottom: bottomHeight + statusBarInset, trailing: 0)
        let bottomBackdropHeight = bottomIsFloating ? 0 : bottomHeight
        content(insets)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.pinnedScrollEdges, PinnedScrollEdges(viewport: .named(viewport), top: topHeight, bottom: bottomBackdropHeight, statusBar: statusBarInset))
            .overlay(alignment: .top) {
                PinnedScrollBar(edge: .top, height: $topHeight, content: top)
            }
            .overlay(alignment: .bottom) {
                PinnedScrollBar(edge: .bottom, height: $bottomHeight, coveredBottom: statusBarInset, isFloating: bottomIsFloating, content: bottom)
            }
            // Nested previews have their own viewport within this pane.
            .environment(\.repositoryStatusBarInset, 0)
            .coordinateSpace(.named(viewport))
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

    /// Apply to individual SwiftUI rows so the content softens as it crosses the fade.
    func progressiveScrollBlur() -> some View {
        modifier(ProgressiveScrollBlur())
    }

    func progressiveScrollBlurViewport(_ viewport: CGRect, top: CGFloat, bottom: CGFloat) -> some View {
        environment(\.pinnedScrollEdges, PinnedScrollEdges(viewport: .global(viewport), top: top, bottom: bottom, statusBar: 0))
    }

    func sidebarScrollBlur() -> some View {
        modifier(SidebarScrollBlur())
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
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PinnedScrollEdges: Sendable {
    static let radius: CGFloat = 14
    private static let topGradient = Gradient(stops: [
        .init(color: .white, location: 0),
        .init(color: .white.opacity(0.98), location: 0.22),
        .init(color: .white.opacity(0.93), location: 0.38),
        .init(color: .white.opacity(0.87), location: 0.50),
        .init(color: .white.opacity(0.70), location: 0.65),
        .init(color: .white.opacity(0.40), location: 0.80),
        .init(color: .white.opacity(0.09), location: 0.94),
        .init(color: .clear, location: 1)
    ])
    private static let bottomGradient = Gradient(stops: [
        .init(color: .white, location: 0),
        .init(color: .white.opacity(0.99), location: 0.35),
        .init(color: .white.opacity(0.94), location: 0.55),
        .init(color: .white.opacity(0.80), location: 0.68),
        .init(color: .white.opacity(0.52), location: 0.82),
        .init(color: .white.opacity(0.23), location: 0.93),
        .init(color: .clear, location: 1)
    ])

    static func gradient(for edge: VerticalEdge) -> Gradient { edge == .top ? topGradient : bottomGradient }

    enum Viewport: Sendable {
        case named(Namespace.ID)
        case global(CGRect)
    }

    let viewport: Viewport
    let top: CGFloat
    let bottom: CGFloat
    let statusBar: CGFloat
}

extension EnvironmentValues {
    @Entry var repositoryStatusBarInset: CGFloat = 0
}

private extension EnvironmentValues {
    @Entry var pinnedScrollEdges: PinnedScrollEdges? = nil
}

private struct SidebarScrollBlur: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.pinnedScrollEdges) private var edges
    @State private var overlapsBar = false

    func body(content: Content) -> some View {
        if !reduceTransparency, let edges, case .global(let viewport) = edges.viewport, !viewport.isEmpty {
            // Blend a faint source with the shader so detail stays visible under the glass.
            content
                .opacity(overlapsBar ? 0.42 : 1)
                .overlay {
                    if overlapsBar {
                        content.drawingGroup().progressiveScrollBlur()
                            .opacity(0.84)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .onGeometryChange(for: Bool.self, of: { geometry in
                    let frame = geometry.frame(in: .global)
                    return frame.intersects(viewport) &&
                        (frame.minY < viewport.minY + edges.top || frame.maxY > viewport.maxY - edges.bottom)
                }) { overlapsBar = $0 }
        } else {
            content
        }
    }
}

private struct ProgressiveScrollBlur: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.pinnedScrollEdges) private var edges
    nonisolated private static let emptyMask = Image(size: CGSize(width: 1, height: 1)) { _ in }

    func body(content: Content) -> some View {
        if let edges, !reduceTransparency {
            let bleed = PinnedScrollEdges.radius * 3
            content.padding(bleed)
                .visualEffect { effect, geometry in
                    let frame: CGRect
                    let viewportHeight: CGFloat
                    switch edges.viewport {
                    case .named(let space):
                        frame = geometry.frame(in: .named(space))
                        viewportHeight = geometry.bounds(of: .named(space))?.height ?? 0
                    case .global(let viewport):
                        frame = geometry.frame(in: .global).offsetBy(dx: -viewport.minX, dy: -viewport.minY)
                        viewportHeight = viewport.height
                    }
                    let footerHeight = edges.bottom > 0 ? edges.bottom : edges.statusBar
                    let footerStart = viewportHeight - edges.statusBar - edges.bottom
                    let footerEnd = footerStart + footerHeight
                    let blurTop = edges.top > 0 && frame.minY < edges.top && frame.maxY > 0
                    let blurFooter = footerHeight > 0 && frame.maxY > footerStart && frame.minY < footerEnd
                    let enabled = viewportHeight > 0 && (blurTop || blurFooter)
                    let mask = enabled
                        ? Image(size: geometry.size) { context in
                            let bounds = Path(CGRect(origin: .zero, size: geometry.size))
                            if blurTop {
                                fill(context, bounds: bounds, edge: .top, blurredAt: -frame.minY, clearAt: edges.top - frame.minY)
                            }
                            if blurFooter {
                                fill(context, bounds: bounds, edge: .bottom, blurredAt: footerEnd - frame.minY, clearAt: footerStart - frame.minY)
                            }
                        }
                        : Self.emptyMask
                    return effect.variableBlur(radius: PinnedScrollEdges.radius, mask: mask, isEnabled: enabled)
                }
                .padding(-bleed)
        } else {
            content
        }
    }

    private nonisolated func fill(_ context: GraphicsContext, bounds: Path, edge: VerticalEdge, blurredAt outer: CGFloat, clearAt inner: CGFloat) {
        let range = CGRect(x: 0, y: min(outer, inner), width: bounds.boundingRect.width, height: abs(outer - inner))
        context.fill(Path(bounds.boundingRect.intersection(range)), with: .linearGradient(
            PinnedScrollEdges.gradient(for: edge),
            startPoint: CGPoint(x: 0, y: outer),
            endPoint: CGPoint(x: 0, y: inner)
        ))
    }
}

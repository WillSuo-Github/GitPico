import SwiftUI
import Variablur

/// The scroll viewport fills the pane. Insets keep the first and last rows
/// reachable while allowing intermediate rows to travel under the fixed bars.
struct PinnedScrollPane<Content: View, Top: View, Bottom: View>: View {
    @ViewBuilder let content: (EdgeInsets) -> Content
    @ViewBuilder let top: () -> Top
    @ViewBuilder let bottom: () -> Bottom
    @State private var topHeight: CGFloat = 0
    @State private var bottomHeight: CGFloat = 0
    @Namespace private var viewport

    var body: some View {
        let insets = EdgeInsets(top: topHeight, leading: 0, bottom: bottomHeight, trailing: 0)
        content(insets)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.pinnedScrollEdges, PinnedScrollEdges(viewport: viewport, insets: insets))
            .overlay(alignment: .top) {
                PinnedScrollBar(edge: .top, height: $topHeight, content: top)
            }
            .overlay(alignment: .bottom) {
                PinnedScrollBar(edge: .bottom, height: $bottomHeight, content: bottom)
            }
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

    /// Apply to individual SwiftUI rows. AppKit-backed content uses the bar's backdrop.
    func progressiveScrollBlur() -> some View {
        modifier(ProgressiveScrollBlur())
    }
}

private struct PinnedScrollBar<Content: View>: View {
    let edge: VerticalEdge
    @Binding var height: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = $0 }
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .accessibilityHidden(true)
            }
            .background { ScrollBarBackdrop(edge: edge) }
    }
}

struct ScrollBarBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let edge: VerticalEdge

    var body: some View {
        GeometryReader { geometry in
            let overlap = PinnedScrollEdges.overlap
            let barHeight = geometry.size.height
            if barHeight > 0 {
                if reduceTransparency {
                    Rectangle().fill(.background)
                } else {
                    let fraction = min(1, PinnedScrollEdges.tintTransition / (barHeight + overlap))
                    Rectangle().fill(.regularMaterial)
                        .overlay { Rectangle().fill(.background.opacity(0.7)) }
                        .mask {
                            LinearGradient(
                                gradient: PinnedScrollEdges.gradient,
                                startPoint: UnitPoint(x: 0.5, y: edge == .top ? 1 - fraction : fraction),
                                endPoint: edge == .top ? .bottom : .top
                            )
                        }
                        .frame(height: barHeight + overlap)
                        .offset(y: edge == .top ? 0 : -overlap)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PinnedScrollEdges: Sendable {
    static let overlap: CGFloat = 12
    static let tintTransition: CGFloat = 24
    static let blurTransition: CGFloat = 40
    static let radius: CGFloat = 8
    static let gradient = Gradient(stops: [
        .init(color: .white, location: 0),
        .init(color: .white.opacity(0.9), location: 0.2),
        .init(color: .white.opacity(0.5), location: 0.5),
        .init(color: .white.opacity(0.1), location: 0.8),
        .init(color: .clear, location: 1)
    ])

    let viewport: Namespace.ID
    let insets: EdgeInsets
}

private extension EnvironmentValues {
    @Entry var pinnedScrollEdges: PinnedScrollEdges? = nil
}

private struct ProgressiveScrollBlur: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.pinnedScrollEdges) private var edges

    func body(content: Content) -> some View {
        if let edges, !reduceTransparency {
            let bleed = PinnedScrollEdges.radius * 3
            content.padding(bleed)
                .visualEffect { effect, geometry in
                    let frame = geometry.frame(in: .named(edges.viewport))
                    let viewportHeight = geometry.bounds(of: .named(edges.viewport))?.height ?? 0
                    let top = edges.insets.top + PinnedScrollEdges.overlap
                    let bottom = viewportHeight - edges.insets.bottom - PinnedScrollEdges.overlap
                    let blurTop = edges.insets.top > 0 && frame.minY < top && frame.maxY > 0
                    let blurBottom = edges.insets.bottom > 0 && frame.maxY > bottom && frame.minY < viewportHeight
                    let mask = Image(size: geometry.size) { context in
                        let bounds = Path(CGRect(origin: .zero, size: geometry.size))
                        if blurTop {
                            fill(context, bounds: bounds, clearAt: top - frame.minY, direction: -1)
                        }
                        if blurBottom {
                            fill(context, bounds: bounds, clearAt: bottom - frame.minY, direction: 1)
                        }
                    }
                    return effect.variableBlur(radius: PinnedScrollEdges.radius, mask: mask, isEnabled: viewportHeight > 0 && (blurTop || blurBottom))
                }
                .padding(-bleed)
        } else {
            content
        }
    }

    private nonisolated func fill(_ context: GraphicsContext, bounds: Path, clearAt y: CGFloat, direction: CGFloat) {
        context.fill(bounds, with: .linearGradient(
            PinnedScrollEdges.gradient,
            startPoint: CGPoint(x: 0, y: y + direction * PinnedScrollEdges.blurTransition),
            endPoint: CGPoint(x: 0, y: y)
        ))
    }
}

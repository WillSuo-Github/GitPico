import AppKit
import SwiftUI

/// Fades the outline's native drawing over the sidebar surface beneath the variable-blur bars.
struct SidebarScrollEdges: NSViewRepresentable {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
        view.reduceTransparency = reduceTransparency
        view.updateEdges()
    }

    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.detach() }

    final class Anchor: NSView {
        var reduceTransparency = false
        private weak var scroll: NSScrollView?
        private let fade = CAGradientLayer()
        private var observers: [any NSObjectProtocol] = []
        private var originalNotifications: (bounds: Bool, frame: Bool)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { detach() }
            else { Task { @MainActor [weak self] in self?.updateEdges() } }
        }

        override func layout() {
            super.layout()
            updateEdges()
        }

        func updateEdges() {
            guard window != nil, bounds.width > 0 else { return }
            if scroll == nil || scroll?.window !== window {
                detach()
                let area = convert(bounds, to: nil)
                for ancestor in sequence(first: superview, next: { $0?.superview }) {
                    guard let ancestor else { break }
                    if let found = outlineScroll(in: ancestor, covering: area) {
                        attach(to: found)
                        break
                    }
                }
            }
            guard let scroll, let layer = scroll.contentView.layer, layer.mask == nil || layer.mask === fade else { return }
            let clip = scroll.contentView
            let viewport = clip.frame
            guard viewport.height > 0 else { return }
            let top = min(clip.contentInsets.top, viewport.height / 2)
            let bottom = min(clip.contentInsets.bottom, viewport.height / 2)
            // Give rows passing under the card room to fade without dimming the first row at rest.
            let travel = max(0, clip.bounds.minY + clip.contentInsets.top)
            let topFade = reduceTransparency || top == 0 ? top : min(top + min(travel, 8), viewport.height / 2)
            updateFade(layer, flipped: clip.isFlipped, top: top / viewport.height, topFade: topFade / viewport.height, bottom: bottom / viewport.height)
        }

        private func outlineScroll(in view: NSView, covering area: NSRect) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.documentView is NSOutlineView {
                let frame = scroll.convert(scroll.bounds, to: nil)
                if abs(frame.minX - area.minX) < 1 && abs(frame.width - area.width) < 1 { return scroll }
            }
            return view.subviews.lazy.compactMap { self.outlineScroll(in: $0, covering: area) }.first
        }

        private func attach(to scroll: NSScrollView) {
            self.scroll = scroll
            let clip = scroll.contentView
            clip.wantsLayer = true
            originalNotifications = (clip.postsBoundsChangedNotifications, clip.postsFrameChangedNotifications)
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            observers = [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateEdges() }
                }
            }
        }

        private func updateFade(_ layer: CALayer, flipped: Bool, top: CGFloat, topFade: CGFloat, bottom: CGFloat) {
            let clear = NSColor.clear.cgColor
            let solid = NSColor.white.cgColor
            let softTop = NSColor.white.withAlphaComponent(0.18).cgColor
            let softBottom = NSColor.white.withAlphaComponent(0.28).cgColor
            let mutedBottom = NSColor.white.withAlphaComponent(0.18).cgColor
            let faintBottom = NSColor.white.withAlphaComponent(0.13).cgColor
            let colors = reduceTransparency ? [clear, clear, solid, solid, clear, clear] :
                [clear, softTop, softTop, solid, solid, softBottom, mutedBottom, faintBottom, clear]
            let stops = reduceTransparency ? [0, top, top, 1 - bottom, 1 - bottom, 1] :
                [0, top * 0.44, top * 0.96, topFade, 1 - bottom, 1 - bottom * 0.82, 1 - bottom * 0.48, 1 - bottom * 0.20, 1]
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fade.frame = layer.bounds
            fade.startPoint = CGPoint(x: 0.5, y: flipped ? 0 : 1)
            fade.endPoint = CGPoint(x: 0.5, y: flipped ? 1 : 0)
            fade.colors = colors
            fade.locations = stops.map { NSNumber(value: Double($0)) }
            if layer.mask == nil { layer.mask = fade }
            CATransaction.commit()
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            if let clip = scroll?.contentView {
                if clip.layer?.mask === fade { clip.layer?.mask = nil }
                if let originalNotifications {
                    clip.postsBoundsChangedNotifications = originalNotifications.bounds
                    clip.postsFrameChangedNotifications = originalNotifications.frame
                }
            }
            originalNotifications = nil
            scroll = nil
        }
    }
}

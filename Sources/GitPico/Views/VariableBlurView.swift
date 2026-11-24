import AppKit
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI

enum VariableBlurDirection: Equatable, Sendable {
    case blurredTopClearBottom
    case blurredBottomClearTop
}

/// Real-time progressive backdrop blur modeled after CostAware's VariableBlurView.
struct VariableBlurView: NSViewRepresentable {
    var maxBlurRadius: CGFloat = 10
    var direction: VariableBlurDirection = .blurredTopClearBottom
    var transitionHeight: CGFloat? = nil
    var startOffset: CGFloat = 0

    func makeNSView(context: Context) -> VariableBlurNSView {
        VariableBlurNSView(
            maxBlurRadius: maxBlurRadius,
            direction: direction,
            transitionHeight: transitionHeight,
            startOffset: startOffset
        )
    }

    func updateNSView(_ nsView: VariableBlurNSView, context: Context) {
        nsView.update(
            maxBlurRadius: maxBlurRadius,
            direction: direction,
            transitionHeight: transitionHeight,
            startOffset: startOffset
        )
    }
}

final class VariableBlurNSView: NSView {
    private static let imageContext = CIContext(options: [.cacheIntermediates: false])
    private static let requiredFilterKeys: Set<String> = [
        "inputRadius",
        "inputMaskImage",
        "inputNormalizeEdges"
    ]

    private var backdrop: CALayer?
    private var blurFilter: NSObject?
    private let fallback = NSVisualEffectView()
    private let fallbackMask = CALayer()
    private var parameters: Parameters
    private var renderedMask: MaskConfiguration?
    private var gradientMask: CGImage?

    var isUsingVariableBlurBackdrop: Bool {
        backdrop != nil && blurFilter != nil
    }

    init(
        maxBlurRadius: CGFloat = 10,
        direction: VariableBlurDirection = .blurredTopClearBottom,
        transitionHeight: CGFloat? = nil,
        startOffset: CGFloat = 0
    ) {
        parameters = Parameters(
            radius: maxBlurRadius,
            direction: direction,
            transitionHeight: transitionHeight,
            offset: startOffset
        )
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = nil
        layer?.isOpaque = false
        layer?.masksToBounds = true

        fallback.blendingMode = .withinWindow
        fallback.material = .contentBackground
        fallback.state = .active
        fallback.wantsLayer = true
        fallback.isHidden = true
        fallback.layer?.mask = fallbackMask
        addSubview(fallback)

        if let backdrop = Self.makeBackdropLayer(), let filter = Self.makeVariableBlurFilter() {
            backdrop.backgroundColor = nil
            backdrop.isOpaque = false
            backdrop.allowsEdgeAntialiasing = false
            layer?.addSublayer(backdrop)
            self.backdrop = backdrop
            blurFilter = filter
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @objc private func _shouldAutoFlattenLayerTree() -> Bool { false }

    func update(
        maxBlurRadius: CGFloat,
        direction: VariableBlurDirection,
        transitionHeight: CGFloat? = nil,
        startOffset: CGFloat = 0
    ) {
        let next = Parameters(
            radius: maxBlurRadius,
            direction: direction,
            transitionHeight: transitionHeight,
            offset: startOffset
        )
        guard next != parameters else { return }
        parameters = next
        updateEffect()
    }

    override func layout() {
        super.layout()
        updateEffect()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        renderedMask = nil
        updateEffect()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateEffect()
    }

    private func updateEffect() {
        let scale = window?.backingScaleFactor ?? 1

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        layer?.contentsScale = scale
        backdrop?.frame = bounds
        backdrop?.contentsScale = scale
        fallback.frame = bounds
        fallbackMask.frame = CGRect(origin: .zero, size: bounds.size)
        fallbackMask.contentsScale = scale

        guard bounds.width > 0, bounds.height > 0, parameters.radius > 0 else {
            renderedMask = nil
            gradientMask = nil
            backdrop?.isHidden = true
            fallback.isHidden = true
            return
        }

        let maskConfiguration = MaskConfiguration(height: bounds.height, scale: scale, parameters: parameters)
        guard maskConfiguration != renderedMask || gradientMask == nil else {
            backdrop?.isHidden = backdrop == nil || blurFilter == nil
            fallback.isHidden = isUsingVariableBlurBackdrop
            return
        }
        guard let mask = makeGradientImage(height: bounds.height, scale: scale) else {
            renderedMask = nil
            gradientMask = nil
            backdrop?.isHidden = true
            fallback.isHidden = true
            return
        }

        renderedMask = maskConfiguration
        gradientMask = mask
        fallbackMask.contents = mask

        if let backdrop, let blurFilter {
            blurFilter.setValue(Double(parameters.radius), forKey: "inputRadius")
            blurFilter.setValue(mask, forKey: "inputMaskImage")
            blurFilter.setValue(true, forKey: "inputNormalizeEdges")
            if backdrop.responds(to: NSSelectorFromString("setScale:")) {
                backdrop.setValue(Double(scale), forKey: "scale")
            }
            backdrop.filters = [blurFilter]
            backdrop.isHidden = false
            fallback.isHidden = true
        } else {
            fallback.isHidden = false
        }
    }

    private func makeGradientImage(height viewHeight: CGFloat, scale: CGFloat) -> CGImage? {
        let height = max(2, min(2048, ceil(viewHeight * scale)))
        let transitionPixels = parameters.transitionHeight.map {
            min(height, max(2, ceil($0 * scale)))
        } ?? height

        let gradient = CIFilter.smoothLinearGradient()
        gradient.color0 = .black
        gradient.color1 = .clear
        switch parameters.direction {
        case .blurredTopClearBottom:
            gradient.point0 = CGPoint(x: 0, y: transitionPixels)
            gradient.point1 = CGPoint(x: 0, y: parameters.offset * transitionPixels)
        case .blurredBottomClearTop:
            gradient.point0 = CGPoint(x: 0, y: height - transitionPixels)
            gradient.point1 = CGPoint(x: 0, y: height - parameters.offset * transitionPixels)
        }
        guard let output = gradient.outputImage else { return nil }
        return Self.imageContext.createCGImage(output, from: CGRect(x: 0, y: 0, width: 2, height: height))
    }

    private static func makeBackdropLayer() -> CALayer? {
        guard let layerClass = NSClassFromString("CABackdropLayer") as? CALayer.Type else { return nil }
        let layer = layerClass.init()
        if layer.responds(to: NSSelectorFromString("setWindowServerAware:")) {
            layer.setValue(false, forKey: "windowServerAware")
        }
        return layer
    }

    private static func makeVariableBlurFilter() -> NSObject? {
        guard let filterClass = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
        let createSelector = NSSelectorFromString("filterWithType:")
        guard filterClass.responds(to: createSelector),
              let filter = filterClass.perform(createSelector, with: "variableBlur")?.takeUnretainedValue() as? NSObject else {
            return nil
        }
        let keysSelector = NSSelectorFromString("inputKeys")
        guard filter.responds(to: keysSelector),
              let inputKeys = filter.perform(keysSelector)?.takeUnretainedValue() as? [String],
              requiredFilterKeys.isSubset(of: Set(inputKeys)) else {
            return nil
        }
        return filter
    }

    private struct Parameters: Equatable {
        let radius: CGFloat
        let direction: VariableBlurDirection
        let transitionHeight: CGFloat?
        let offset: CGFloat

        init(radius: CGFloat, direction: VariableBlurDirection, transitionHeight: CGFloat?, offset: CGFloat) {
            self.radius = radius.isFinite ? max(0, radius) : 0
            self.direction = direction
            if let transitionHeight, transitionHeight.isFinite, transitionHeight > 0 {
                self.transitionHeight = transitionHeight
            } else {
                self.transitionHeight = nil
            }
            self.offset = offset.isFinite ? min(0.999, offset) : 0
        }
    }

    private struct MaskConfiguration: Equatable {
        let height: CGFloat
        let scale: CGFloat
        let parameters: Parameters
    }
}

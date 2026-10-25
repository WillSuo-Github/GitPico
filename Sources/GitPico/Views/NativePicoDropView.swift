import AppKit
import OSLog
import UniformTypeIdentifiers

/// Native destination lifecycle; it can be exercised without a window or mouse events.
final class NativePicoDropView: NSView {
    var validate: (([PicoDragToken]) -> Bool)?
    var accept: (([PicoDragToken], CGPoint, CGFloat) -> Bool)?
    private(set) var isDropTargeted = false
    private var enteredTokens: [PicoDragToken]?
    private var operation: NSDragOperation = []
    private let pasteboardType = NSPasteboard.PasteboardType(UTType.picoDrag.identifier)
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([pasteboardType])
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Normal clicks pass through; drag targeting must not intercept later clicks.
        guard isDropTargeted || NSApp?.currentEvent?.type == .leftMouseDragged else { return nil }
        return super.hitTest(point)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        reset()
        guard let tokens = readTokens(sender.draggingPasteboard), validate?(tokens) == true else { return [] }
        enteredTokens = tokens
        return update(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { reset() }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { reset() }
    override func draggingEnded(_ sender: any NSDraggingInfo) { reset() }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { !update(sender).isEmpty }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard !update(sender).isEmpty, let tokens = enteredTokens else { reset(); return false }
        let point = convert(sender.draggingLocation, from: nil)
        // Consume before dispatch: duplicated AppKit callbacks cannot open a second review.
        reset()
        return accept?(tokens, point, bounds.height) ?? false
    }

    private func update(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let enteredTokens, readTokens(sender.draggingPasteboard) == enteredTokens,
              validate?(enteredTokens) == true else { reset(); return [] }
        let mask = sender.draggingSourceOperationMask
        operation = mask.contains(.copy) ? .copy : mask.contains(.move) ? .move : []
        guard !operation.isEmpty else { reset(); return [] }
        isDropTargeted = true; needsDisplay = true
        sender.numberOfValidItemsForDrop = enteredTokens.count
        return operation
    }

    private func readTokens(_ pasteboard: NSPasteboard) -> [PicoDragToken]? {
        let items = pasteboard.pasteboardItems ?? []
        guard !items.isEmpty, items.count <= 512 else { return nil }
        var tokens: [PicoDragToken] = []
        for item in items {
            guard let data = item.data(forType: pasteboardType), data.count <= 512,
                  let token = try? JSONDecoder().decode(PicoDragToken.self, from: data) else { return nil }
            tokens.append(token)
        }
        return tokens
    }

    private func reset() {
        enteredTokens = nil; operation = []; isDropTargeted = false; needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isDropTargeted else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
        path.fill(); NSColor.controlAccentColor.setStroke(); path.lineWidth = 1.5; path.stroke()
    }
}

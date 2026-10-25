import AppKit
import GitCore
import SwiftUI

private struct NativePicoDropTarget: NSViewRepresentable {
    let validate: ([PicoDragToken]) -> Bool
    let receive: ([PicoDragToken], CGPoint, CGFloat) -> Bool
    func makeNSView(context: Context) -> NativePicoDropView { NativePicoDropView() }
    func updateNSView(_ view: NativePicoDropView, context: Context) {
        view.validate = validate; view.accept = receive
    }
}

extension View {
    func picoDrag(_ store: RepositoryStore, _ action: PicoDragAction) -> some View {
        onDrag { store.dragProvider(action) }
    }
    func picoDrop(_ store: RepositoryStore, _ target: PicoDropTarget) -> some View {
        overlay {
            NativePicoDropTarget(validate: { store.canAcceptDrop($0, on: target) }) { tokens, point, height in
                store.acceptDrop(tokens, on: target, point: point, height: height)
            }
        }
    }
    func picoRebaseDrop(_ store: RepositoryStore, planID: UUID, receive: @escaping (String, Bool) -> Bool) -> some View {
        overlay {
            NativePicoDropTarget(validate: { store.rebaseDragSource($0, planID: planID) != nil }) { tokens, point, height in
                guard let hash = store.rebaseDragSource(tokens, planID: planID) else { return false }
                return receive(hash, point.y >= height / 2)
            }
        }
    }
}

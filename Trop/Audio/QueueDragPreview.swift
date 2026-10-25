//
//  QueueDragPreview.swift
//  Trop
//

import ObjectiveC
import SwiftUI
import UIKit

private var dragProxyKey: UInt8 = 0

/// Wraps the list's drag delegate so a row lifted for reordering keeps its own
/// look: no dark rectangle behind it, rounded like the highlight of the current song.
private final class DragPreviewProxy: NSObject, UICollectionViewDragDelegate {
    weak var original: UICollectionViewDragDelegate?

    func collectionView(
        _ collectionView: UICollectionView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        original?.collectionView(collectionView, itemsForBeginning: session, at: indexPath) ?? []
    }

    func collectionView(
        _ collectionView: UICollectionView,
        dragPreviewParametersForItemAt indexPath: IndexPath
    ) -> UIDragPreviewParameters? {
        let parameters = original?.collectionView?(collectionView, dragPreviewParametersForItemAt: indexPath)
            ?? UIDragPreviewParameters()
        parameters.backgroundColor = .clear
        if let cell = collectionView.cellForItem(at: indexPath) {
            parameters.visiblePath = UIBezierPath(roundedRect: cell.bounds.insetBy(dx: 12, dy: 1), cornerRadius: 10)
        }
        return parameters
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? { original }
}

/// Put in the background of a list row: finds the list and installs the drag preview fix once.
struct QueueDragPreviewFix: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { Probe() }

    func updateUIView(_ uiView: UIView, context: Context) {}

    private final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.install() }
        }

        private func install() {
            var view = superview
            while let current = view, !(current is UICollectionView) { view = current.superview }
            guard let collectionView = view as? UICollectionView,
                  let original = collectionView.dragDelegate,
                  !(original is DragPreviewProxy) else { return }
            let proxy = DragPreviewProxy()
            proxy.original = original
            objc_setAssociatedObject(collectionView, &dragProxyKey, proxy, .OBJC_ASSOCIATION_RETAIN)
            collectionView.dragDelegate = proxy
        }
    }
}

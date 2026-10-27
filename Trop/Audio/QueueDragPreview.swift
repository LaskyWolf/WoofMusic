//
//  QueueDragPreview.swift
//  Trop
//

import ObjectiveC
import SwiftUI
import UIKit

private var dragProxyKey: UInt8 = 0
private var dropProxyKey: UInt8 = 0

/// Clear background and the rounded shape of the current-song highlight.
private func rowPreviewParameters(
    _ base: UIDragPreviewParameters?,
    collectionView: UICollectionView,
    indexPath: IndexPath
) -> UIDragPreviewParameters {
    let parameters = base ?? UIDragPreviewParameters()
    parameters.backgroundColor = .clear
    if let cell = collectionView.cellForItem(at: indexPath) {
        parameters.visiblePath = UIBezierPath(roundedRect: cell.bounds.insetBy(dx: 12, dy: 1), cornerRadius: 10)
    }
    return parameters
}

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
        rowPreviewParameters(
            original?.collectionView?(collectionView, dragPreviewParametersForItemAt: indexPath),
            collectionView: collectionView,
            indexPath: indexPath
        )
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? { original }
}

/// Same fix for the drop: the row settling into its new place uses the drop
/// delegate's preview, which otherwise gets the default dark background.
private final class DropPreviewProxy: NSObject, UICollectionViewDropDelegate {
    weak var original: UICollectionViewDropDelegate?

    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        original?.collectionView(collectionView, performDropWith: coordinator)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        dropPreviewParametersForItemAt indexPath: IndexPath
    ) -> UIDragPreviewParameters? {
        rowPreviewParameters(
            original?.collectionView?(collectionView, dropPreviewParametersForItemAt: indexPath),
            collectionView: collectionView,
            indexPath: indexPath
        )
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
            guard let collectionView = view as? UICollectionView else { return }
            if let original = collectionView.dragDelegate, !(original is DragPreviewProxy) {
                let proxy = DragPreviewProxy()
                proxy.original = original
                objc_setAssociatedObject(collectionView, &dragProxyKey, proxy, .OBJC_ASSOCIATION_RETAIN)
                collectionView.dragDelegate = proxy
            }
            if let original = collectionView.dropDelegate, !(original is DropPreviewProxy) {
                let proxy = DropPreviewProxy()
                proxy.original = original
                objc_setAssociatedObject(collectionView, &dropProxyKey, proxy, .OBJC_ASSOCIATION_RETAIN)
                collectionView.dropDelegate = proxy
            }
        }
    }
}

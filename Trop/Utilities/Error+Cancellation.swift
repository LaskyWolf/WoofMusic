//
//  Error+Cancellation.swift
//  Trop
//

import Foundation

extension Error {
    /// True for a cancelled Task or URL request (-999): the work was stopped on
    /// purpose, usually because the view that started it went away. Not a failure.
    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}

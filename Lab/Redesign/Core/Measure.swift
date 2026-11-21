import AppKit
import SwiftUI

/// The height SwiftUI gives a view at a width, for containers that size
/// themselves to their text (the island, cards) and have to know it before
/// the frame draws, so larger labels grow the container instead of clipping.
@MainActor
enum Measure {
    private static var cache: [String: CGSize] = [:]

    static func size<V: View>(_ key: String, width: CGFloat, @ViewBuilder _ view: () -> V) -> CGSize {
        let k = "\(key)@\(width)"
        if let s = cache[k] { return s }
        let host = NSHostingView(rootView: view().frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true))
        let s = host.fittingSize
        cache[k] = s
        return s
    }
}

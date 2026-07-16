import Foundation
#if canImport(UIKit)
import UIKit

/// #AARRGGBB, resolving dynamic (trait-dependent) colors first so the value is
/// the one actually on screen. Shared by the snapshot walk and the region probe.
enum ColorHex {
    static func hex(_ color: UIColor, in traits: UITraitCollection) -> String {
        let resolved = color.resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ v: CGFloat) -> Int { max(0, min(255, Int((v * 255.0).rounded()))) }
        return String(format: "#%02X%02X%02X%02X", c(a), c(r), c(g), c(b))
    }
}
#endif

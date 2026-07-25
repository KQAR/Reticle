import Foundation
import ReticleProtocol
#if canImport(UIKit)
import UIKit

/// Sub-regions inside ONE SwiftUI `Text` that contains links — the iOS twin of the
/// Android `ComposeTextRegions`.
///
/// The gap it closes: a markdown `Text` ("Read the [Terms](…) and [Privacy](…)") is a
/// single accessibility element with one label. There is no `UILabel`, no
/// `NSAttributedString.link` run, no child element and no view to measure, so the
/// `RegionProbe` channels all come up empty and the two links are unaddressable —
/// while the UIKit agreement row next to it decomposes fine.
///
/// The surface that DOES exist (measured on iOS 26.3, and the only one that did):
/// `accessibilityAttributedLabel` returns the label split into runs carrying
/// `UIAccessibilityTokenLink` on the link ranges, plus the font tokens
/// (`…TokenFontName` / `…TokenFontSize` / `…TokenFontFamily`) for every run. Those
/// are system-emitted accessibility attributes on a public property — not SwiftUI
/// internals, which the project never reads for selectors. What was NOT available,
/// so nothing here depends on it: child accessibility elements (0), an element count
/// (0), custom actions (none), a usable custom rotor, or any `_accessibility*` link
/// accessor.
///
/// Geometry is therefore RECONSTRUCTED: the runs are re-laid out with their own
/// fonts inside the element's own screen frame, the same way `TextLayoutStack`
/// rebuilds a `UILabel`'s stack — reliable enough to tap (verified end to end: the
/// computed "Privacy" point fires the app's `openURL` handler), and honest about
/// where it came from. Regions use `source = span`, matching what the Compose bridge
/// emits for the same shape.
@MainActor
enum SwiftUITextRegions {

    /// The attribute key iOS puts on a link run inside an accessibility label.
    /// A plain string on a public property, so this reads no private API.
    private static let linkToken = NSAttributedString.Key("UIAccessibilityTokenLink")
    private static let fontNameToken = NSAttributedString.Key("UIAccessibilityTokenFontName")
    private static let fontSizeToken = NSAttributedString.Key("UIAccessibilityTokenFontSize")

    struct Result {
        var regions: [InteractionRegion] = []
        var charGrid: CharGrid?
    }

    /// Link regions + a char grid for one accessibility element, or an empty result
    /// when it carries no link runs (the overwhelmingly common case, so the
    /// expensive re-layout never runs for ordinary text).
    static func probe(element: NSObject, screenFrame: Rect?) -> Result {
        guard let screenFrame, screenFrame.width > 0 else { return Result() }
        guard let attributed = element.accessibilityAttributedLabel, attributed.length > 0 else { return Result() }
        let linkRanges = linkRuns(in: attributed)
        guard !linkRanges.isEmpty else { return Result() }
        guard let stack = TextLayoutStack(attributed: layoutString(from: attributed), screenFrame: screenFrame) else {
            return Result()
        }

        var result = Result()
        let text = attributed.string as NSString
        for range in linkRanges {
            let rects = stack.screenRects(for: range, in: nil)
            guard !rects.isEmpty else { continue }
            result.regions.append(InteractionRegion(
                source: .span,
                label: text.substring(with: range),
                rects: rects
            ))
        }
        // The same grid the UIKit rows get: any substring stays targetable even when
        // it is not one of the link runs.
        let (lines, approximate) = stack.charLines(in: nil)
        if !lines.isEmpty {
            result.charGrid = CharGrid(text: attributed.string, lines: lines, approximate: approximate)
        }
        return result
    }

    private static func linkRuns(in attributed: NSAttributedString) -> [NSRange] {
        var ranges: [NSRange] = []
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(linkToken, in: full) { value, range, _ in
            guard value != nil, range.length > 0 else { return }
            ranges.append(range)
        }
        return ranges
    }

    /// Rebuild a measurable string: the accessibility label carries fonts as tokens
    /// (name + size), not as `NSFont`/`UIFont` attributes, so nothing would lay out
    /// without this translation.
    private static func layoutString(from attributed: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(string: attributed.string)
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttributes(in: full) { attrs, range, _ in
            let size = (attrs[fontSizeToken] as? NSNumber).map { CGFloat($0.doubleValue) }
                ?? UIFont.labelFontSize
            let name = attrs[fontNameToken] as? String
            out.addAttribute(.font, value: font(named: name, size: size), range: range)
        }
        return out
    }

    /// The system font reports itself as a dot-prefixed internal name
    /// (".SFUI-Regular"), which `UIFont(name:)` cannot instantiate — ask for the
    /// system font at that size instead, which is what it actually is.
    private static func font(named name: String?, size: CGFloat) -> UIFont {
        guard let name, !name.isEmpty, !name.hasPrefix(".") else {
            return UIFont.systemFont(ofSize: size)
        }
        return UIFont(name: name, size: size) ?? UIFont.systemFont(ofSize: size)
    }
}
#endif

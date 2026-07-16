import Foundation
import ReticleProtocol
#if canImport(UIKit)
import UIKit

/// Discovers sub-regions inside a single view — the iOS port of the Android
/// agent's `RegionProbe`, driving the same protocol fields
/// (`Node.regions` / `suspectedMultiRegion` / `charGrid`).
///
/// Channels, in decreasing reliability:
/// - `span` — real `.link` attribute runs, with per-line pixel rects.
/// - `a11yVirtual` — child accessibility elements a view exposes (the YYText /
///   `accessibilityElements` pattern; the analogue of Android's virtual nodes).
/// - `colorSpan` — a re-colored run that is NOT a real link ("highlight =
///   tappable" candidate), surfaced with its actual color.
/// - `textMarker` — bracketed / markdown links inside a self-drawn row that
///   exposed nothing structural (fires only under `suspectedMultiRegion`).
/// - char grid — exact per-character boundary X for any text node, so a
///   substring is targetable even with no markers at all.
///
/// Runs on the main thread (called from SnapshotCapture). Every channel
/// degrades to "nothing" on any error rather than throwing, so a weird widget
/// never breaks a whole snapshot.
///
/// Text geometry: UITextView lends its own TextKit stack (exact); UILabel has
/// no public layout API, so a parallel TextKit stack is rebuilt from its
/// attributed text — the same reconstruction real multi-link rows use for
/// their private hit-testing, which is what keeps the geometry honest.
@MainActor
enum RegionProbe {

    struct Result {
        var regions: [InteractionRegion] = []
        var suspectedMultiRegion = false
        var charGrid: CharGrid?
    }

    /// `isSwiftUIHost` suppresses the a11yVirtual channel for SwiftUI hosting
    /// surfaces: their accessibility elements are already captured as
    /// `axElement` child nodes, and double-reporting them as regions would
    /// present the same target twice.
    static func probe(_ view: UIView, isSwiftUIHost: Bool) -> Result {
        var result = Result()

        // Channel 1: real `.link` attribute runs.
        if let stack = TextLayoutStack(view: view) {
            result.regions += linkRegions(view, stack: stack)

            // Channel 3b: re-colored runs not covered by a real link run.
            result.regions += colorRunRegions(view, stack: stack, existing: result.regions)
        }

        // Channel 2: child accessibility elements (UIKit virtual nodes).
        if !isSwiftUIHost {
            result.regions += a11yVirtualRegions(view)
        }

        // Suspected-multi-region heuristic: an interactive text node that looks
        // like it embeds links (paired bracket markers or a markdown link) yet
        // exposed no real link runs, no accessibility elements, and has no
        // tappable children. Detection is structural, never lexical — Reticle
        // must not assume an app's language.
        if result.regions.isEmpty,
           let label = view as? UILabel,
           label.isUserInteractionEnabled,
           looksLikeEmbeddedLink(label.attributedText?.string ?? label.text) {
            result.suspectedMultiRegion = true
            // Channel 4 (fallback): one region per in-text marker.
            if let stack = TextLayoutStack(view: view) {
                result.regions += markerRegions(view, stack: stack)
            }
        }

        // Char grid for any text node — the last resort for a self-drawn
        // control with no markers (substring targeting by exact glyph X).
        if let stack = TextLayoutStack(view: view) {
            result.charGrid = charGrid(view, stack: stack)
        }

        return result
    }

    // MARK: - Channel 1: .link attribute runs

    private static func linkRegions(_ view: UIView, stack: TextLayoutStack) -> [InteractionRegion] {
        let attributed = stack.attributed
        var out: [InteractionRegion] = []
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.link, in: full) { value, range, _ in
            guard let value, range.length > 0 else { return }
            let target: String?
            switch value {
            case let url as URL: target = url.absoluteString
            case let s as String: target = s
            default: target = nil
            }
            let label = (attributed.string as NSString).substring(with: range)
            out.append(InteractionRegion(
                source: .span,
                label: label,
                target: target,
                charStart: range.location,
                charEnd: range.location + range.length,
                rects: stack.screenRects(for: range, in: view),
                color: linkColor(view, attributed: attributed, range: range)
            ))
        }
        return out
    }

    /// The color a link run actually renders with. UITextView repaints link
    /// ranges with `linkTextAttributes` at render time, overriding any
    /// `.foregroundColor` run, so that wins there; elsewhere an explicit
    /// foreground run covering the range, then the view's tint (UIKit's
    /// default link tint).
    private static func linkColor(_ view: UIView, attributed: NSAttributedString, range: NSRange) -> String? {
        if let textView = view as? UITextView,
           let color = textView.linkTextAttributes[.foregroundColor] as? UIColor {
            return ColorHex.hex(color, in: view.traitCollection)
        }
        var covering = NSRange()
        if let color = attributed.attribute(.foregroundColor, at: range.location, longestEffectiveRange: &covering, in: range) as? UIColor,
           covering.length == range.length {
            return ColorHex.hex(color, in: view.traitCollection)
        }
        if let tint = view.tintColor {
            return ColorHex.hex(tint, in: view.traitCollection)
        }
        return nil
    }

    // MARK: - Channel 3b: re-colored runs (colorSpan)

    /// Contiguous `.foregroundColor` runs that differ from the node's base text
    /// color and are NOT covered by a real link region. iOS attributed strings
    /// carry a foreground run for the whole string whenever a color is set at
    /// all, so the base color (the one covering the most characters) is the
    /// reference — only minority-colored runs are candidates.
    private static func colorRunRegions(_ view: UIView, stack: TextLayoutStack, existing: [InteractionRegion]) -> [InteractionRegion] {
        let attributed = stack.attributed
        guard attributed.length > 0 else { return [] }
        let full = NSRange(location: 0, length: attributed.length)

        var runs: [(color: UIColor, range: NSRange)] = []
        var coverage: [UIColor: Int] = [:]
        attributed.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            guard let color = value as? UIColor else { return }
            runs.append((color, range))
            coverage[color, default: 0] += range.length
        }
        guard runs.count > 1, let base = coverage.max(by: { $0.value < $1.value })?.key else { return [] }

        var out: [InteractionRegion] = []
        for run in runs where run.color != base {
            let start = run.range.location
            let end = run.range.location + run.range.length
            let covered = existing.contains { r in
                guard r.source == .span, let cs = r.charStart, let ce = r.charEnd else { return false }
                return start >= cs && end <= ce
            }
            if covered { continue }
            let label = (attributed.string as NSString).substring(with: run.range)
            if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            out.append(InteractionRegion(
                source: .colorSpan,
                label: label,
                charStart: start,
                charEnd: end,
                rects: stack.screenRects(for: run.range, in: view),
                color: ColorHex.hex(run.color, in: view.traitCollection)
            ))
        }
        return out
    }

    // MARK: - Channel 2: child accessibility elements

    /// A view whose `accessibilityElements` expose labeled sub-frames is the
    /// iOS analogue of Android's virtual a11y provider (ExploreByTouchHelper):
    /// YYText-style rich labels, custom multi-target rows, etc. Each element
    /// becomes one region with its on-screen frame.
    private static func a11yVirtualRegions(_ view: UIView) -> [InteractionRegion] {
        guard let elements = view.accessibilityElements, !elements.isEmpty else { return [] }
        let viewFrame = view.accessibilityFrame
        var out: [InteractionRegion] = []
        for case let element as NSObject in elements {
            // Subviews can legally appear in accessibilityElements — they are
            // already real nodes in the tree, not virtual sub-regions.
            if element is UIView { continue }
            let frame = element.accessibilityFrame
            guard frame.width > 0, frame.height > 0 else { continue }
            // An element spanning the whole view is the view's own a11y proxy
            // (UITextView does this), not a sub-region — no targeting value.
            if abs(frame.minX - viewFrame.minX) < 2, abs(frame.minY - viewFrame.minY) < 2,
               abs(frame.width - viewFrame.width) < 4, abs(frame.height - viewFrame.height) < 4 {
                continue
            }
            // Same proxy signal by content: an element carrying the text view's
            // ENTIRE text (as label or value — text fields report content as
            // value) is the row itself, not a sub-target.
            if let textView = view as? UITextView, let text = textView.text, !text.isEmpty,
               element.accessibilityLabel == text || element.accessibilityValue == text { continue }
            let label = element.accessibilityLabel
                ?? (element.accessibilityValue.flatMap { $0.isEmpty ? nil : $0 })
            out.append(InteractionRegion(
                source: .a11yVirtual,
                label: label,
                rects: [Rect(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height)]
            ))
        }
        return out
    }

    // MARK: - Channel 4: text markers (fallback)

    /// Paired "title/quote" delimiters used to mark an embedded link inside a
    /// self-drawn text run, across scripts — kept byte-identical in intent to
    /// the Android probe's BRACKET_PAIRS. Keep open/close distinct (no
    /// symmetric quotes, which can't be paired unambiguously by scanning).
    private static let bracketPairs: [(String, String)] = [
        ("《", "》"), // CJK double angle (book title)
        ("「", "」"), // CJK corner
        ("『", "』"), // CJK white corner
        ("【", "】"), // CJK lenticular
        ("«", "»"),  // European guillemets
    ]

    private static let markdownLink = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)]+)\)"#)

    private static func markerRegions(_ view: UIView, stack: TextLayoutStack) -> [InteractionRegion] {
        let text = stack.attributed.string as NSString
        guard text.length > 0 else { return [] }
        var out: [InteractionRegion] = []

        var markers: [NSRange] = []
        for (open, close) in bracketPairs {
            var search = NSRange(location: 0, length: text.length)
            while true {
                let o = text.range(of: open, options: [], range: search)
                if o.location == NSNotFound { break }
                let tailStart = o.location + o.length
                let c = text.range(of: close, options: [], range: NSRange(location: tailStart, length: text.length - tailStart))
                if c.location == NSNotFound { break }
                markers.append(NSRange(location: o.location, length: c.location + c.length - o.location))
                let next = c.location + c.length
                search = NSRange(location: next, length: text.length - next)
            }
        }
        markers.sort { $0.location < $1.location }
        for range in markers {
            out.append(InteractionRegion(
                source: .textMarker,
                label: text.substring(with: range),
                charStart: range.location,
                charEnd: range.location + range.length,
                rects: stack.screenRects(for: range, in: view)
            ))
        }

        if let markdownLink {
            let full = NSRange(location: 0, length: text.length)
            for m in markdownLink.matches(in: text as String, range: full) {
                out.append(InteractionRegion(
                    source: .textMarker,
                    label: text.substring(with: m.range(at: 1)),
                    target: text.substring(with: m.range(at: 2)),
                    charStart: m.range.location,
                    charEnd: m.range.location + m.range.length,
                    rects: stack.screenRects(for: m.range, in: view)
                ))
            }
        }
        return out
    }

    /// Structural link-marker check — a paired bracket or a markdown `](`.
    /// Never matches natural-language wording.
    private static func looksLikeEmbeddedLink(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        if text.contains("](") { return true }
        return bracketPairs.contains { open, close in
            if let o = text.range(of: open) {
                return text.range(of: close, range: o.upperBound..<text.endIndex) != nil
            }
            return false
        }
    }

    // MARK: - Char grid

    private static func charGrid(_ view: UIView, stack: TextLayoutStack) -> CharGrid? {
        let text = stack.attributed.string
        guard !text.isEmpty else { return nil }
        let (lines, approximate) = stack.charLines(in: view)
        if lines.isEmpty {
            return CharGrid(text: text, lines: [], approximate: true)
        }
        return CharGrid(text: text, lines: lines, approximate: approximate)
    }
}
#endif

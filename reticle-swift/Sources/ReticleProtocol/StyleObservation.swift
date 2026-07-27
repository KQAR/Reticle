import Foundation

/// Style observation — the Swift twin of reticle-core's `StyleObservation`.
/// Every rendering rule here must match that file line for line; the shared
/// fixture `reticle-protocol/fixtures/style-observation.cases.json` pins both.
///
/// This is deliberately NOT a comparison. Reticle does not know what the values
/// ought to be — a design frame, a previous build and a second device are all
/// equally valid things to hold this up against, and the threshold and the
/// exemption list ("ignore the status bar") are the consumer's policy, not an
/// observation. So the projection stops at the magnitudes and their provenance.
///
/// Two things it does do, because neither is guessable from the outside:
///
///  - **Units.** A raw length is meaningless without the screen it was measured
///    on, and the raw unit is not even the same on both platforms (see
///    `StyleUnits.lengthsAreDensityIndependent`). Each length is rendered in the
///    platform's own unit, in dp, and — for text — in sp.
///  - **Gaps.** A property Reticle cannot read is listed by name with a reason
///    instead of being absent, so "the app sets no corner radius" and "this
///    radius lives in a Compose draw modifier" stop looking identical.
public struct StyleObservation: Codable, Sendable {
    public var capturedAtMillis: Int64
    public var platform: String
    public var screen: ScreenInfo
    public var items: [StyleItem]

    public init(capturedAtMillis: Int64, platform: String, screen: ScreenInfo, items: [StyleItem]) {
        self.capturedAtMillis = capturedAtMillis
        self.platform = platform
        self.screen = screen
        self.items = items
    }

    /// The whole text projection: screen header, then one block per node that has
    /// style or a declared gap.
    ///
    /// It lives here rather than in each host renderer so the Kotlin helper and the
    /// Swift host cannot render the same snapshot differently — the failure mode
    /// this repo has already had twice. `style-observation.cases.json` pins the
    /// output of exactly this function on both sides.
    public func render() -> String {
        var out = [screenLine()]
        for item in items where item.hasInformativeStyle() {
            out.append(item.headerLine())
            out.append(contentsOf: item.bodyLines())
        }
        if out.count == 1 { out.append("(no style-bearing nodes in this snapshot)") }
        return out.joined(separator: "\n")
    }

    /// Screen header line: raw size, the divisors, and — where the raw unit is
    /// physical pixels — the same size in dp. On iOS the raw unit already IS
    /// density-independent, so no second figure is printed rather than printing
    /// one number twice under two names.
    public func screenLine() -> String {
        let d = screen.density
        let rawUnit = StyleUnits.lengthsAreDensityIndependent(platform) ? "pt" : "px"
        let dp = (rawUnit == "px" && d > 0)
            ? " -> \(StyleObservation.fmt(screen.size.width / d))x\(StyleObservation.fmt(screen.size.height / d))dp"
            : ""
        let scale = screen.fontScale.map { " fontScale=\(StyleObservation.fmt($0))" } ?? " fontScale=unprobed"
        return "screen: \(StyleObservation.fmt(screen.size.width))x\(StyleObservation.fmt(screen.size.height))\(rawUnit) "
            + "density=\(StyleObservation.fmt(d))\(scale)\(dp)"
    }

    /// Build from a snapshot, keeping nodes that carry a frame, a style property
    /// or a declared gap.
    ///
    /// Unlike `CompactObservation` this does NOT filter on `hasTargetingSignal()`
    /// or visibility: an unlabelled spacer container is exactly the kind of node a
    /// spacing question is about, and an invisible one still has a specified
    /// style. The compact view is for acting now; this one is for measuring.
    public static func from(_ snapshot: Snapshot, maxItems: Int = 500) -> StyleObservation {
        let units = StyleUnits(platform: snapshot.platform, screen: snapshot.screen)
        var items: [StyleItem] = []
        var seen = Set<String>()
        func visit(_ ref: String) {
            guard !seen.contains(ref), let node = snapshot.nodes[ref] else { return }
            seen.insert(ref)
            let attributes = node.styleChannels.compactMap { name, channel -> StyleAttribute? in
                guard let value = node.custom[name],
                      !StyleUnits.isUninformativeDefault(name, value) else { return nil }
                return StyleAttribute(
                    name: name,
                    value: value,
                    unit: StyleUnits.unitOf(name),
                    channel: channel,
                    rendered: units.render(name, value)
                )
            }.sorted { $0.name < $1.name }
            let gaps = node.styleGaps.sorted { $0.key < $1.key }
                .map { StyleGap(property: $0.key, reason: $0.value) }
            if node.frame != nil || !attributes.isEmpty || !gaps.isEmpty {
                items.append(StyleItem(
                    ref: node.ref,
                    role: node.role ?? node.typeName,
                    testId: node.testId,
                    resourceId: node.resourceId,
                    label: node.text ?? node.contentDescription,
                    frame: node.frame,
                    frameRendered: node.frame.map { units.renderFrame($0) },
                    attributes: attributes,
                    gaps: gaps
                ))
            }
            for child in node.children { visit(child) }
        }
        visit(snapshot.rootRef)
        return StyleObservation(
            capturedAtMillis: snapshot.capturedAtMillis,
            platform: snapshot.platform,
            screen: snapshot.screen,
            items: Array(items.prefix(maxItems))
        )
    }

    /// One decimal, trailing `.0` dropped. `%.1f` is locale-independent here,
    /// matching the Kotlin twin's explicit `Locale.ROOT`.
    static func fmt(_ value: Double) -> String {
        let rounded = String(format: "%.1f", value)
        return rounded.hasSuffix(".0") ? String(rounded.dropLast(2)) : rounded
    }
}

/// One node's geometry + style, as rendered for a text projection.
public struct StyleItem: Codable, Sendable {
    public var ref: String
    public var role: String
    public var testId: String?
    public var resourceId: String?
    public var label: String?
    public var frame: Rect?
    /// Multi-unit rendering of `frame`; nil when the node has no frame.
    public var frameRendered: String?
    public var attributes: [StyleAttribute]
    public var gaps: [StyleGap]

    public init(
        ref: String,
        role: String,
        testId: String? = nil,
        resourceId: String? = nil,
        label: String? = nil,
        frame: Rect? = nil,
        frameRendered: String? = nil,
        attributes: [StyleAttribute] = [],
        gaps: [StyleGap] = []
    ) {
        self.ref = ref
        self.role = role
        self.testId = testId
        self.resourceId = resourceId
        self.label = label
        self.frame = frame
        self.frameRendered = frameRendered
        self.attributes = attributes
        self.gaps = gaps
    }

    /// True when this node has something to say: a property off its platform
    /// default, or a declared gap.
    ///
    /// The text projection skips the rest. An Android `ViewGroup` reports four
    /// paddings and an elevation whether or not anyone set them, so wrappers with
    /// nothing but zeros produced a seven-line block each and made the view
    /// unreadable (measured on a real device, on the sample's own home screen). Note
    /// what this is NOT: once a node is kept, ALL its properties print, zeros
    /// included — "the app sets padding 0 and the design says 16" is exactly the
    /// finding this projection exists to support. And `attributes` keeps everything
    /// either way, so a structured consumer never sees this filter at all.
    public func hasInformativeStyle() -> Bool {
        !gaps.isEmpty || attributes.contains { !StyleUnits.isDefaultValued($0.name, $0.value) }
    }

    /// Header line for this node: selector, role, label.
    public func headerLine() -> String {
        let selector = testId.map { "#\($0)" } ?? resourceId.map { "@\($0)" } ?? ref
        let labelPart = label.map { " \"\(String($0.prefix(40)))\"" } ?? ""
        return "\(selector) \(role)\(labelPart)"
    }

    /// The indented body: frame, then each attribute, then each gap.
    public func bodyLines() -> [String] {
        var out: [String] = []
        if let frameRendered { out.append("    frame  \(frameRendered)") }
        let width = attributes.map { $0.name.count }.max() ?? 0
        for a in attributes {
            let padded = a.name.padding(toLength: max(width, a.name.count), withPad: " ", startingAt: 0)
            out.append("    \(padded)  \(a.rendered)  [\(a.channel.rawValue)]")
        }
        for g in gaps { out.append("    ! \(g.property)  unreadable: \(g.reason)") }
        return out
    }
}

/// One style property: the raw value, its unit, its provenance, its rendering.
public struct StyleAttribute: Codable, Sendable {
    public var name: String
    public var value: MetadataValue
    public var unit: StyleUnit
    public var channel: StyleChannel
    /// Human-facing multi-unit rendering, e.g. "42px | 14dp | 14sp".
    public var rendered: String

    public init(name: String, value: MetadataValue, unit: StyleUnit, channel: StyleChannel, rendered: String) {
        self.name = name
        self.value = value
        self.unit = unit
        self.channel = channel
        self.rendered = rendered
    }
}

/// A style property that exists on screen but which no channel can read.
public struct StyleGap: Codable, Sendable {
    public var property: String
    public var reason: String

    public init(property: String, reason: String) {
        self.property = property
        self.reason = reason
    }
}

/// What kind of quantity a style property holds — which decides whether a unit
/// conversion is meaningful at all. Twin of reticle-core's `StyleUnit`.
///
/// Only `length` and `textLength` are converted. Everything else passes through
/// verbatim, including `opaque`, which is the honest answer for a value whose
/// unit Reticle does not know (a `getComputedStyle` string carries its own suffix
/// and a page's zoom is not observable from here, so converting it would be
/// arithmetic on an assumption).
public enum StyleUnit: String, Codable, Sendable {
    /// A device length: rendered in the platform's raw unit and dp.
    case length
    /// A text length: rendered in raw, dp AND sp, since font scaling applies.
    case textLength
    /// An ARGB hex string.
    case color
    /// A named constant (`center`, `italic`, `sans-serif`).
    case keyword
    /// A unitless 0..1 fraction.
    case ratio
    /// A unitless integer (font weight, line count).
    case count
    /// Unit unknown to the table — passed through, never converted.
    case opaque
}

/// The property-name -> `StyleUnit` table plus the conversions. Twin of
/// reticle-core's `StyleUnits`; the table must stay identical on both sides.
///
/// The table is code rather than wire data because the name already determines
/// the kind: emitting a unit tag per property would be a second copy of this
/// knowledge, free to drift from the first. Names not in the table render as
/// `opaque` — a new capture surface degrades to "shown verbatim" instead of to a
/// wrong conversion.
public struct StyleUnits {
    private let platform: String
    private let screen: ScreenInfo

    public init(platform: String, screen: ScreenInfo) {
        self.platform = platform
        self.screen = screen
    }

    /// True when this platform's view geometry is ALREADY density-independent, so
    /// a px->dp division would scale it twice. UIKit measures in points; the
    /// Android view tree measures in physical pixels.
    public static func lengthsAreDensityIndependent(_ platform: String) -> Bool {
        platform == "ios"
    }

    private static let table: [String: StyleUnit] = [
        "textSize": .textLength,
        "lineHeight": .textLength,
        "letterSpacing": .textLength,
        "paddingLeft": .length,
        "paddingTop": .length,
        "paddingRight": .length,
        "paddingBottom": .length,
        "cornerRadius": .length,
        "borderWidth": .length,
        "elevation": .length,
        "textColor": .color,
        "backgroundColor": .color,
        "borderColor": .color,
        "tintColor": .color,
        "linkTextColor": .color,
        "textAlign": .keyword,
        "fontFamily": .keyword,
        "fontStyle": .keyword,
        "visibility": .keyword,
        "alpha": .ratio,
        "fontWeight": .count,
        "maxLines": .count,
    ]

    public static func unitOf(_ name: String) -> StyleUnit { table[name] ?? .opaque }

    /// True for the two properties every platform view carries at a value that
    /// says nothing at all: full opacity and ordinary visibility. These are dropped
    /// from the output entirely.
    ///
    /// Measured, not guessed at: on a real iOS screen these two turned a 40-node
    /// capture into 120 lines of `alpha 1.0`, burying the handful of nodes that had
    /// style of their own.
    public static func isUninformativeDefault(_ name: String, _ value: MetadataValue) -> Bool {
        switch name {
        case "alpha": return value.asDouble() == 1.0
        case "visibility":
            if case .text(let v) = value { return v == "visible" }
            return false
        default: return false
        }
    }

    /// True when a property is sitting at its platform default, so it says nothing
    /// **on its own** — every zero length included.
    ///
    /// This decides whether a NODE is worth printing, not whether a property is, and
    /// the difference is the whole point: see `StyleItem.hasInformativeStyle`.
    public static func isDefaultValued(_ name: String, _ value: MetadataValue) -> Bool {
        if isUninformativeDefault(name, value) { return true }
        switch unitOf(name) {
        case .length, .textLength, .count: return value.asDouble() == 0.0
        default: return false
        }
    }

    private var densityDivisor: Double {
        if StyleUnits.lengthsAreDensityIndependent(platform) { return 1.0 }
        return screen.density > 0 ? screen.density : 1.0
    }

    private var rawUnit: String {
        StyleUnits.lengthsAreDensityIndependent(platform) ? "pt" : "px"
    }

    /// Render one property value in every unit that applies to it.
    public func render(_ name: String, _ value: MetadataValue) -> String {
        switch StyleUnits.unitOf(name) {
        case .length: return lengths(value)
        case .textLength: return textLengths(value)
        default: return value.displayString()
        }
    }

    /// `24,1800 1032x120px | 8,600 344x40dp | 95.6%x5% of screen`
    public func renderFrame(_ frame: Rect) -> String {
        let f = StyleObservation.fmt
        let px = "\(f(frame.x)),\(f(frame.y)) \(f(frame.width))x\(f(frame.height))\(rawUnit)"
        let d = densityDivisor
        let dp = rawUnit == "px"
            ? " | \(f(frame.x / d)),\(f(frame.y / d)) \(f(frame.width / d))x\(f(frame.height / d))dp"
            : ""
        let share = (screen.size.width > 0 && screen.size.height > 0)
            ? " | \(pct(frame.width / screen.size.width))x\(pct(frame.height / screen.size.height)) of screen"
            : ""
        return px + dp + share
    }

    private func lengths(_ value: MetadataValue) -> String {
        guard let raw = value.asDouble() else { return value.displayString() }
        let base = "\(StyleObservation.fmt(raw))\(rawUnit)"
        if rawUnit == "pt" { return base }
        return "\(base) | \(StyleObservation.fmt(raw / densityDivisor))dp"
    }

    private func textLengths(_ value: MetadataValue) -> String {
        guard let raw = value.asDouble() else { return value.displayString() }
        let base = lengths(value)
        // sp divides out font scaling as well as density, recovering the size the
        // app asked for. Unprobed font scale means the two cannot be told apart —
        // say so rather than printing dp twice under different names.
        guard let scale = screen.fontScale else {
            return "\(base) | sp:unprobed (no fontScale in this capture)"
        }
        if scale <= 0 { return base }
        return "\(base) | \(StyleObservation.fmt(raw / densityDivisor / scale))sp"
    }

    private func pct(_ fraction: Double) -> String { "\(StyleObservation.fmt(fraction * 100))%" }
}

extension MetadataValue {
    fileprivate func asDouble() -> Double? {
        switch self {
        case .real(let v): return v
        case .integer(let v): return Double(v)
        default: return nil
        }
    }
}

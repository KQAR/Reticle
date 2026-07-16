import Foundation

/// Discovery channel for a sub-node interaction region. Mirrors reticle-core's
/// `RegionSource`.
public enum RegionSource: String, Codable, Sendable {
    case span
    case a11yVirtual
    case touchDelegate
    case textMarker
    case colorSpan
}

/// Sub-node interaction evidence: the answer to "a single view carries more than
/// one tappable region". Mirrors reticle-core's `InteractionRegion`.
public struct InteractionRegion: Codable, Sendable {
    public var source: RegionSource
    public var label: String?
    public var target: String?
    public var charStart: Int?
    public var charEnd: Int?
    public var rects: [Rect]
    public var color: String?

    public init(
        source: RegionSource,
        label: String? = nil,
        target: String? = nil,
        charStart: Int? = nil,
        charEnd: Int? = nil,
        rects: [Rect] = [],
        color: String? = nil
    ) {
        self.source = source
        self.label = label
        self.target = target
        self.charStart = charStart
        self.charEnd = charEnd
        self.rects = rects
        self.color = color
    }

    /// Best single tap point for this region: center of the first rect.
    public func tapPoint() -> Point? {
        rects.first.map { Point(x: $0.centerX, y: $0.centerY) }
    }

    private enum CodingKeys: String, CodingKey {
        case source, label, target, charStart, charEnd, rects, color
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(target, forKey: .target)
        try c.encodeIfPresent(charStart, forKey: .charStart)
        try c.encodeIfPresent(charEnd, forKey: .charEnd)
        if !rects.isEmpty { try c.encode(rects, forKey: .rects) }
        try c.encodeIfPresent(color, forKey: .color)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(RegionSource.self, forKey: .source)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        target = try c.decodeIfPresent(String.self, forKey: .target)
        charStart = try c.decodeIfPresent(Int.self, forKey: .charStart)
        charEnd = try c.decodeIfPresent(Int.self, forKey: .charEnd)
        rects = try c.decodeIfPresent([Rect].self, forKey: .rects) ?? []
        color = try c.decodeIfPresent(String.self, forKey: .color)
    }
}

/// Character-position grid for a text node. Mirrors reticle-core's `CharGrid`.
public struct CharGrid: Codable, Sendable {
    public var text: String
    public var lines: [CharLine]
    public var approximate: Bool

    public init(text: String, lines: [CharLine], approximate: Bool = false) {
        self.text = text
        self.lines = lines
        self.approximate = approximate
    }

    public func rangeRects(start: Int, end: Int) -> [Rect] {
        lines.compactMap { $0.subRange(start, end) }
    }

    private enum CodingKeys: String, CodingKey { case text, lines, approximate }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(lines, forKey: .lines)
        if approximate { try c.encode(approximate, forKey: .approximate) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        lines = try c.decode([CharLine].self, forKey: .lines)
        approximate = try c.decodeIfPresent(Bool.self, forKey: .approximate) ?? false
    }
}

public struct CharLine: Codable, Sendable {
    public var line: Int
    public var start: Int
    public var end: Int
    public var top: Double
    public var bottom: Double
    public var xOffsets: [Double]

    public init(line: Int, start: Int, end: Int, top: Double, bottom: Double, xOffsets: [Double]) {
        self.line = line
        self.start = start
        self.end = end
        self.top = top
        self.bottom = bottom
        self.xOffsets = xOffsets
    }

    /// The rect for the intersection of [a, b) with this line, or nil.
    public func subRange(_ a: Int, _ b: Int) -> Rect? {
        let s = max(a, start)
        let e = min(b, end)
        if s >= e || xOffsets.count < 2 { return nil }
        let i0 = min(max(s - start, 0), xOffsets.count - 1)
        let i1 = min(max(e - start, 0), xOffsets.count - 1)
        let lo = xOffsets[i0]
        let hi = xOffsets[i1]
        return Rect(x: min(lo, hi), y: top, width: abs(hi - lo), height: bottom - top)
    }
}

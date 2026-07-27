import Foundation

/// Geometry primitives: size, point, and rect on the wire. Field names and
/// shapes mirror `reticle-core`'s Geometry.kt exactly.
public struct Size: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct Point: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct Rect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var centerX: Double { x + width / 2.0 }
    public var centerY: Double { y + height / 2.0 }

    public func contains(_ px: Double, _ py: Double) -> Bool {
        px >= x && px <= x + width && py >= y && py <= y + height
    }

    /// Whether this is a rectangle a screen could actually have: every component
    /// real, finite, and inside the whole-number range a rect is rendered in.
    ///
    /// UIKit uses `CGRectInfinite` / `CGRectNull` as sentinels for "no geometry"
    /// (a `UIScrollView`'s hidden scroll indicator is one), and a capture can pick
    /// one up as a view frame. Note that those sentinels are **finite** doubles —
    /// ±`CGFloat.greatestFiniteMagnitude`, around 1.8e308 — so `Double.isFinite`
    /// says yes to them while `Int(_:)` still traps. That gap is exactly the bug
    /// this guards: the check has to be about the representable range, not about
    /// infinity. The agent drops such a frame rather than reporting it, but a
    /// snapshot written by an older agent may still carry one, so every renderer
    /// must survive reading it.
    public var isRepresentable: Bool {
        Rect.representable(x) && Rect.representable(y)
            && Rect.representable(width) && Rect.representable(height)
    }

    private static func representable(_ value: Double) -> Bool {
        value.isFinite && value > Double(Int.min) && value < Double(Int.max)
    }

    /// `x,y WxH` with whole-number components — the one spelling every renderer
    /// uses for a rect.
    ///
    /// Rounding goes through a saturating conversion because `Int(someDouble)`
    /// **traps** on a value outside `Int`'s range: formatting a `CGRectInfinite`
    /// frame used to abort the whole host process (SIGTRAP) while printing an
    /// action trace. A sentinel rect is bad evidence; it is not a reason to lose
    /// the report that carries it.
    public var intDescription: String {
        "\(Rect.whole(x)),\(Rect.whole(y)) \(Rect.whole(width))x\(Rect.whole(height))"
    }

    /// A comma-joined variant (`x,y,WxH`) for the wait-predicate evidence lines.
    public var commaIntDescription: String {
        "\(Rect.whole(x)),\(Rect.whole(y)),\(Rect.whole(width))x\(Rect.whole(height))"
    }

    /// `Int` if the value fits, clamped to the representable range otherwise, and
    /// `0` for NaN. Never traps.
    public static func whole(_ value: Double) -> Int {
        guard !value.isNaN else { return 0 }
        if value >= Double(Int.max) { return Int.max }
        if value <= Double(Int.min) { return Int.min }
        return Int(value)
    }
}

public struct ScreenInfo: Codable, Equatable, Sendable {
    public var size: Size
    /// Display density. On iOS this is `UIScreen.scale`.
    public var density: Double
    /// System font-scale multiplier at capture time (Android
    /// `Configuration.fontScale`; on iOS the Dynamic Type scale of a body font),
    /// or nil when the platform did not probe it.
    ///
    /// Without it a raw text size cannot be split into the two questions a
    /// consumer actually asks: *is this the size the design specifies* (compare in
    /// dp, which divides out `density` only) and *is the user scaling text right
    /// now* (compare in sp, which divides out both). Guessing 1.0 turns "the user
    /// enlarged text" into "the app got the font size wrong".
    public var fontScale: Double?
    /// "light" | "dark".
    public var interfaceStyle: String?
    /// System keyboard (IME) state at capture time, or nil when the platform
    /// did not probe it. The keyboard is another process's window, so it never
    /// appears in the node tree — this is the only record that part of the
    /// screen is covered. (Currently filled by the Android agent.)
    public var keyboard: KeyboardInfo?
    /// Does this app's top window still hold input focus? Nil when unprobed.
    ///
    /// The honest answer to the one on-screen thing an in-process agent cannot
    /// see: a system permission prompt, a biometric sheet or an autofill dialog
    /// belongs to another process, so it appears in no window of this app and no
    /// node of this tree — a capture taken while one is up looks like an ordinary
    /// screen with every control still "tappable". This does not reveal what is on
    /// top; it reports that something is.
    public var windowFocused: Bool?

    public init(
        size: Size,
        density: Double,
        fontScale: Double? = nil,
        interfaceStyle: String? = nil,
        keyboard: KeyboardInfo? = nil,
        windowFocused: Bool? = nil
    ) {
        self.size = size
        self.density = density
        self.fontScale = fontScale
        self.interfaceStyle = interfaceStyle
        self.keyboard = keyboard
        self.windowFocused = windowFocused
    }
}

public struct KeyboardInfo: Codable, Equatable, Sendable {
    public var visible: Bool
    /// Screen-coordinate rect the keyboard occupies; nil when hidden or unknown.
    public var frame: Rect?

    public init(visible: Bool, frame: Rect? = nil) {
        self.visible = visible
        self.frame = frame
    }
}

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

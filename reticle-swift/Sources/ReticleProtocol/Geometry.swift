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
    /// "light" | "dark".
    public var interfaceStyle: String?
    /// System keyboard (IME) state at capture time, or nil when the platform
    /// did not probe it. The keyboard is another process's window, so it never
    /// appears in the node tree — this is the only record that part of the
    /// screen is covered. (Currently filled by the Android agent.)
    public var keyboard: KeyboardInfo?

    public init(size: Size, density: Double, interfaceStyle: String? = nil, keyboard: KeyboardInfo? = nil) {
        self.size = size
        self.density = density
        self.interfaceStyle = interfaceStyle
        self.keyboard = keyboard
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

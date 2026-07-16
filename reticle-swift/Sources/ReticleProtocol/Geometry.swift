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

    public init(size: Size, density: Double, interfaceStyle: String? = nil) {
        self.size = size
        self.density = density
        self.interfaceStyle = interfaceStyle
    }
}

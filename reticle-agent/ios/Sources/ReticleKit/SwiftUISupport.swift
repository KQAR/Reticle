import Foundation
import ReticleProtocol
#if canImport(UIKit)
import UIKit

/// SwiftUI boundary handling — the iOS analogue of the Android Compose-semantics
/// bridge. The rule matches: Reticle does NOT synthesize a SwiftUI view tree or
/// invent selectors from private SwiftUI backing views. A SwiftUI element is
/// addressable only through the natively-exposed accessibility elements. Every
/// inference carries an `evidence` list saying why.
@MainActor
enum SwiftUISupport {
    /// Peripheral signals that a UIView is a SwiftUI hosting surface. Never keys
    /// on private SwiftUI view class internals for *selectors* — only to decide
    /// whether to read the accessibility elements.
    static func hostingEvidence(for view: UIView) -> [String] {
        var evidence: [String] = []
        let cls = String(describing: type(of: view))
        if cls.contains("Hosting") || cls.contains("UIHosting") || cls.contains("PlatformView") {
            evidence.append("backingTypeName")
        }
        let bundleId = Bundle(for: type(of: view)).bundleIdentifier ?? ""
        if bundleId == "com.apple.SwiftUI" || bundleId == "com.apple.SwiftUICore" {
            evidence.append("frameworkBundleIdentifier")
        }
        if let vc = view.reticleOwningViewController {
            let vcName = String(describing: type(of: vc))
            if vcName.contains("Hosting") { evidence.append("hostingController") }
        }
        return evidence
    }

    static func isHosting(_ view: UIView) -> Bool {
        !hostingEvidence(for: view).isEmpty
    }

    /// Read a hosting view's accessibility elements in ONE pass. `accessibilityElements`
    /// is preferred; the private `_accessibilityElements` accessor is a fallback that
    /// keeps this O(N) on large SwiftUI containers where per-index enumeration is
    /// O(N^2) and can hang. Guards the `CGDrawingView` case where
    /// `accessibilityElementCount()` returns NSNotFound.
    static func accessibilityElements(of view: NSObject) -> [NSObject] {
        if let elements = view.value(forKey: "accessibilityElements") as? [Any] {
            return elements.compactMap { $0 as? NSObject }
        }
        // Private fast path: one array read instead of accessibilityElement(at:).
        let sel = NSSelectorFromString("_accessibilityElements")
        if view.responds(to: sel), let raw = view.perform(sel)?.takeUnretainedValue() as? [Any] {
            return raw.compactMap { $0 as? NSObject }
        }
        // Last resort: bounded index enumeration, with the NSNotFound guard.
        let count = view.accessibilityElementCount()
        if count == NSNotFound || count <= 0 { return [] }
        var out: [NSObject] = []
        for i in 0..<count {
            if let e = view.accessibilityElement(at: i) as? NSObject { out.append(e) }
        }
        return out
    }

    /// A role name for a synthesized SwiftUI element, from its accessibility traits.
    static func role(for traits: UIAccessibilityTraits) -> String {
        if traits.contains(.button) { return "button" }
        if traits.contains(.link) { return "link" }
        if traits.contains(.image) { return "image" }
        if traits.contains(.header) { return "header" }
        if traits.contains(.searchField) { return "textField" }
        if traits.contains(.adjustable) { return "adjustable" }
        if traits.contains(.staticText) { return "text" }
        return "element"
    }

    /// SwiftUI-ish type name from a role, for `Node.typeName` (e.g. "SwiftUI.Button").
    static func typeName(for role: String) -> String {
        switch role {
        case "button": return "SwiftUI.Button"
        case "link": return "SwiftUI.Link"
        case "image": return "SwiftUI.Image"
        case "header": return "SwiftUI.Text"
        case "text": return "SwiftUI.Text"
        case "textField": return "SwiftUI.TextField"
        default: return "SwiftUI.Element"
        }
    }

    /// Optional, default-off Mirror reflection of the first user `View`'s scalar
    /// @State, surfaced as evidence-tagged metadata (never as a selector). Enabled
    /// by RETICLE_SWIFTUI_REFLECT=1. Uses only Swift `Mirror` — no SwiftUI private API.
    static func reflectState(of view: UIView) -> [String: MetadataValue] {
        guard ProcessInfo.processInfo.environment["RETICLE_SWIFTUI_REFLECT"] == "1" else { return [:] }
        guard let userView = firstUserView(reflecting: view, depth: 0, visited: NSHashTable.weakObjects()) else { return [:] }
        var out: [String: MetadataValue] = [:]
        var count = 0
        for child in Mirror(reflecting: userView).children {
            guard count < 16, let label = child.label else { continue }
            let clean = cleanPropertyName(label)
            if let scalar = scalarMetadata(child.value) {
                out["state.\(clean)"] = scalar
                count += 1
            }
        }
        if !out.isEmpty { out["swiftUIReflectionEvidence"] = .text("privateReflection") }
        return out
    }

    // MARK: - Mirror helpers

    private static func firstUserView(reflecting object: Any, depth: Int, visited: NSHashTable<AnyObject>) -> Any? {
        if depth > 10 { return nil }
        let typeName = String(reflecting: type(of: object))
        if isUserViewType(typeName) { return object }
        let mirror = Mirror(reflecting: object)
        var seen = 0
        for child in mirror.children {
            guard seen < 24 else { break }
            seen += 1
            if let found = firstUserView(reflecting: child.value, depth: depth + 1, visited: visited) {
                return found
            }
        }
        return nil
    }

    private static func isUserViewType(_ fqName: String) -> Bool {
        let lower = fqName.lowercased()
        if lower.hasPrefix("swiftui.") || lower.hasPrefix("uikit.") || lower.hasPrefix("foundation.") { return false }
        guard let leaf = fqName.split(separator: ".").last.map(String.init) else { return false }
        if leaf.hasPrefix("_") || leaf.hasPrefix("UI") || leaf.hasPrefix("NS") { return false }
        return leaf.hasSuffix("View") || leaf.hasSuffix("Screen") || leaf.hasSuffix("Route")
    }

    private static func cleanPropertyName(_ name: String) -> String {
        var n = name
        if let r = n.range(of: "$__lazy_storage_$_") { n.removeSubrange(r) }
        while n.hasPrefix("_") { n.removeFirst() }
        return n
    }

    private static func scalarMetadata(_ value: Any) -> MetadataValue? {
        switch value {
        case let v as Bool: return .bool(v)
        case let v as Int: return .integer(Int64(v))
        case let v as Int64: return .integer(v)
        case let v as Double: return .real(v)
        case let v as CGFloat: return .real(Double(v))
        case let v as String: return .text(v)
        default: return nil
        }
    }
}

extension UIView {
    /// The view controller that owns this view, if any (walks the responder chain).
    @MainActor
    var reticleOwningViewController: UIViewController? {
        var responder: UIResponder? = self
        while let r = responder {
            if let vc = r as? UIViewController { return vc }
            responder = r.next
        }
        return nil
    }
}
#endif

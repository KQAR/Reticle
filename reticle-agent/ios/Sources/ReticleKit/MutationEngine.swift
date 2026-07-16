import Foundation
import ReticleProtocol
#if canImport(UIKit)
import UIKit

/// Allowlisted runtime mutation — the iOS analogue of the Android
/// `MutationEngine`. Only a bounded set of view properties may be patched live;
/// arbitrary selector/KVC writes are refused. The result carries the previous
/// value, and when UIKit's layout snaps the property back the `message` reports
/// the effective value (requested-vs-effective honesty).
@MainActor
struct MutationEngine {
    private static let allowed: Set<String> = [
        "alpha", "isHidden", "visibility", "backgroundColor", "tintColor",
        "text", "isEnabled", "cornerRadius",
    ]

    func apply(_ request: MutationRequest) -> MutationResult {
        let property = request.property
        guard MutationEngine.allowed.contains(property) else {
            return MutationResult(applied: false, message: "property '\(property)' is not in the mutation allowlist")
        }
        let (snapshot, index) = SnapshotCapture().captureWithIndex()
        guard let (ref, view) = resolve(request.selector, snapshot: snapshot, index: index) else {
            return MutationResult(applied: false, message: "no view matched selector \(request.selector.describe())")
        }

        let previous = read(property, from: view)
        do {
            try write(property, request.value, to: view)
        } catch {
            return MutationResult(applied: false, ref: ref, previousValue: previous, message: "\(error)")
        }
        view.setNeedsLayout()

        // Read the value back: if UIKit reverted it, say so rather than claiming success.
        let effective = read(property, from: view)
        var message: String?
        if let effective, effective != request.value {
            message = "effective value differs from requested: \(effective.displayString())"
        }
        return MutationResult(applied: true, ref: ref, previousValue: previous, message: message)
    }

    // MARK: - Resolution

    private func resolve(_ selector: ReticleProtocol.Selector, snapshot: Snapshot, index: [String: UIView]) -> (String, UIView)? {
        if let testId = selector.testId {
            for (ref, node) in snapshot.nodes where node.testId == testId {
                if let view = index[ref] { return (ref, view) }
            }
        }
        if let resourceId = selector.resourceId {
            for (ref, node) in snapshot.nodes where node.resourceId == resourceId {
                if let view = index[ref] { return (ref, view) }
            }
        }
        if let ref = selector.ref, let view = index[ref] {
            return (ref, view)
        }
        if let point = selector.point {
            // Deepest hit at the point, across windows top-to-bottom.
            let cg = CGPoint(x: point.x, y: point.y)
            for (ref, view) in index.sorted(by: { $0.key > $1.key }) {
                if let window = view.window {
                    let local = window.convert(cg, to: view)
                    if view.point(inside: local, with: nil) && view.subviews.isEmpty {
                        return (ref, view)
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Read / write

    private func read(_ property: String, from view: UIView) -> MetadataValue? {
        switch property {
        case "alpha": return .real(Double(view.alpha))
        case "isHidden", "visibility": return .bool(view.isHidden)
        case "backgroundColor": return view.backgroundColor.map { .text(hex($0, view.traitCollection)) }
        case "tintColor": return view.tintColor.map { .text(hex($0, view.traitCollection)) }
        case "isEnabled": return .bool((view as? UIControl)?.isEnabled ?? true)
        case "cornerRadius": return .real(Double(view.layer.cornerRadius))
        case "text":
            if let l = view as? UILabel { return l.text.map { .text($0) } }
            if let b = view as? UIButton { return b.currentTitle.map { .text($0) } }
            if let f = view as? UITextField { return f.text.map { .text($0) } }
            if let t = view as? UITextView { return .text(t.text) }
            return nil
        default: return nil
        }
    }

    private func write(_ property: String, _ value: MetadataValue, to view: UIView) throws {
        switch property {
        case "alpha":
            view.alpha = CGFloat(try doubleValue(value))
        case "isHidden", "visibility":
            view.isHidden = try boolValue(value)
        case "backgroundColor":
            view.backgroundColor = try color(value)
        case "tintColor":
            view.tintColor = try color(value)
        case "cornerRadius":
            view.layer.cornerRadius = CGFloat(try doubleValue(value))
            view.layer.masksToBounds = true
        case "isEnabled":
            (view as? UIControl)?.isEnabled = try boolValue(value)
        case "text":
            let s = try stringValue(value)
            if let l = view as? UILabel { l.text = s }
            else if let b = view as? UIButton { b.setTitle(s, for: .normal) }
            else if let f = view as? UITextField { f.text = s }
            else if let t = view as? UITextView { t.text = s }
            else { throw MutationError.notTextView }
        default:
            throw MutationError.unsupported(property)
        }
    }

    // MARK: - Coercion

    private func doubleValue(_ v: MetadataValue) throws -> Double {
        switch v {
        case .real(let d): return d
        case .integer(let i): return Double(i)
        case .text(let s): if let d = Double(s) { return d }; throw MutationError.badValue
        default: throw MutationError.badValue
        }
    }

    private func boolValue(_ v: MetadataValue) throws -> Bool {
        switch v {
        case .bool(let b): return b
        case .text(let s): return (s as NSString).boolValue
        case .integer(let i): return i != 0
        default: throw MutationError.badValue
        }
    }

    private func stringValue(_ v: MetadataValue) throws -> String {
        if case .text(let s) = v { return s }
        return v.displayString()
    }

    private func color(_ v: MetadataValue) throws -> UIColor {
        guard case .text(let s) = v, let c = UIColor(reticleHex: s) else { throw MutationError.badColor }
        return c
    }

    private func hex(_ color: UIColor, _ traits: UITraitCollection) -> String {
        let resolved = color.resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ x: CGFloat) -> Int { max(0, min(255, Int((x * 255.0).rounded()))) }
        return String(format: "#%02X%02X%02X%02X", c(a), c(r), c(g), c(b))
    }

    enum MutationError: Error, CustomStringConvertible {
        case unsupported(String), badValue, badColor, notTextView
        var description: String {
            switch self {
            case .unsupported(let p): return "unsupported property '\(p)'"
            case .badValue: return "value not coercible for this property"
            case .badColor: return "expected an #AARRGGBB / #RRGGBB color string"
            case .notTextView: return "target does not carry text"
            }
        }
    }
}

extension UIColor {
    /// Parse #RRGGBB or #AARRGGBB.
    convenience init?(reticleHex: String) {
        var s = reticleHex
        if s.hasPrefix("#") { s.removeFirst() }
        guard let value = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        switch s.count {
        case 6:
            a = 1.0
            r = CGFloat((value >> 16) & 0xFF) / 255.0
            g = CGFloat((value >> 8) & 0xFF) / 255.0
            b = CGFloat(value & 0xFF) / 255.0
        case 8:
            a = CGFloat((value >> 24) & 0xFF) / 255.0
            r = CGFloat((value >> 16) & 0xFF) / 255.0
            g = CGFloat((value >> 8) & 0xFF) / 255.0
            b = CGFloat(value & 0xFF) / 255.0
        default:
            return nil
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}
#endif

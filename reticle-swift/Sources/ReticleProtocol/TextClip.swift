import Foundation

/// Clip for the render projections, counted in CODE POINTS — the Swift half of
/// reticle-core's `clipCodePoints`.
///
/// Swift's `prefix(n)` counts grapheme clusters and Kotlin's `take(n)` counts
/// UTF-16 units; the two ports agree on ASCII and quietly disagree on CJK and
/// emoji (a multi-scalar emoji is ONE grapheme here and several UTF-16 units
/// there). The trace layer already learned this (`clipIdentityText`); this is
/// the same rule for every `prefix(30/40)` the renderers do. A Unicode scalar
/// is exactly one code point on the Kotlin side, so both languages count the
/// same thing.
extension String {
    func clipCodePoints(_ max: Int) -> String {
        let scalars = unicodeScalars
        guard scalars.count > max else { return self }
        return String(String.UnicodeScalarView(scalars.prefix(max)))
    }
}

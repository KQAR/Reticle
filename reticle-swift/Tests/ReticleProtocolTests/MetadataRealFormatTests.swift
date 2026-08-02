import Testing
@testable import ReticleProtocol

/// `MetadataValue.displayString()` feeds `verify --custom` matching and trace
/// diffs, so a `real` has to spell the same on both agents. The expectations
/// here are Kotlin's `Double.toString()` output verbatim — the Kotlin twin of
/// this suite (`MetadataRealFormatTest`) asserts the same table against the
/// real thing, so a divergence fails on one side or the other.
@Suite("Canonical real formatting")
struct MetadataRealFormatTests {
    @Test func matchesTheKotlinSpelling() {
        let table: [(Double, String)] = [
            (0, "0.0"),
            (-0.0, "-0.0"),
            (1, "1.0"),
            (-1, "-1.0"),
            (3.5, "3.5"),
            (1234.5, "1234.5"),
            (0.001, "0.001"),
            (-0.001, "-0.001"),
            (0.0001, "1.0E-4"),
            (1e-5, "1.0E-5"),
            (1.5e-7, "1.5E-7"),
            (9999999.0, "9999999.0"),
            (1e7, "1.0E7"),
            (1.23e10, "1.23E10"),
            (1e17, "1.0E17"),
            (-1e17, "-1.0E17"),
            (1.7976931348623157e308, "1.7976931348623157E308"),
            (Double.infinity, "Infinity"),
            (-Double.infinity, "-Infinity"),
            (Double.nan, "NaN"),
        ]
        for (value, expected) in table {
            #expect(MetadataValue.real(value).displayString() == expected,
                    "\(value) spelled \(MetadataValue.real(value).displayString())")
        }
    }

    @Test func staysRoundTrippable() {
        // Re-dressing the digits must not drop or invent any: every finite
        // spelling parses back to the value it came from.
        for value in [0.1, 1.0 / 3.0, 1e-300, 1e300, 123456.789, -2.5e-8, 6.02214076e23] {
            let text = MetadataValue.canonicalRealString(value)
            #expect(Double(text) == value, "\(value) -> \(text)")
        }
    }
}

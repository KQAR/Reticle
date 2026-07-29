import Foundation
import Testing
@testable import ReticleHostCore
@testable import ReticleHostShared

/// `HelperMethod` against the authority it copies: the method table in
/// `reticle-protocol/helper-rpc.md`.
///
/// The list exists in three places by necessity — the Kotlin helper's `dispatch`
/// (the implementation), the markdown (the contract), and this enum (the caller's
/// view). Two of those are now checked against each other here, so a method added
/// to the protocol without a Swift case, or a case invented that the protocol does
/// not define, fails the build. The third is the helper's own dispatch, which
/// answers "unknown method" at runtime for anything it does not implement.
struct HelperMethodContractTests {

    private func documentedMethods() throws -> Set<String> {
        // <repo>/reticle-host/Tests/ReticleHostCoreTests/<this file>
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let doc = try String(
            contentsOf: repoRoot.appendingPathComponent("reticle-protocol/helper-rpc.md"),
            encoding: .utf8
        )
        // Rows of the Methods table look like: | `status` | `package?` | … |
        var found: Set<String> = []
        for line in doc.components(separatedBy: "\n") where line.hasPrefix("| `") {
            let after = line.dropFirst(3)
            guard let end = after.firstIndex(of: "`") else { continue }
            let name = String(after[after.startIndex..<end])
            // Skip the header/separator rows and any prose table elsewhere.
            if name.isEmpty || name.contains(" ") { continue }
            found.insert(name)
        }
        return found
    }

    @Test func theEnumMatchesTheDocumentedWireContract() throws {
        let documented = try documentedMethods()
        let declared = Set(HelperMethod.allCases.map(\.rawValue))
        #expect(!documented.isEmpty, "no method rows parsed out of helper-rpc.md")
        let onlyInEnum = declared.subtracting(documented).sorted()
        let onlyInDoc = documented.subtracting(declared).sorted()
        #expect(onlyInEnum.isEmpty, "HelperMethod declares methods the protocol does not")
        #expect(onlyInDoc.isEmpty, "helper-rpc.md documents methods HelperMethod does not declare")
        #expect(declared == documented)
    }

    @Test func anUnknownMethodIsNotKnown() {
        #expect(HelperMethod.isKnown("status"))
        #expect(HelperMethod.isKnown("proxyInstallCa"))
        // The shape that matters: the broker used to forward any string at all.
        #expect(!HelperMethod.isKnown("exec"))
        #expect(!HelperMethod.isKnown(""))
        #expect(!HelperMethod.isKnown("Status"), "method names are case-sensitive on the wire")
    }
}

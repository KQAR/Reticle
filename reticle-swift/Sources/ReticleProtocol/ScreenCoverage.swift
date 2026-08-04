import Foundation

/// How much of the screen an agent can actually address, and why a given
/// coordinate could not be.
///
/// The Swift twin of reticle-core's `ScreenCoverage.kt` — same reasons, same
/// sentences, same rendering — pinned for both by
/// reticle-protocol/fixtures/screen-coverage.cases.json. See the Kotlin file for
/// why this exists and what it deliberately refuses to guess.
public enum ScreenCoverage {

    /// Default sampling cell for `of`, in device pixels.
    public static let defaultCellPx: Double = 32.0

    /// How many gap groups `CoverageReport.render()` lists before summarizing.
    public static let maxListedGaps = 10

    /// Above this share of the screen, an interactive node is a CONTAINER rather
    /// than a control, and its addressability does not carry the points inside it.
    /// See the Kotlin twin for the measurement behind the constant (a hybrid screen
    /// read as 100% addressable because the `WebView` itself is tappable).
    public static let containerAreaFraction: Double = 0.5

    public static let reasonAddressable = "selector-available"
    public static let reasonCrossOrigin = "iframe:cross-origin"
    public static let reasonDomCapped = "dom:capped"
    public static let reasonDomUnavailable = "dom:unavailable"
    public static let reasonDomKernel = "dom:unsupported-kernel"
    public static let reasonWheel = "wheel"
    public static let reasonContainerOnly = "container-only"
    public static let reasonNotInteractive = "no-interactive-node"
    public static let reasonNothingCaptured = "nothing-captured"
    public static let reasonOffScreen = "off-screen"

    /// The check itself could not run — the tree was unreadable when the coordinate
    /// was dispatched. Reported rather than omitted: a missing verdict would read as
    /// "the coordinate was fine".
    public static let reasonUnavailable = "coverage:unavailable"

    // Obstruction tokens: WHO gets the touch instead of the target. Distinct from
    // the coverage reasons above, which answer "could a selector have named this
    // point" — a point can be perfectly addressable and still unreachable.
    public static let obstructedByKeyboard = "occluded:keyboard"
    public static let obstructedByWindow = "occluded:window"
    public static let obstructedByNode = "occluded:node"

    /// A verdict that says the check failed, naming why.
    public static func unavailable(x: Double, y: Double, why: String) -> PointCoverage {
        PointCoverage(x: x, y: y, covered: false, reason: reasonUnavailable, detail: why)
    }

    /// Draw-ordered nodes plus which window layer each one is in: later entries are
    /// drawn on top (window stacking first, then document order).
    private struct Stacked {
        var nodes: [Node]
        var layer: [String: Int]
    }

    private static func stack(_ snapshot: Snapshot) -> Stacked {
        let windowRefs = snapshot.windowRefs()
        var windowOrder: [String: Int] = [:]
        for (i, ref) in windowRefs.enumerated() { windowOrder[ref] = i }
        var positions: [String: Int] = [:]
        var ordered: [Node] = []
        var seen = Set<String>()
        func visit(_ ref: String) {
            guard !seen.contains(ref), let node = snapshot.nodes[ref] else { return }
            seen.insert(ref)
            positions[ref] = positions.count
            if node.isVisible, node.frame != nil { ordered.append(node) }
            for child in node.children { visit(child) }
        }
        visit(snapshot.rootRef)
        for ref in snapshot.nodes.keys.sorted() where !seen.contains(ref) { visit(ref) }
        var layer: [String: Int] = [:]
        for node in ordered {
            layer[node.ref] = snapshot.windowRefOf(node.ref).flatMap { windowOrder[$0] } ?? -1
        }
        let sorted = ordered.sorted { a, b in
            let wa = layer[a.ref] ?? -1
            let wb = layer[b.ref] ?? -1
            if wa != wb { return wa < wb }
            return (positions[a.ref] ?? 0) < (positions[b.ref] ?? 0)
        }
        return Stacked(nodes: sorted, layer: layer)
    }

    /// Is this node one an agent can aim a selector at right now?
    private static func addressable(_ node: Node) -> Bool {
        node.isInteractive && node.hasTargetingSignal()
    }

    /// The flag that would have hit `node`, most stable handle first.
    public static func selectorFlag(for node: Node) -> String {
        if let testId = node.testId { return "--test-id \(testId)" }
        if let resourceId = node.resourceId { return "--resource-id \(resourceId)" }
        if let css = node.domCssSelector() { return "--css '\(css)'" }
        let label = node.contentDescription ?? node.text
        if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "--label \"\(label.clipCodePoints(40))\""
        }
        return "--ref \(node.ref)"
    }

    /// The boundary this node declares, or nil when it declares none.
    private static func boundary(of node: Node) -> (reason: String, detail: String)? {
        if node.domCrossOriginFrame() {
            return (reasonCrossOrigin,
                    "the frame at \(node.ref) is cross-origin, so its document is unreadable by "
                    + "browser policy — coordinates are the only path into it")
        }
        if let captured = node.domCappedAt() {
            return ("\(reasonDomCapped)(\(captured))",
                    "the DOM walk under \(node.ref) stopped at its node cap (\(captured) node(s) "
                    + "captured), so nodes here were never captured at all — narrow the page or scroll")
        }
        if node.domUnavailable() {
            return (reasonDomUnavailable, "the DOM under \(node.ref) could not be read at capture time")
        }
        if node.domKernelUnsupported() {
            let name = node.domKernelName().map { " (\($0))" } ?? ""
            return (reasonDomKernel,
                    "\(node.ref) is a third-party WebView kernel\(name) with no DOM bridge at all")
        }
        if node.suspectedWheel {
            return (reasonWheel,
                    "\(node.ref) is a wheel column whose candidate values exist only as pixels — "
                    + "drive it with `act swipe`")
        }
        return nil
    }

    /// What covers one coordinate, and whether a selector could have reached it.
    public static func at(_ snapshot: Snapshot, x: Double, y: Double) -> PointCoverage {
        verdict(snapshot, stack(snapshot), x, y)
    }

    /// Who receives the touch at (x, y) instead of `targetRef` — or nil when the
    /// target itself is on top there. Twin of the Kotlin `obstruction`, where the
    /// measurement and the three rules are written down.
    public static func obstruction(
        _ snapshot: Snapshot, x: Double, y: Double, targetRef: String? = nil
    ) -> TapObstruction? {
        if let keyboard = snapshot.screen.keyboard, keyboard.visible,
           keyboard.frame?.contains(x, y) == true {
            return TapObstruction(
                reason: obstructedByKeyboard,
                detail: "the IME covers this point, so the touch goes to the keyboard and not to "
                    + "the app — dismiss it with `act hide-keyboard` first"
            )
        }
        guard let targetRef, let target = snapshot.nodes[targetRef] else { return nil }
        let stacked = stack(snapshot)
        let targetLayer = stacked.layer[target.ref] ?? -1
        let here = stacked.nodes.filter { $0.frame?.contains(x, y) == true }
        let topLayer = here.map { stacked.layer[$0.ref] ?? -1 }.max() ?? -1
        if topLayer > targetLayer {
            let front = here.last { (stacked.layer[$0.ref] ?? -1) == topLayer }
            let window = front.flatMap { snapshot.windowRefOf($0.ref) } ?? front?.ref
            return TapObstruction(
                reason: obstructedByWindow,
                detail: "a window above \(target.ref) covers this point"
                    + (window.map { " (\($0))" } ?? "")
                    + " — the touch lands in that window, not on the target",
                ref: window
            )
        }
        let screenArea = snapshot.screen.size.width * snapshot.screen.size.height
        if let above = laterSiblingCovering(
            snapshot, node: target, x: x, y: y, containerArea: screenArea * containerAreaFraction
        ) {
            return TapObstruction(
                reason: obstructedByNode,
                detail: "\(above.ref) (\(above.role ?? above.typeName)) is drawn over \(target.ref) "
                    + "at this point and is itself interactive, so it consumes the touch",
                ref: above.ref
            )
        }
        return nil
    }

    /// The nearest interactive node drawn AFTER `node` that contains the point.
    /// Screen-sized containers are skipped — see the Kotlin twin.
    private static func laterSiblingCovering(
        _ snapshot: Snapshot, node: Node, x: Double, y: Double, containerArea: Double
    ) -> Node? {
        var current = node
        var parent = current.parentRef.flatMap { snapshot.nodes[$0] }
        var seen = Set<String>()
        while let p = parent, !seen.contains(p.ref) {
            seen.insert(p.ref)
            if let position = p.children.firstIndex(of: current.ref) {
                for i in stride(from: p.children.count - 1, to: position, by: -1) {
                    guard let above = snapshot.nodes[p.children[i]] else { continue }
                    guard above.isVisible, above.isInteractive, let frame = above.frame else { continue }
                    guard frame.contains(x, y) else { continue }
                    if frame.width * frame.height > containerArea { continue }
                    return above
                }
            }
            current = p
            parent = current.parentRef.flatMap { snapshot.nodes[$0] }
        }
        return nil
    }

    /// `at` against a pre-built stack — sampling a screen asks this thousands of
    /// times and the stack does not change between samples of one snapshot.
    private static func verdict(_ snapshot: Snapshot, _ stacked: Stacked, _ x: Double, _ y: Double) -> PointCoverage {
        let size = snapshot.screen.size
        if x < 0 || y < 0 || x > size.width || y > size.height {
            return PointCoverage(
                x: x, y: y, covered: false, reason: reasonOffScreen,
                detail: "this point is outside the \(Rect.whole(size.width))x\(Rect.whole(size.height)) screen",
                ref: nil, selector: nil
            )
        }
        let here = stacked.nodes.filter { $0.frame?.contains(x, y) == true }
        // Only the TOP window layer at this point can answer for it: a stacked screen
        // keeps the window behind it alive and fully laid out, and its nodes are
        // usually SMALLER than the front screen's containers — so a smallest-node rule
        // would reach through the front screen and name a control the touch can never
        // reach. See the Kotlin twin for the measured case.
        let topLayer = here.map { stacked.layer[$0.ref] ?? -1 }.max() ?? -1
        // Topmost first: the boundary nearest the touch is the one in the way.
        let topDown = Array(here.filter { (stacked.layer[$0.ref] ?? -1) == topLayer }.reversed())
        let containerArea = size.width * size.height * containerAreaFraction
        func area(_ node: Node) -> Double {
            node.frame.map { $0.width * $0.height } ?? 0
        }
        let addressableHere = topDown.filter { addressable($0) }
        // The SMALLEST addressable node wins, not the topmost: nesting means several
        // contain the point, and the innermost is the control while its ancestors are
        // layout. `min(by:)` keeps the first of equal areas, i.e. topmost-first.
        // A boundary HOST never counts as cover for the points inside it, even when
        // it is tappable and carries an id — see the Kotlin twin for the measured
        // case (a cross-origin frame element that was itself `tappable`).
        let hit = addressableHere.filter { area($0) <= containerArea && boundary(of: $0) == nil }
            .min { area($0) < area($1) }
        if let hit {
            let flag = selectorFlag(for: hit)
            let taps = hit.frame.map { " and would tap (\(Rect.whole($0.centerX)),\(Rect.whole($0.centerY)))" } ?? ""
            return PointCoverage(
                x: x, y: y, covered: true, reason: reasonAddressable,
                detail: "\(flag) resolves to \(hit.ref) (\(hit.role ?? hit.typeName)), whose frame "
                    + "contains this point\(taps)",
                ref: hit.ref, selector: flag
            )
        }
        for node in topDown {
            guard let boundary = boundary(of: node) else { continue }
            return PointCoverage(
                x: x, y: y, covered: false, reason: boundary.reason, detail: boundary.detail,
                ref: node.ref, selector: nil
            )
        }
        // Nothing small is addressable here and no boundary explains it, but a
        // screen-sized tappable container does contain the point. That container is
        // not cover: a selector tap on it lands on its own centre.
        if let container = addressableHere.min(by: { area($0) < area($1) }) {
            let taps = container.frame.map { "(\(Rect.whole($0.centerX)),\(Rect.whole($0.centerY)))" } ?? "(unknown)"
            return PointCoverage(
                x: x, y: y, covered: false, reason: reasonContainerOnly,
                detail: "the only addressable node here is \(container.ref) "
                    + "(\(container.role ?? container.typeName)), a screen-sized container whose own "
                    + "tap point is \(taps) — nothing smaller is captured at this point",
                ref: container.ref, selector: nil
            )
        }
        guard let top = topDown.first else {
            return PointCoverage(
                x: x, y: y, covered: false, reason: reasonNothingCaptured,
                detail: "no captured node contains this point", ref: nil, selector: nil
            )
        }
        return PointCoverage(
            x: x, y: y, covered: false, reason: reasonNotInteractive,
            detail: "the topmost node here is \(top.ref) (\(top.role ?? top.typeName)) and it is not "
                + "interactive, so no selector aims at this point",
            ref: top.ref, selector: nil
        )
    }

    /// The whole screen, sampled on a grid of `cellPx` cells.
    public static func of(_ snapshot: Snapshot, cellPx: Double = defaultCellPx) -> CoverageReport {
        let size = snapshot.screen.size
        let cell = cellPx > 0 ? cellPx : defaultCellPx
        let columns = max(0, Rect.whole((size.width / cell).rounded(.up)))
        let rows = max(0, Rect.whole((size.height / cell).rounded(.up)))
        let stacked = stack(snapshot)
        let keyboardFrame = snapshot.screen.keyboard.flatMap { $0.visible ? $0.frame : nil }
        var addressableCells = 0
        var containerOnlyCells = 0
        var inertCells = 0
        var emptyCells = 0
        var keyboardCells = 0
        // Keyed by reason + host ref, in first-seen order, so the Kotlin twin's
        // LinkedHashMap and this agree before the sort.
        var keys: [String] = []
        var gaps: [String: CoverageGap] = [:]
        for row in 0..<max(0, rows) {
            for column in 0..<max(0, columns) {
                let cx = Double(column) * cell + cell / 2.0
                let cy = Double(row) * cell + cell / 2.0
                if keyboardFrame?.contains(cx, cy) == true {
                    keyboardCells += 1
                    continue
                }
                let v = verdict(snapshot, stacked, cx, cy)
                if v.covered {
                    addressableCells += 1
                } else if v.reason == reasonNothingCaptured || v.reason == reasonOffScreen {
                    emptyCells += 1
                } else if v.reason == reasonNotInteractive {
                    inertCells += 1
                } else if v.reason == reasonContainerOnly {
                    // Not cover, but not a gap either — see the Kotlin twin for the
                    // login screen that read as 31% addressable while every control
                    // on it worked.
                    containerOnlyCells += 1
                } else {
                    let ref = v.ref ?? "?"
                    let key = "\(v.reason)|\(ref)"
                    if var existing = gaps[key] {
                        existing.cells += 1
                        gaps[key] = existing
                    } else {
                        keys.append(key)
                        gaps[key] = CoverageGap(
                            reason: v.reason, ref: ref, frame: snapshot.nodes[ref]?.frame, cells: 1
                        )
                    }
                }
            }
        }
        let sorted = keys.compactMap { gaps[$0] }.sorted { a, b in
            if a.cells != b.cells { return a.cells > b.cells }
            if a.reason != b.reason { return a.reason < b.reason }
            return a.ref < b.ref
        }
        return CoverageReport(
            screen: size, cellPx: cell, columns: columns, rows: rows,
            addressableCells: addressableCells, inertCells: inertCells, emptyCells: emptyCells,
            keyboardCells: keyboardCells, containerOnlyCells: containerOnlyCells, gaps: sorted
        )
    }
}

/// The verdict for one coordinate.
public struct PointCoverage: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    /// True when an addressable node's frame contains this point.
    public var covered: Bool
    /// Machine token: `selector-available`, `iframe:cross-origin`, `dom:capped(N)`, …
    public var reason: String
    /// The same fact as a sentence, naming the node in the way.
    public var detail: String
    /// The node the verdict is about: the hit, the boundary host, or the topmost node.
    public var ref: String?
    /// The flag that would have resolved this point, when one would have.
    public var selector: String?

    public init(
        x: Double, y: Double, covered: Bool, reason: String, detail: String,
        ref: String? = nil, selector: String? = nil
    ) {
        self.x = x
        self.y = y
        self.covered = covered
        self.reason = reason
        self.detail = detail
        self.ref = ref
        self.selector = selector
    }

    /// The one line a coordinate tap prints, as a warning either way — see the
    /// Kotlin twin for why a COVERED point is also a warning.
    public func warning() -> String {
        let where_ = "(\(Rect.whole(x)),\(Rect.whole(y)))"
        if reason == ScreenCoverage.reasonUnavailable {
            return "could not check whether a selector covers \(where_) — \(detail)"
        }
        if covered {
            return "--point was not needed at \(where_): \(detail). "
                + "A selector tap re-resolves and confirms its target; a coordinate does neither"
        }
        return "no semantic selector covers \(where_) — \(reason): \(detail)"
    }

    /// The wire shape the host prints from.
    public var jsonObject: [String: Any] {
        var out: [String: Any] = [
            "x": x, "y": y, "covered": covered, "reason": reason,
            "detail": detail, "warning": warning(),
        ]
        if let ref { out["ref"] = ref }
        if let selector { out["selector"] = selector }
        return out
    }
}

/// Who gets the touch instead of the target, as a tap result field. Carried by
/// EVERY tap, selector or coordinate — see the Kotlin twin.
public struct TapObstruction: Codable, Equatable, Sendable {
    /// `occluded:keyboard`, `occluded:window` or `occluded:node`.
    public var reason: String
    /// The same fact as a sentence, naming what is in the way and what to do.
    public var detail: String
    /// The occluding window or node, when one is nameable (the IME is not a node).
    public var ref: String?

    public init(reason: String, detail: String, ref: String? = nil) {
        self.reason = reason
        self.detail = detail
        self.ref = ref
    }

    /// The line a tap prints when something is in the way — a warning, not a
    /// refusal. See the Kotlin twin.
    public func warning(x: Double, y: Double) -> String {
        "the touch at (\(Rect.whole(x)),\(Rect.whole(y))) may not reach the target — \(reason): \(detail)"
    }

    /// The wire shape the host prints from.
    public func jsonObject(x: Double, y: Double) -> [String: Any] {
        var out: [String: Any] = ["reason": reason, "detail": detail, "warning": warning(x: x, y: y)]
        if let ref { out["ref"] = ref }
        return out
    }
}

/// One boundary-marked region and how much of the sampled grid it takes.
public struct CoverageGap: Codable, Equatable, Sendable {
    public var reason: String
    public var ref: String
    public var frame: Rect?
    public var cells: Int

    public init(reason: String, ref: String, frame: Rect? = nil, cells: Int) {
        self.reason = reason
        self.ref = ref
        self.frame = frame
        self.cells = cells
    }
}

/// The whole-screen answer to "how much of this screen is unreachable?".
public struct CoverageReport: Codable, Equatable, Sendable {
    public var screen: Size
    public var cellPx: Double
    public var columns: Int
    public var rows: Int
    public var addressableCells: Int
    /// A node is captured here, but nothing over the point is interactive.
    public var inertCells: Int
    /// No captured node contains the point at all.
    public var emptyCells: Int
    /// Covered by the system keyboard — another process's window, never a node.
    public var keyboardCells: Int
    /// Only a screen-sized interactive container answers here. Counted apart from
    /// `gaps` — see the Kotlin twin.
    public var containerOnlyCells: Int
    public var gaps: [CoverageGap]

    public init(
        screen: Size, cellPx: Double, columns: Int, rows: Int, addressableCells: Int,
        inertCells: Int, emptyCells: Int, keyboardCells: Int, containerOnlyCells: Int = 0,
        gaps: [CoverageGap]
    ) {
        self.screen = screen
        self.cellPx = cellPx
        self.columns = columns
        self.rows = rows
        self.addressableCells = addressableCells
        self.inertCells = inertCells
        self.emptyCells = emptyCells
        self.keyboardCells = keyboardCells
        self.containerOnlyCells = containerOnlyCells
        self.gaps = gaps
    }

    /// Cells inside a region a named boundary makes unreachable.
    public var unreachableCells: Int { gaps.reduce(0) { $0 + $1.cells } }

    /// Cells the contract is measured over: addressable plus unreachable.
    public var touchRelevantCells: Int { addressableCells + unreachableCells }

    /// Integer percent of `touchRelevantCells` that is addressable, truncated —
    /// truncation keeps the two ports byte-identical.
    public var addressablePercent: Int {
        touchRelevantCells == 0 ? 100 : addressableCells * 100 / touchRelevantCells
    }

    public func render() -> String {
        var out = "coverage: \(Rect.whole(screen.width))x\(Rect.whole(screen.height)), "
            + "sampled on a \(columns)x\(rows) grid of \(Rect.whole(cellPx))px cells\n"
        if touchRelevantCells == 0 {
            out += "addressable: no touch-relevant cells on this screen — nothing interactive and no "
                + "named boundary was captured\n"
        } else {
            out += "addressable: \(addressableCells) of \(touchRelevantCells) touch-relevant cell(s) "
                + "(\(addressablePercent)%)\n"
        }
        if gaps.isEmpty {
            out += "unreachable: none — every touch-relevant cell has an addressable node over it\n"
        } else {
            out += "unreachable: \(unreachableCells) cell(s)\n"
            for gap in gaps.prefix(ScreenCoverage.maxListedGaps) {
                let whereAt = gap.frame.map { " [\($0.intDescription)]" } ?? ""
                out += "  \(gap.reason) \(gap.ref)\(whereAt) \(gap.cells) cell(s)\n"
            }
            let more = gaps.count - ScreenCoverage.maxListedGaps
            if more > 0 { out += "  (\(more) more gap group(s))\n" }
        }
        if containerOnlyCells > 0 {
            out += "container-only: \(containerOnlyCells) cell(s) — only a screen-sized container "
                + "answers here (a selector tap on it lands on its own centre)\n"
        }
        out += "inert: \(inertCells) cell(s) — a node is captured there, none of it interactive\n"
        out += "empty: \(emptyCells) cell(s) — no captured node contains the point\n"
        if keyboardCells > 0 {
            out += "keyboard: \(keyboardCells) cell(s) covered by the IME (another process's window)\n"
        }
        out += "(inert, empty and container-only cells are NOT counted as gaps: without pixels, plain content and a "
            + "control the projection failed to mark are the same observation)"
        return out
    }
}

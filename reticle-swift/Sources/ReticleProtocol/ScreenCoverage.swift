import Foundation

/// How much of the screen an agent can actually address, and why a given
/// coordinate could not be.
///
/// Reticle's contract is that a model with no visual capability can drive a
/// running app. Every `act tap --point` is a place that contract broke: the agent
/// measured pixels because nothing in the projection covered the thing it wanted.
/// That fallback used to be SILENT — the tap reported success and the gap left no
/// trace — so the only way to find one was to run a flow by hand and notice.
///
/// Two questions are answered here, from the tree alone:
///
///  - `at` — for ONE point: is there an addressable node over it, and if not, what
///    is in the way. Attached to every coordinate tap, so a coordinate is either
///    justified by a named boundary or reported as an unnecessary fallback.
///  - `of` — for the WHOLE screen: what share of the touch-relevant area has an
///    addressable node over it. That number is the direct measure of the contract.
///
/// Deliberately honest about one limit, stated in the rendering rather than hidden
/// in it: a cell where a node IS captured but nothing is interactive is NOT counted
/// as a gap. Without pixels, a paragraph of text and a control the projection
/// failed to mark are the same observation, and guessing would turn every screen
/// into a false report.
///
/// The ONLY implementation, for both platforms: the host aims every tap itself, so
/// it judges the snapshot the tap was aimed in here, Android and iOS alike. Pinned by reticle-protocol/fixtures/screen-coverage.cases.json.
public enum ScreenCoverage {

    /// Default sampling cell for `of`, in device pixels.
    public static let defaultCellPx: Double = 32.0

    /// How many gap groups `CoverageReport.render()` lists before summarizing.
    public static let maxListedGaps = 10

    /// Above this share of the screen, an interactive node is a CONTAINER rather
    /// than a control, and its addressability does not carry the points inside it.
    ///
    /// Measured, and the reason the first cut of this file reported a hybrid screen
    /// as 100% addressable: an Android `WebView` is itself focusable/clickable and
    /// carries a resource id, so it satisfies every test a control does while
    /// covering the whole display. A selector tap on it lands on ITS centre — not on
    /// the thing the agent was aiming at — so counting it as cover for 2550 sampled
    /// cells turned the one number that measures the blind-agent contract into a
    /// constant. A control the agent can actually aim at is small; a screen-sized
    /// tappable rectangle is scenery.
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
        /// Shortest-css-handle index for the same snapshot. Built with the stack for
        /// the same reason: a whole-screen sample asks thousands of times and the
        /// snapshot does not change between samples.
        var cssHandles: CssHandle.Index
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
        return Stacked(nodes: sorted, layer: layer, cssHandles: CssHandle.Index(snapshot))
    }

    /// Is this node one an agent can aim a selector at right now?
    private static func addressable(_ node: Node) -> Bool {
        node.isInteractive && node.hasTargetingSignal()
    }

    /// The flag that would have hit `node`, most stable handle first.
    ///
    /// `--ref` is last and is still a real answer: a ref is addressable within the
    /// capture it came from, which is exactly the scope a tap has.
    public static func selectorFlag(for node: Node, cssHandle: String? = nil) -> String {
        if let testId = node.testId { return "--test-id \(testId)" }
        if let resourceId = node.resourceId { return "--resource-id \(resourceId)" }
        // The SHORTEST css that still names this node alone, when a snapshot was
        // available to decide that against: a full ancestor path is ~400 characters
        // of lineage in a hint whose whole job is to be read. See `CssHandle`.
        if let css = cssHandle ?? node.domCssSelector() { return "--css '\(css)'" }
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
    ///
    /// Computed for every coordinate tap. When the answer is `reasonAddressable`
    /// the coordinate was NOT needed and the report says which flag would have
    /// worked — that is the case this exists to catch, since a pixel-measured tap on
    /// an addressable node is a silent loss of the re-resolution, settle and
    /// readback a selector tap carries.
    public static func at(_ snapshot: Snapshot, x: Double, y: Double) -> PointCoverage {
        verdict(snapshot, stack(snapshot), x, y)
    }

    /// Who receives the touch at (x, y) instead of `targetRef` — or nil when the
    /// target itself is on top there.
    ///
    /// A separate question from `at`, and the one that was missing: `at` answers
    /// "could a selector have named this point", which a covered point answers YES
    /// to even when the touch cannot reach it. Measured on a physical device, both
    /// halves silent:
    ///
    ///  - a third-party debug overlay's small floating window sat over a form
    ///    control; `act tap --css …` resolved the control, dispatched, reported
    ///    `settled=1`, and the overlay opened its own screen;
    ///  - a button under the IME was tapped with the keyboard up and nothing
    ///    happened, while `ui compact` for the same node already printed
    ///    `occluded-by:keyboard` and even suggested `act hide-keyboard`.
    ///
    /// Three sources, in the order a touch meets them:
    ///
    ///  1. the IME — another process's window above every app window;
    ///  2. a HIGHER window layer than the target's (dialog, popup, toast);
    ///  3. a later sibling in the same window (draw order) that consumes the touch —
    ///     interactive for a native view, anything not `pointer-events: none` for a
    ///     DOM element, whose default is to eat the click.
    ///
    /// A screen-sized interactive container is deliberately NOT an obstruction: it
    /// is the same scenery `containerAreaFraction` exists for. An app that wraps its
    /// content in one full-screen clickable frame (debug overlays do exactly this)
    /// would otherwise mark every tap on the screen as obstructed, and a warning that
    /// fires on every tap is one nobody reads. A NATIVE modal scrim gets caught by
    /// rule 2 instead, because it lives in its own window; an in-page one has no
    /// window of its own, so it is caught by rule 3 as a painted out-of-flow DOM
    /// layer.
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
            let why = above.kind == .domNode
                ? "and the page did not opt it out of hit-testing"
                : "and is itself interactive"
            return TapObstruction(
                reason: obstructedByNode,
                detail: "\(above.ref) (\(above.role ?? above.typeName)) is drawn over \(target.ref) "
                    + "at this point \(why), so it consumes the touch",
                ref: above.ref
            )
        }
        return nil
    }

    /// The nearest node drawn AFTER `node` that contains the point and would consume
    /// the touch: interactive for a native view, anything not `pointer-events: none`
    /// for a DOM element. Screen-sized containers are skipped (scenery, see
    /// `obstruction`), except a full-screen DOM layer that is out of flow AND paints
    /// its own box: that is a dialog backdrop, the one full-screen cover that really
    /// does consume every touch on the screen. Twin of the rule `CompactObservation`
    /// renders as `occluded-by:` — sharing the conclusion, not the code, because that
    /// one asks about a node's CENTRE while a tap asks about the point it is about to
    /// dispatch.
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
                    guard above.isVisible, let frame = above.frame else { continue }
                    let isDom = above.kind == .domNode
                    if isDom ? above.domPointerEventsNone() : !above.isInteractive { continue }
                    guard frame.contains(x, y) else { continue }
                    if frame.width * frame.height > containerArea {
                        guard isDom, above.domOutOfFlow(), above.domPaintsBackground() else { continue }
                    }
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
        // reach. Measured on the sample app: a coordinate inside a cross-origin frame
        // on the top window was answered with `--test-id scenario.list` from the home
        // screen underneath it.
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
        // it is tappable and carries an id. Measured on a real third-party widget:
        // `iframe:cross-origin` sat on a frame element that was itself `tappable`
        // with a test id, so every point in the widget read "a selector covers this"
        // while the steps the agent needed were inside a document nothing can read.
        // Tapping the frame hits its centre; the boundary answer is the true one, and
        // it still names the ref for a caller who did mean the frame.
        let hit = addressableHere.filter { area($0) <= containerArea && boundary(of: $0) == nil }
            .min { area($0) < area($1) }
        if let hit {
            let flag = selectorFlag(for: hit, cssHandle: stacked.cssHandles.of(hit))
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
        // not cover: a selector tap on it lands on its own centre, so the thing at
        // THIS point has no handle. Naming it (with its tap point) is what separates
        // "you could have used a selector" from "a coordinate was the only path".
        if let container = addressableHere.min(by: { area($0) < area($1) }) {
            let taps = container.frame.map { "(\(Rect.whole($0.centerX)),\(Rect.whole($0.centerY)))" } ?? "(unknown)"
            return PointCoverage(
                x: x, y: y, covered: false, reason: reasonContainerOnly,
                detail: "the only addressable node here is \(container.ref) "
                    + "(\(container.role ?? container.typeName)), a screen-sized container whose own "
                    + "tap point is \(taps) — nothing smaller is captured at this point"
                    + namedFieldNote(snapshot, x, y),
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
                + "interactive, so no selector aims at this point"
                + namedFieldNote(snapshot, x, y),
            ref: top.ref, selector: nil
        )
    }

    /// The `— inside the named field "…"` clause, when this point falls in one.
    ///
    /// The whole-screen report already lists these (`named but inert:`), and without
    /// this the two halves of the same tool contradicted each other on the same
    /// screen: `ui coverage` named `"Employment type" r404 [57,786 964x195]` while a
    /// tap at a point inside that rect answered `nothing smaller is captured at this
    /// point`. The per-point warning is where a caller reads it — at the moment it
    /// dispatches the coordinate — so it is the half that needed it most.
    private static func namedFieldNote(_ snapshot: Snapshot, _ x: Double, _ y: Double) -> String {
        guard let deepest = deepestAt(snapshot, snapshot.rootRef, x, y),
              let (name, host) = labelledFieldName(snapshot, deepest.ref)
        else { return "" }
        return " — it is inside the named field \"\(name)\" (\(host)), which the page exposes no "
            + "control for, so a coordinate is the only path to it"
    }

    /// How deep `deepestAt` descends. A DOM-heavy screen is deep; the walk is not.
    private static let maxFieldDepth = 60

    /// The deepest visible node under this point, starting from `ref`. The per-cell
    /// verdict names the node that ANSWERS for the point (a screen-sized web view,
    /// usually), which is the wrong starting point for "which field is this".
    /// Measured: five named dropdowns all sat in `container-only` cells whose ref was
    /// the web view, so looking at the verdict's own node found nothing about them.
    private static func deepestAt(_ snapshot: Snapshot, _ ref: String, _ cx: Double, _ cy: Double) -> Node? {
        guard let start = snapshot.nodes[ref] else { return nil }
        var best: Node? = start.frame?.contains(cx, cy) == true ? start : nil
        var seen = Set<String>()
        func visit(_ node: Node, _ depth: Int) {
            if depth > maxFieldDepth || !seen.insert(node.ref).inserted { return }
            if node.isVisible, node.frame?.contains(cx, cy) == true { best = node }
            for child in node.children { snapshot.nodes[child].map { visit($0, depth + 1) } }
        }
        visit(start, 0)
        return best
    }

    /// The name of the field this point belongs to, when the page named it and
    /// exposed no control for it.
    ///
    /// The case measured on a real form: five dropdowns whose trigger is a bare
    /// `<div>` with no role, no `aria-*`, no text and nothing the page declares as
    /// clickable. Their `<label>` IS captured, so the screen read as fully
    /// addressable while those five fields could only be driven by coordinates — the
    /// one number meant to measure the blind-agent contract said 100% exactly where
    /// the contract was broken.
    ///
    /// Narrow, because a wrong name here would be worse than the silence it
    /// replaces: the enclosing field wrapper (at most three levels up) must hold
    /// EXACTLY ONE label-ish node and NO interactive node at all. A named field with
    /// a control beside it is not this case, and a group legend over several
    /// controls is not either. The OUTERMOST wrapper that still satisfies the rule
    /// wins: walking up from different starting nodes stops at different levels, and
    /// reporting each separately listed one field up to three times.
    private static func labelledFieldName(_ snapshot: Snapshot, _ ref: String?) -> (String, String)? {
        guard let ref, var current = snapshot.nodes[ref] else { return nil }
        var match: (String, String)?
        var level = 0
        while level < 3 {
            guard let parent = current.parentRef.flatMap({ snapshot.nodes[$0] }) else { return match }
            var descendants: [Node] = []
            var seen = Set<String>()
            func collect(_ node: Node) {
                if !seen.insert(node.ref).inserted { return }
                descendants.append(node)
                for child in node.children { snapshot.nodes[child].map(collect) }
            }
            for child in parent.children { snapshot.nodes[child].map(collect) }
            // An interactive node at this level ends the walk — but it does not undo a
            // match found INSIDE it: the field wrapper below may still be a named
            // field with no control, while a sibling field further out has one.
            if descendants.contains(where: { $0.isInteractive }) { return match }
            let labels = descendants.filter { $0.role == "label" && !($0.text ?? "").isEmpty }
            if labels.count == 1, let text = labels[0].text { match = (text, parent.ref) }
            current = parent
            level += 1
        }
        return match
    }

    /// The whole screen, sampled on a grid of `cellPx` cells.
    ///
    /// A grid rather than exact rect arithmetic because overlapping frames make an
    /// exact union area a different (and much larger) problem, and because the
    /// sampling is then a stated fact in the output rather than a hidden
    /// approximation.
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
        // Keyed by reason + host ref, in first-seen order, so two frames with the same
        // boundary stay two rows: the rect is what an agent acts on.
        var keys: [String] = []
        var gaps: [String: CoverageGap] = [:]
        var labelledKeys: [String] = []
        var labelled: [String: LabelledInertRegion] = [:]
        // Keyed by name + RECT, not by ref: the same field has several nested
        // wrappers with the identical rect, and walking up from different cells stops
        // at different ones, which listed one field several times.
        func noteLabelled(_ cx: Double, _ cy: Double, _ ref: String?) {
            let start = ref ?? snapshot.rootRef
            guard let deepest = deepestAt(snapshot, start, cx, cy),
                  let (name, host) = labelledFieldName(snapshot, deepest.ref)
            else { return }
            let f = snapshot.nodes[host]?.frame
            let key = "\(name)|\(Rect.whole(f?.x ?? 0)),\(Rect.whole(f?.y ?? 0)),"
                + "\(Rect.whole(f?.width ?? 0))x\(Rect.whole(f?.height ?? 0))"
            if var existing = labelled[key] {
                existing.cells += 1
                labelled[key] = existing
            } else {
                labelledKeys.append(key)
                labelled[key] = LabelledInertRegion(name: name, ref: host, frame: f, cells: 1)
            }
        }
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
                    noteLabelled(cx, cy, v.ref)
                } else if v.reason == reasonContainerOnly {
                    // Not cover — that rule stands, and the per-point verdict still
                    // says so — but not a GAP either, and counting it as one made a
                    // whole class of app unreadable. Measured on a login screen
                    // carrying a full-screen debug overlay (an interactive
                    // `FrameLayout` the size of the display): 1004 of 1462
                    // touch-relevant cells came back unreachable and the screen read
                    // as 31% addressable, while every control on it resolved and every
                    // tap landed. A boundary the container declares is answered before
                    // this branch and still counts as a gap.
                    containerOnlyCells += 1
                    // A named field inside a screen-sized container is the same
                    // observation as one in an inert region.
                    noteLabelled(cx, cy, v.ref)
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
            keyboardCells: keyboardCells, containerOnlyCells: containerOnlyCells,
            labelledInert: labelledKeys.compactMap { labelled[$0] }.sorted { a, b in
                if a.cells != b.cells { return a.cells > b.cells }
                return a.name < b.name
            },
            gaps: sorted
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

    /// The one line a coordinate tap prints, as a warning either way.
    ///
    /// Both outcomes are warnings on purpose. An uncovered point is a coverage gap
    /// to file; a COVERED one is worse in a quieter way — the agent measured pixels
    /// for something it could have named, throwing away the re-resolution, settle
    /// confirm and stale-rect evidence a selector tap carries.
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
/// EVERY tap, selector or coordinate — unlike `PointCoverage`, which only a
/// coordinate tap needs. A selector tap is exactly the case that used to be silent:
/// it re-resolves, confirms the rect has stopped moving, reports `settled=1`, and
/// then hands the touch to whatever is drawn on top.
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

    /// The line a tap prints when something is in the way.
    ///
    /// A warning rather than a refusal: the touch may still be the right thing to
    /// dispatch (a scrim that closes on outside taps, an overlay the caller means to
    /// hit), and a hard failure on a heuristic would strand a flow. What the caller
    /// must not have is silence — `settled=1` with nothing else reads as "the app
    /// got it".
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

/// A field the page NAMED but exposed no control for: its label is captured and
/// nothing in the field is interactive, so the region reads as ordinary inert
/// content while only a coordinate reaches it.
public struct LabelledInertRegion: Codable, Equatable, Sendable {
    public var name: String
    public var ref: String
    public var frame: Rect?
    public var cells: Int

    public init(name: String, ref: String, frame: Rect? = nil, cells: Int) {
        self.name = name
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
    /// `gaps` for the reason `inertCells` is: the container is not cover (a selector
    /// tap on it lands on its own centre), but a transparent full-screen frame over
    /// ordinary content is not a region the app failed to expose either. Folding
    /// these into the gap total made a screen whose every control worked read as 31%
    /// addressable.
    public var containerOnlyCells: Int
    /// Named fields with no addressable control. Listed, not counted as gaps:
    /// nothing here proves the region is tappable, and inferring that from a label
    /// would be the guess this file refuses everywhere else. Naming them is what
    /// stops `addressable: 100%` from reading as "every control has a selector".
    public var labelledInert: [LabelledInertRegion]
    public var gaps: [CoverageGap]

    public init(
        screen: Size, cellPx: Double, columns: Int, rows: Int, addressableCells: Int,
        inertCells: Int, emptyCells: Int, keyboardCells: Int, containerOnlyCells: Int = 0,
        labelledInert: [LabelledInertRegion] = [], gaps: [CoverageGap]
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
        self.labelledInert = labelledInert
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
        if !labelledInert.isEmpty {
            out += "named but inert: \(labelledInert.count) field(s) — the page names these and "
                + "exposes no control for them, so only a coordinate reaches them\n"
            for region in labelledInert.prefix(ScreenCoverage.maxListedGaps) {
                let where_ = region.frame.map {
                    " [\(Rect.whole($0.x)),\(Rect.whole($0.y)) \(Rect.whole($0.width))x\(Rect.whole($0.height))]"
                } ?? ""
                out += "  \"\(region.name)\" \(region.ref)\(where_) \(region.cells) cell(s)\n"
            }
            let more = labelledInert.count - ScreenCoverage.maxListedGaps
            if more > 0 { out += "  (\(more) more named field(s))\n" }
        }
        out += "empty: \(emptyCells) cell(s) — no captured node contains the point\n"
        if keyboardCells > 0 {
            out += "keyboard: \(keyboardCells) cell(s) covered by the IME (another process's window)\n"
        }
        out += "(inert, empty and container-only cells are NOT counted as gaps: without pixels, plain content and a "
            + "control the projection failed to mark are the same observation)"
        return out
    }
}

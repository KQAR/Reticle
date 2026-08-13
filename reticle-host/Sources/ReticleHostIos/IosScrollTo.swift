import Foundation
import ReticleHostShared
import ReticleProtocol

// `act scroll-to` on iOS: drag a scrollable container until the selector resolves
// inside it, then confirm the position stopped moving.
//
// Split out of `IosHelperClient`, which had grown to eight concerns in one type.
// This is the twin of the Kotlin helper's `HelperScrollTo` and exists for the same
// measured reason: a SwiftUI `List` realizes only its visible window, so a far-down
// row has no node at all and `tap` can never reach it. `private` becomes
// module-internal only because a Swift extension in another file cannot see
// `private`.
extension IosHelperClient {
    // MARK: - scroll-to

    /// Drag a scrollable container until the selector resolves to a point inside
    /// it, then confirm the position stopped moving. The iOS twin of the helper's
    /// `HelperScrollTo`, and it exists for the same measured reason: a SwiftUI
    /// `List` realizes only its visible window, so `list.item40` has no node at
    /// all and `tap` can never reach it.
    ///
    /// Slow drags on purpose: a flick leaves the list decelerating after the
    /// gesture returns, so the point reported would already be stale for the next
    /// command. `settled` says whether the position was confirmed to have stopped.
    func scrollTo(_ pkg: String, _ params: [String: Any], surface: IosTouchSurface) async throws -> [String: Any] {
        let selector = selectorFromParams(params)
        let maxSwipes = Int((params["maxSwipes"] as? String) ?? "") ?? 12
        let requested = (params["direction"] as? String)?.lowercased()
        var swipes = 0
        var lastDirection: String?
        // Locked after the first pick: re-choosing per iteration made an absent
        // selector ping-pong (at the bottom, "first available" becomes `up`), so a
        // run would re-cover ground instead of finishing a sweep.
        var lockedDirection: String?

        while true {
            let snapshot = try await fetchSnapshot(pkg)
            let container = try scrollContainer(snapshot, params)
            if let point = resolvedInside(snapshot, params, container: container) {
                let settled = await confirmSettled(pkg, params, container: container, first: point)
                var out: [String: Any] = [
                    "gesture": "scroll-to", "via": surface.describe, "found": true, "swipes": swipes,
                    "x": settled.point.x, "y": settled.point.y, "settled": settled.stable,
                ]
                if let lastDirection { out["direction"] = lastDirection }
                if let container { out["container"] = container.testId ?? container.ref }
                return out
            }
            guard let container, let frame = container.frame, let scroll = container.scroll else {
                throw HelperError("scroll-to found no scrollable container on screen, so "
                    + "\(selector.describe()) cannot be scrolled into view" + Self.scrollHint(snapshot))
            }
            let direction = requested ?? lockedDirection ?? firstDirection(scroll)
            lockedDirection = direction
            guard let direction, canScroll(scroll, direction) else {
                let containerOnly = matchedTheContainer(
                    (try? resolveTarget(params, snapshot: snapshot))?.ref, container: container, snapshot: snapshot)
                throw HelperError("scroll-to reached the end of "
                    + "'\(container.testId ?? container.ref)' after \(swipes) drag(s) without resolving "
                    + "\(selector.describe()) (container now reports \(scroll.describe())). "
                    + "Nothing realized under that selector came into view."
                    + (containerOnly
                        ? " The only thing that DID match is the container itself — a scroll host carries the "
                          + "concatenated text of the rows it has realized, so a --label for a value that is not "
                          + "on screen matches the list rather than a row. Target a row's own handle, or drive "
                          + "the list with `act swipe` and read back what rendered."
                        : ""))
            }
            if swipes >= maxSwipes {
                throw HelperError("scroll-to gave up after \(maxSwipes) drag(s) \(direction) inside "
                    + "'\(container.testId ?? container.ref)' without resolving \(selector.describe()). "
                    + "The container can still scroll \(direction) — raise --max-swipes.")
            }
            let screen = (snapshot.screen.size.width, snapshot.screen.size.height)
            try await drag(frame, direction, surface: surface, screen: screen)
            lastDirection = direction
            swipes += 1
            try? await Task.sleep(for: .seconds(0.35))
        }
    }

    func resolvedInside(_ snapshot: Snapshot, _ params: [String: Any], container: Node?) -> Point? {
        guard let resolved = try? resolveTarget(params, snapshot: snapshot) else { return nil }
        // The match must be something INSIDE the list, not the list. A scroll host
        // captures the concatenated text of every row it has realized, so a
        // `--label` for a value that is not on screen substring-matches the
        // container and resolves to its centre — which is inside its own frame, so
        // the loop declared success with `swipes=0` for a row that does not exist.
        // Measured on a virtualized web date wheel: `scroll-to --label "1995"`
        // answered `found=true settled=true swipes=0` while 1995 was in no node of
        // the tree and nothing had scrolled. `found` then means "go tap it", and
        // the tap lands on the wheel instead.
        if matchedTheContainer(resolved.ref, container: container, snapshot: snapshot) { return nil }
        let point = resolved.point
        guard let frame = container?.frame else { return point }
        let inside = point.x >= frame.x && point.x <= frame.x + frame.width
            && point.y >= frame.y && point.y <= frame.y + frame.height
        return inside ? point : nil
    }

    /// True when the selector resolved to the scroll container itself, to an
    /// ancestor of it, or to another scrollable node — none of which is a row that
    /// scrolling could bring into view.
    func matchedTheContainer(_ ref: String?, container: Node?, snapshot: Snapshot) -> Bool {
        guard let ref, let node = snapshot.nodes[ref] else { return false }
        if node.scroll != nil { return true }
        guard let container else { return false }
        if ref == container.ref { return true }
        // An ancestor of the container is equally not a row inside it.
        var walker: String? = container.parentRef
        var hops = 0
        while let current = walker, hops < 64 {
            if current == ref { return true }
            walker = snapshot.nodes[current]?.parentRef
            hops += 1
        }
        return false
    }

    /// A point plus whether its position was confirmed to have stopped moving.
    /// Shared with the tap path, which settles for the same reason.
    struct SettledPoint { let point: Point; let stable: Bool }

    /// Poll until the target resolves to the same point twice — the list stopped —
    /// or the budget runs out. Reports the freshest point either way.
    func confirmSettled(
        _ pkg: String, _ params: [String: Any], container: Node?, first: Point
    ) async -> SettledPoint {
        let deadline = Date().addingTimeInterval(2.0)
        var previous = first
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(0.2))
            guard let snapshot = try? await fetchSnapshot(pkg) else { return SettledPoint(point: previous, stable: false) }
            let fresh = (try? scrollContainer(snapshot, params)).flatMap { $0 }
            guard let point = resolvedInside(snapshot, params, container: fresh) else {
                return SettledPoint(point: previous, stable: false)
            }
            if abs(point.x - previous.x) < 1, abs(point.y - previous.y) < 1 {
                return SettledPoint(point: point, stable: true)
            }
            previous = point
        }
        return SettledPoint(point: previous, stable: false)
    }

    /// The container to scroll: an explicit `--container`, else the largest
    /// scrollable node **in the topmost window**.
    ///
    /// The window filter matters: a snapshot holds every window in the process,
    /// so a background screen's page scroller can be larger than the foreground
    /// list and plain "largest" would move something invisible. Within the top
    /// window, largest is the right tie-break — a nested scroller is usually the
    /// smaller of the two.
    func scrollContainer(_ snapshot: Snapshot, _ params: [String: Any]) throws -> Node? {
        if let wanted = params["container"] as? String {
            guard let node = snapshot.nodes.values.first(where: {
                $0.testId == wanted || $0.resourceId == wanted || $0.ref == wanted
            }) else { throw HelperError("scroll-to: no node matched --container '\(wanted)'") }
            return node
        }
        func windowRef(of node: Node) -> String? {
            var current: Node? = node
            while let n = current {
                if n.kind == .window { return n.ref }
                current = n.parentRef.flatMap { snapshot.nodes[$0] }
            }
            return nil
        }
        let scrollables = snapshot.nodes.values.filter { $0.scroll?.isScrollable == true && $0.frame != nil }
        // Highest-stacked window that HAS a scroller: the keyboard is itself a
        // window in the scene, so "top window only" would find nothing when it is up.
        let windowRefs = (snapshot.root()?.children ?? []).filter { snapshot.nodes[$0]?.kind == .window }
        var scoped = Array(scrollables)
        for ref in windowRefs.reversed() {
            let inWindow = scrollables.filter { windowRef(of: $0) == ref }
            if !inWindow.isEmpty { scoped = inWindow; break }
        }
        return scoped.max { lhs, rhs in
            (lhs.frame!.width * lhs.frame!.height) < (rhs.frame!.width * rhs.frame!.height)
        }
    }

    func firstDirection(_ scroll: ScrollInfo) -> String? {
        if scroll.canScrollDown { return "down" }
        if scroll.canScrollRight { return "right" }
        if scroll.canScrollUp { return "up" }
        if scroll.canScrollLeft { return "left" }
        return nil
    }

    func canScroll(_ scroll: ScrollInfo, _ direction: String) -> Bool {
        switch direction {
        case "down": return scroll.canScrollDown
        case "up": return scroll.canScrollUp
        case "left": return scroll.canScrollLeft
        case "right": return scroll.canScrollRight
        default: return false
        }
    }

    func drag(
        _ frame: Rect, _ direction: String, surface: IosTouchSurface, screen: (Double, Double)
    ) async throws {
        let cx = frame.x + frame.width / 2
        let cy = frame.y + frame.height / 2
        let dx = frame.width * 0.3
        let dy = frame.height * 0.3
        let backend = surface
        // Content moves with the finger: dragging up scrolls DOWN.
        switch direction {
        case "down": try await backend.swipe(from: (cx, cy + dy), to: (cx, cy - dy), screen: screen, durationMs: 700)
        case "up": try await backend.swipe(from: (cx, cy - dy), to: (cx, cy + dy), screen: screen, durationMs: 700)
        case "right": try await backend.swipe(from: (cx + dx, cy), to: (cx - dx, cy), screen: screen, durationMs: 700)
        case "left": try await backend.swipe(from: (cx - dx, cy), to: (cx + dx, cy), screen: screen, durationMs: 700)
        default: throw HelperError("scroll-to: unknown --direction '\(direction)'")
        }
    }

    /// A selector miss inside a lazy list is a different failure from a wrong
    /// selector: the row has no node until it is realized. When the screen holds a
    /// container with travel left, say so — stating the fact, not promising the
    /// element is down there. Mirrors the Android helper's diagnostics.
    static func scrollHint(_ snapshot: Snapshot) -> String {
        let scrollable = snapshot.nodes.values.filter { $0.scroll?.isScrollable == true }.prefix(3)
        if scrollable.isEmpty { return "" }
        let described = scrollable.map { node -> String in
            let id = node.testId ?? node.resourceId ?? node.ref
            return "'\(id)' (\(node.scroll?.describe() ?? ""))"
        }.joined(separator: ", ")
        return ". Note: the screen has scrollable content (\(described)); "
            + "a lazy list only realizes its visible window, so an unrealized row has no node yet"
    }

    func parsePoint(_ raw: Any?) -> Point? {
        guard let s = raw as? String else { return nil }
        let parts = s.split(separator: ",")
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
        return Point(x: x, y: y)
    }
}

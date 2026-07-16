import Foundation

/// The subset of the view snapshot that carries a usable targeting signal,
/// projected to a compact per-node shape. Mirrors reticle-core's `SemanticTree`.
public struct SemanticTree: Codable, Sendable {
    public var rootRef: String
    public var nodes: [String: SemanticNode]

    public init(rootRef: String, nodes: [String: SemanticNode]) {
        self.rootRef = rootRef
        self.nodes = nodes
    }

    public func node(_ ref: String) -> SemanticNode? { nodes[ref] }
    public func root() -> SemanticNode? { nodes[rootRef] }
    public func findByTestId(_ testId: String) -> SemanticNode? {
        nodes.values.first { $0.testId == testId }
    }
    public func findByResourceId(_ resourceId: String) -> SemanticNode? {
        nodes.values.first { $0.resourceId == resourceId }
    }

    /// Build a semantic view from a snapshot, keeping only nodes that carry a
    /// targeting signal. Ports reticle-core's `SemanticTree.build` step for step;
    /// iteration follows the snapshot's own child order for deterministic output.
    public static func build(from: Snapshot) -> SemanticTree {
        // 1. Which nodes carry a targeting signal and are therefore kept.
        var kept = Set<String>()
        for (ref, node) in from.nodes where node.hasTargetingSignal() {
            kept.insert(ref)
        }

        // 2. Nearest kept ancestor of a ref, walking parentRef upward.
        func nearestKeptAncestor(_ ref: String) -> String? {
            var cur = from.nodes[ref]?.parentRef
            while let c = cur {
                if kept.contains(c) { return c }
                cur = from.nodes[c]?.parentRef
            }
            return nil
        }

        // 3. Kept children of a ref: nearest kept descendants along each branch,
        //    preserving order.
        func keptDescendants(_ ref: String) -> [String] {
            var out: [String] = []
            func collect(_ childRef: String) {
                if kept.contains(childRef) {
                    out.append(childRef)
                } else {
                    for c in from.nodes[childRef]?.children ?? [] { collect(c) }
                }
            }
            for c in from.nodes[ref]?.children ?? [] { collect(c) }
            return out
        }

        // Build kept semantic nodes in snapshot child order (deterministic),
        // starting from the root and walking children.
        var nodes: [String: SemanticNode] = [:]
        for ref in orderedRefs(from) where kept.contains(ref) {
            guard let node = from.nodes[ref] else { continue }
            nodes[ref] = SemanticNode(
                ref: ref,
                parentRef: nearestKeptAncestor(ref),
                role: node.role ?? node.typeName,
                label: node.contentDescription ?? node.text,
                resourceId: node.resourceId,
                testId: node.testId,
                frame: node.frame,
                isEnabled: node.isEnabled,
                isInteractive: node.isInteractive,
                children: keptDescendants(ref)
            )
        }

        // 4. Synthesize a lightweight root when the snapshot root wasn't kept.
        let rootRef = from.rootRef
        if nodes[rootRef] == nil {
            let topLevel = orderedRefs(from).filter { nodes[$0]?.parentRef == nil && nodes[$0] != nil }
            for ref in topLevel {
                nodes[ref]?.parentRef = rootRef
            }
            let rootNode = from.nodes[rootRef]
            nodes[rootRef] = SemanticNode(
                ref: rootRef,
                parentRef: nil,
                role: rootNode?.role ?? rootNode?.typeName ?? "root",
                children: topLevel
            )
        }
        return SemanticTree(rootRef: rootRef, nodes: nodes)
    }

    /// Snapshot refs in a stable DFS order from the root, so derivations are
    /// deterministic regardless of dictionary hashing.
    private static func orderedRefs(_ snapshot: Snapshot) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func visit(_ ref: String) {
            guard !seen.contains(ref), let node = snapshot.nodes[ref] else { return }
            seen.insert(ref)
            out.append(ref)
            for c in node.children { visit(c) }
        }
        visit(snapshot.rootRef)
        // Include any orphan nodes not reachable from the root, in a stable order.
        for ref in snapshot.nodes.keys.sorted() where !seen.contains(ref) {
            visit(ref)
        }
        return out
    }
}

public struct SemanticNode: Codable, Sendable, Equatable {
    public var ref: String
    public var parentRef: String?
    public var role: String
    public var label: String?
    public var resourceId: String?
    public var testId: String?
    public var frame: Rect?
    public var isEnabled: Bool
    public var isInteractive: Bool
    public var children: [String]

    public init(
        ref: String,
        parentRef: String? = nil,
        role: String,
        label: String? = nil,
        resourceId: String? = nil,
        testId: String? = nil,
        frame: Rect? = nil,
        isEnabled: Bool = true,
        isInteractive: Bool = false,
        children: [String] = []
    ) {
        self.ref = ref
        self.parentRef = parentRef
        self.role = role
        self.label = label
        self.resourceId = resourceId
        self.testId = testId
        self.frame = frame
        self.isEnabled = isEnabled
        self.isInteractive = isInteractive
        self.children = children
    }

    private enum CodingKeys: String, CodingKey {
        case ref, parentRef, role, label, resourceId, testId, frame, isEnabled, isInteractive, children
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ref, forKey: .ref)
        try c.encodeIfPresent(parentRef, forKey: .parentRef)
        try c.encode(role, forKey: .role)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(resourceId, forKey: .resourceId)
        try c.encodeIfPresent(testId, forKey: .testId)
        try c.encodeIfPresent(frame, forKey: .frame)
        if !isEnabled { try c.encode(isEnabled, forKey: .isEnabled) }
        if isInteractive { try c.encode(isInteractive, forKey: .isInteractive) }
        if !children.isEmpty { try c.encode(children, forKey: .children) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ref = try c.decode(String.self, forKey: .ref)
        parentRef = try c.decodeIfPresent(String.self, forKey: .parentRef)
        role = try c.decode(String.self, forKey: .role)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        resourceId = try c.decodeIfPresent(String.self, forKey: .resourceId)
        testId = try c.decodeIfPresent(String.self, forKey: .testId)
        frame = try c.decodeIfPresent(Rect.self, forKey: .frame)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isInteractive = try c.decodeIfPresent(Bool.self, forKey: .isInteractive) ?? false
        children = try c.decodeIfPresent([String].self, forKey: .children) ?? []
    }
}

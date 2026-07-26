import ReticleProtocol

/// The protocol's target selector, under a name that cannot be confused with
/// ObjC's `Selector` (which Foundation brings into every file here).
///
/// Module-internal rather than per-file private: the backend's helpers pass
/// selectors across file boundaries now that the client is split by concern, and a
/// private alias cannot appear in an internal signature.
typealias TargetSelector = ReticleProtocol.Selector

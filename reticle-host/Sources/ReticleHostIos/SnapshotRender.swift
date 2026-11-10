import Foundation
import ReticleHostShared
import ReticleProtocol

/// `ui <view>` over a snapshot the host already holds — for BOTH platforms.
///
/// Rendering is pure: a snapshot in, text out. It used to run in the Kotlin helper
/// for Android and here for iOS, two ports of one formatter kept honest only by
/// shared fixtures. Android now ships its snapshot to the host and renders here
/// too, so a format change is one edit. `outline` is rendered by `Outline` (Android
/// only for now; `Render.view` refuses it by name for iOS).
public enum SnapshotRender {
    public static func render(_ request: RenderRequest, snapshot: Snapshot) throws -> RenderResult {
        let text = try Render.view(
            request.view,
            snapshot: try scoped(snapshot, window: request.window),
            depth: request.depth ?? Int.max,
            selector: request.selector.protocolSelector
        )
        return RenderResult(text: text)
    }

    /// The capture narrowed to `--window`, applied to the SNAPSHOT so every view —
    /// and the outline's `@N` numbering — narrows identically. An unknown ref is an
    /// error naming the windows that exist, never a silent full render.
    public static func scoped(_ snapshot: Snapshot, window: String?) throws -> Snapshot {
        guard let window else { return snapshot }
        guard let scoped = snapshot.scopedToWindow(window) else {
            let refs = snapshot.windowRefs()
            throw HelperError("no window '\(window)' in this capture. Windows here (bottom to top): "
                + (refs.isEmpty ? "(none — this capture has no window nodes)" : refs.joined(separator: ", "))
                + ". Use `--window top` for whichever is on top.")
        }
        return scoped
    }

    /// A snapshot file on disk, as `ui <view> <path>` names it.
    public static func load(path: String) throws -> Snapshot {
        try decode(Data(contentsOf: URL(fileURLWithPath: path)))
    }

    public static func decode(_ data: Data) throws -> Snapshot {
        try ReticleJSON.decode(Snapshot.self, from: data).requireSupportedSchema()
    }
}

import Foundation
import ReticleProtocol

/// Endpoint dispatch — the iOS analogue of `ReticleServer.route`. Every route is
/// wrapped so a thrown error becomes a 500 rather than dropping the socket.
/// Capture, screenshot, and mutation run on the main thread (see `MainThread`).
struct Router {
    func route(_ request: HttpRequest) -> HttpResponse {
        do {
            switch (request.method, request.path) {
            case ("GET", Endpoints.runtime):
                return try json(ReticleRuntime.shared.runtimeInfo())
            case ("GET", Endpoints.snapshot):
                return try json(captureSnapshot())
            case ("GET", Endpoints.report):
                return try json(UiReport.from(captureSnapshot()))
            case ("GET", Endpoints.semantics):
                return try json(SemanticTree.build(from: captureSnapshot()))
            case ("GET", Endpoints.compact):
                return try json(CompactObservation.from(captureSnapshot()))
            case ("GET", Endpoints.logs):
                return try json(LogBatch(entries: ReticleRuntime.shared.collectedLogs()))
            case ("GET", Endpoints.screenshot):
                return screenshot()
            case ("POST", Endpoints.mutate):
                return try mutate(request.body)
            case ("POST", Endpoints.activate):
                return try activate(request.body)
            case ("POST", Endpoints.clipboard):
                return clipboard(request.body)
            default:
                return HttpResponse.text(404, "no route for \(request.method) \(request.path)")
            }
        } catch {
            return HttpResponse.text(500, "\(type(of: error)): \(error)")
        }
    }

    private func json<T: Encodable>(_ value: T) throws -> HttpResponse {
        HttpResponse.json(200, try ReticleJSON.encodeWire(value))
    }

    /// Two-phase capture: the view walk runs on main; any WKWebView DOM is then
    /// folded in from THIS (server) thread, which can safely block while the
    /// JS evaluation completes back on main.
    private func captureSnapshot() throws -> Snapshot {
        #if canImport(WebKit)
        let transport = MainThread.sync { SnapshotCapture().captureForTransport() }
        var snapshot = transport.snapshot
        WebViewBridge.captureInto(&snapshot, pending: transport.pendingWebViews, nextRef: transport.nextRef)
        return snapshot
        #else
        return try MainThread.sync { try SnapshotCapture().capture() }
        #endif
    }

    private func screenshot() -> HttpResponse {
        do {
            let png = try MainThread.sync { try ScreenshotCapture().capturePng() }
            return HttpResponse.png(png)
        } catch {
            return HttpResponse.text(500, "screenshot failed: \(error)")
        }
    }

    private func mutate(_ body: Data) throws -> HttpResponse {
        let req = try ReticleJSON.decode(MutationRequest.self, from: body)
        let result = try MainThread.sync { MutationEngine().apply(req) }
        return try json(result)
    }

    private func activate(_ body: Data) throws -> HttpResponse {
        let req = try ReticleJSON.decode(ActivationRequest.self, from: body)
        #if canImport(WebKit)
        // A CSS selector targets a domNode: resolve + dispatch inside the web
        // content from THIS (server) thread, which can block on the JS round
        // trip (the main thread cannot).
        if let css = req.selector.cssSelector, !css.isEmpty {
            let transport = MainThread.sync { SnapshotCapture().captureForTransport() }
            let result = WebActivation.activate(selectorChain: css, pending: transport.pendingWebViews)
            return try json(result)
        }
        #endif
        let result = try MainThread.sync { ActivationEngine().activate(req) }
        return try json(result)
    }

    private func clipboard(_ body: Data) -> HttpResponse {
        let text = String(decoding: body, as: UTF8.self)
        MainThread.async { ClipboardWriter.set(text) }
        return HttpResponse.text(200, "ok")
    }
}

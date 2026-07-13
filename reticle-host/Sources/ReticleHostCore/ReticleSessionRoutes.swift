import Foundation
import Hummingbird

struct ReticleSessionRoutes: Sendable {
    let store: EventStore
    let traceIngest: ActionTraceIngest
    let port: @Sendable () -> Int

    func register(on router: Router<BasicRequestContext>) {
        router.get("health") { _, _ -> Response in
            try jsonResponse(HealthResponse(ok: true, session: store.session, port: port(), eventCount: store.eventCount))
        }
        router.get("sessions") { _, _ -> Response in
            try jsonResponse(SessionsResponse(sessions: store.sessionInfos()))
        }
        router.get("sessions/current/events") { request, _ -> Response in
            try sessionEventsResponse(session: store.session, since: query(request, "since"))
        }
        router.get("sessions/:session/events") { request, context -> Response in
            try sessionEventsResponse(session: try sessionParameter(context), since: query(request, "since"))
        }
        router.get("sessions/current/artifacts") { request, _ -> Response in
            try artifactResponse(session: store.session, eventId: query(request, "event"), refName: query(request, "ref"))
        }
        router.get("sessions/:session/artifacts") { request, context -> Response in
            try artifactResponse(
                session: try sessionParameter(context),
                eventId: query(request, "event"),
                refName: query(request, "ref")
            )
        }
        router.post("sessions/current/events") { request, _ -> Response in
            let body = try await badRequestOnDecode {
                try await decode(EventPostRequest.self, from: request)
            }
            return try jsonResponse(store.append(body), status: .created)
        }
        router.post("sessions/current/action-traces") { request, _ -> Response in
            let body = try await badRequestOnDecode {
                try await traceIngest.event(from: requestBodyData(request))
            }
            // A trace's evidence lives in the trace directory the caller pointed
            // at (e.g. a user-chosen --trace-output). Trust that directory so its
            // artifacts can be served, without opening the whole filesystem.
            for path in body.refs.values {
                store.registerArtifactRoot(URL(fileURLWithPath: path).deletingLastPathComponent())
            }
            return try jsonResponse(store.append(body), status: .created)
        }
    }

    private func sessionEventsResponse(session id: String, since: String?) throws -> Response {
        do {
            return try jsonResponse(EventsResponse(events: store.historicalEvents(session: id, since: since)))
        } catch let error as EventStoreError {
            throw HTTPError(.notFound, message: error.description)
        }
    }

    private func artifactResponse(session id: String, eventId: String?, refName: String?) throws -> Response {
        guard let eventId, let refName, !eventId.isEmpty, !refName.isEmpty else {
            throw HTTPError(.badRequest, message: "artifact requests require event and ref")
        }
        let event: ReticleEventEnvelope?
        do {
            event = try store.historicalEvent(session: id, eventId: eventId)
        } catch let error as EventStoreError {
            throw HTTPError(.notFound, message: error.description)
        }
        guard let event else {
            throw HTTPError(.notFound, message: "event not found")
        }
        guard let path = event.refs[refName] else {
            throw HTTPError(.notFound, message: "artifact ref not found")
        }
        let url = URL(fileURLWithPath: path)
        // Confine reads to trusted artifact roots so a ref (which any local
        // process can inject via POST /sessions/current/events) cannot be used
        // to read arbitrary files off the host.
        guard store.isArtifactPathAllowed(url) else {
            throw HTTPError(.notFound, message: "artifact path is not allowed")
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            throw HTTPError(.notFound, message: "artifact file not found")
        }
        guard let fileType = attributes[.type] as? FileAttributeType, fileType == .typeRegular else {
            throw HTTPError(.notFound, message: "artifact is not a regular file")
        }
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount <= 25 * 1024 * 1024 else {
            throw HTTPError(.badRequest, message: "artifact is too large")
        }
        let data = try Data(contentsOf: url)
        return Response(
            status: .ok,
            headers: [.contentType: contentType(for: url)],
            body: .init(byteBuffer: buffer(from: data))
        )
    }
}

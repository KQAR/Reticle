import Foundation
import Testing
@testable import ReticleHostCore

/// Records calls and echoes them back — a stand-in for the resident helper.
private final class EchoBackend: HelperCalling, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(method: String, params: [String: Any])] = []
    var failWith: String?

    func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        lock.lock()
        calls.append((method, params))
        lock.unlock()
        if let failWith { throw HelperError(failWith) }
        return ["echoedMethod": method, "serial": params["serial"] ?? NSNull()]
    }
}

private func temporarySocketPath() -> String {
    // Keep it short: sockaddr_un caps paths at ~104 bytes.
    "/tmp/reticle-helperd-test-\(UUID().uuidString.prefix(8)).sock"
}

private func makeServer(
    backend: HelperCalling,
    socketPath: String,
    idleTimeout: TimeInterval = 60,
    backendAlive: @escaping @Sendable () -> Bool = { true }
) -> HelperDaemonServer {
    HelperDaemonServer(
        socketPath: socketPath,
        backend: backend,
        info: .init(version: ReticleCLI.version, helperPath: "/tmp/helper", helperMtime: 42),
        idleTimeout: idleTimeout,
        backendAlive: backendAlive
    )
}

@Suite("Helper daemon", .serialized)
struct HelperDaemonTests {
    @Test func roundTripForwardsToBackendAndInjectsSerial() throws {
        let backend = EchoBackend()
        let path = temporarySocketPath()
        let server = makeServer(backend: backend, socketPath: path)
        try server.start()
        defer { server.stop() }

        let client = try #require(SocketHelperClient(socketPath: path, serial: "emu-5554", callTimeout: 5))
        defer { client.close() }
        let result = try client.call("status", ["package": "dev.reticle.sample"])
        #expect(result["echoedMethod"] as? String == "status")
        #expect(result["serial"] as? String == "emu-5554")
        #expect(backend.calls.count == 1)
        #expect(backend.calls[0].params["package"] as? String == "dev.reticle.sample")
    }

    @Test func infoAnswersLocallyWithoutTouchingTheBackend() throws {
        let backend = EchoBackend()
        let path = temporarySocketPath()
        let server = makeServer(backend: backend, socketPath: path)
        try server.start()
        defer { server.stop() }

        let client = try #require(SocketHelperClient(socketPath: path, serial: nil, callTimeout: 5))
        defer { client.close() }
        let info = try client.call("helperd/info")
        #expect(info["version"] as? String == ReticleCLI.version)
        #expect(info["helperMtime"] as? Int == 42)
        #expect(backend.calls.isEmpty)
    }

    @Test func shutdownStopsTheServerAndUnlinksTheSocket() throws {
        let backend = EchoBackend()
        let path = temporarySocketPath()
        let server = makeServer(backend: backend, socketPath: path)
        try server.start()

        let client = try #require(SocketHelperClient(socketPath: path, serial: nil, callTimeout: 5))
        let result = try client.call("helperd/shutdown")
        #expect(result["stopping"] as? Bool == true)
        client.close()

        // stop() unlinks the socket just after flipping isStopped, so wait on
        // the terminal state (file gone) — the same signal the launcher polls.
        waitUntil(timeout: 2) { server.isStopped && !FileManager.default.fileExists(atPath: path) }
        #expect(server.isStopped)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func idleTimeoutStopsTheServerAndUnlinksTheSocket() throws {
        let backend = EchoBackend()
        let path = temporarySocketPath()
        let server = makeServer(backend: backend, socketPath: path, idleTimeout: 0.2)
        try server.start()

        waitUntil(timeout: 3) { server.isStopped }
        #expect(server.isStopped)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func deadBackendErrorStopsTheServerAfterReplying() throws {
        let backend = EchoBackend()
        backend.failWith = "helper closed stdout"
        let path = temporarySocketPath()
        let server = makeServer(backend: backend, socketPath: path, backendAlive: { false })
        try server.start()

        let client = try #require(SocketHelperClient(socketPath: path, serial: nil, callTimeout: 5))
        #expect(throws: (any Error).self) { try client.call("status") }
        client.close()

        waitUntil(timeout: 2) { server.isStopped && !FileManager.default.fileExists(atPath: path) }
        #expect(server.isStopped)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func secondBindOnALiveSocketFails() throws {
        let backend = EchoBackend()
        let path = temporarySocketPath()
        let server = makeServer(backend: backend, socketPath: path)
        try server.start()
        defer { server.stop() }

        let loser = makeServer(backend: backend, socketPath: path)
        #expect(throws: (any Error).self) { try loser.start() }
        // The loser must not have unlinked the winner's socket.
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func staleSocketFileIsReboundAfterACrash() throws {
        let backend = EchoBackend()
        let path = temporarySocketPath()
        // A crash leaves the socket file behind with nothing listening.
        FileManager.default.createFile(atPath: path, contents: nil)
        let server = makeServer(backend: backend, socketPath: path)
        try server.start()
        defer { server.stop() }

        let client = try #require(SocketHelperClient(socketPath: path, serial: nil, callTimeout: 5))
        defer { client.close() }
        let result = try client.call("ping")
        #expect(result["echoedMethod"] as? String == "ping")
    }

    private func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !predicate() {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}

@Suite("Helperd socket naming")
struct HelperdPathTests {
    @Test func plainSerialsKeepTheirName() {
        #expect(Helperd.fileKey("emulator-5554") == "emulator-5554")
        #expect(Helperd.fileKey("default") == "default")
    }

    @Test func transportSerialsAreSanitizedWithAStableSuffix() {
        let key = Helperd.fileKey("192.168.1.20:5555")
        #expect(!key.contains(":"))
        #expect(key == Helperd.fileKey("192.168.1.20:5555"))
    }

    @Test func distinctSerialsThatSanitizeAlikeStayDistinct() {
        #expect(Helperd.fileKey("a:b") != Helperd.fileKey("a-b"))
        #expect(Helperd.fileKey("a:b") != Helperd.fileKey("a.b"))
    }
}

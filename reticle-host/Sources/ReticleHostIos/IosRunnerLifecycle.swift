import Foundation
import Synchronization
import ReticleHostShared
import ReticleProtocol

/// Where the system channel is, as two states rather than one boolean.
///
/// The two failures need OPPOSITE repairs — `notInstalled` needs a full prepare
/// (build + sign + install), `installed` needs only a launch — so a single
/// "usable / not usable" flag cannot produce correct advice. This distinction is
/// the whole reason the spec defines both.
public enum SystemChannelState: String, Sendable, Equatable {
    /// Nothing on the device. Needs `system prepare`.
    case notInstalled
    /// Installed, but no live process. Needs a launch only.
    case installed
    /// Live and answering.
    case connected
}

/// Identity and addressing for the runner.
///
/// The port is derived with the SAME rule the agent uses (`PortMap`, FNV-1a over
/// the app id), just fed the runner's own bundle id. Reusing the rule rather than
/// inventing an allocator means there is one place where ports come from; feeding
/// it a different id is what keeps the runner off the app's port.
public struct IosRunnerConfig: Sendable, Equatable {
    /// Bundle id of the runner app. XCTest appends `.xctrunner` to the test
    /// target's id, which is why this value already carries the suffix.
    public var bundleId: String
    /// The app under test, needed to detect a port collision and to activate it.
    public var appBundleId: String

    public init(bundleId: String = IosRunnerConfig.defaultBundleId, appBundleId: String) {
        self.bundleId = bundleId
        self.appBundleId = appBundleId
    }

    public static let defaultBundleId = "dev.reticle.runner.xctrunner"

    /// The runner's EXECUTABLE name, which is what `devicectl device info
    /// processes` prints — that listing shows binary paths, not bundle ids.
    ///
    /// Matching the bundle id against it silently never matched, so `stop()`
    /// concluded there was nothing to stop and left the runner running while
    /// reporting success. A liveness check that can only answer "no" is worse than
    /// none, because everything downstream trusts it.
    public var processName: String = "ReticleRunner-Runner"

    public var port: Int { PortMap.derivePort(bundleId) }
    public var appPort: Int { PortMap.derivePort(appBundleId) }

    /// Both ends tunnel over USB to loopback ports, so two channels that hash to
    /// the same port would fight over one tunnel. The odds are ~1/1000, and the
    /// symptom would be intermittent, cross-talking failures that look like
    /// anything but a port clash — so it is refused up front instead of being left
    /// to chance.
    public func assertNoPortCollision() throws {
        guard port != appPort else {
            throw HelperError(
                "the system-channel runner (\(bundleId)) and the app under test "
                + "(\(appBundleId)) derive the same loopback port \(port), so their "
                + "USB tunnels would collide. Rename the runner bundle id to move it "
                + "off that port — a shared port would surface as intermittent, "
                + "misattributed failures rather than as a clash"
            )
        }
    }
}

/// Brings the runner from "nothing" to "answering", and takes it back down.
///
/// Everything here is deliberately shell-shaped: the pieces this depends on
/// (`devicectl`, `xcodebuild`, `iproxy`) are the same ones `scripts/e2e-ios-device.sh`
/// and `scripts/inject-ios-device.sh` already use, and this is not the place to
/// introduce a second way of talking to a device.
/// Sendable without an `@unchecked` promise: everything on it is immutable except
/// the resident child process, which lives inside a `Mutex`. The daemon can reach
/// one lifecycle from more than one request thread, so that field is a genuine
/// hand-off rather than a formality.
public final class IosRunnerLifecycle: Sendable {

    public let config: IosRunnerConfig
    /// The hardware UDID/ECID, and the only device identifier needed here.
    ///
    /// Measured: it is accepted by `devicectl --device`, `iproxy -u` AND
    /// `xcodebuild -destination id=` alike. The coredevice UUID that
    /// `devicectl list devices` prints works only for devicectl, so carrying both
    /// would add a way to be wrong without adding any reach.
    public let udid: String
    /// Where `prepare` put the build products, and therefore where the xctestrun
    /// that later sessions reuse lives.
    public let derivedDataPath: String

    /// The resident `test-without-building` child. Owning it is the only handle on
    /// a never-ending test. Behind a mutex, because `serve` and `stop` can land on
    /// different threads.
    private let serveProcess: Mutex<Process?> = Mutex(nil)

    public init(
        config: IosRunnerConfig,
        udid: String,
        derivedDataPath: String = IosRunnerLifecycle.defaultDerivedDataPath
    ) {
        self.config = config
        self.udid = udid
        self.derivedDataPath = derivedDataPath
    }

    public static let defaultDerivedDataPath =
        ("~/.reticle/system-runner/DerivedData" as NSString).expandingTildeInPath

    // MARK: - State

    public func state() -> SystemChannelState {
        guard isInstalled() else { return .notInstalled }
        return isAnswering() ? .connected : .installed
    }

    func isInstalled() -> Bool {
        let r = Self.shell("/usr/bin/xcrun", ["devicectl", "device", "info", "apps",
                                              "--device", udid])
        return r.out.contains(config.bundleId)
    }

    func isAnswering() -> Bool {
        (try? IosRunnerClient(config: config).health()) != nil
    }

    func isRunning() -> Bool {
        let r = Self.shell("/usr/bin/xcrun", ["devicectl", "device", "info", "processes",
                                              "--device", udid])
        return r.out.contains(config.processName)
    }

    // MARK: - Prepare (US1-1 .. US1-3, US1-5)

    /// Build, sign, install. Reports whether it replaced an existing install, so
    /// the command can say so (US1-5) rather than silently swapping something out
    /// from under the caller.
    public struct PrepareOutcome: Sendable {
        public var replacedExisting: Bool
        public var deviceId: String
        public var state: SystemChannelState
    }

    public func prepare(team: String, runnerProjectPath: String, derivedDataPath: String) throws -> PrepareOutcome {
        try config.assertNoPortCollision()
        try assertDeviceReady()
        try assertSigningUsable(team: team)

        let hadExisting = isInstalled()
        if hadExisting {
            // Replace rather than coexist: two installs of the same runner would
            // make "which one answered?" unanswerable.
            _ = Self.shell("/usr/bin/xcrun", ["devicectl", "device", "uninstall", "app",
                                              "--device", udid, config.bundleId])
        }

        let build = Self.shell("/usr/bin/xcodebuild", [
            "-project", runnerProjectPath,
            "-scheme", "ReticleRunner",
            "-destination", "platform=iOS,id=\(udid)",
            "-derivedDataPath", derivedDataPath,
            "CODE_SIGN_STYLE=Automatic",
            "DEVELOPMENT_TEAM=\(team)",
            "build-for-testing",
        ])
        guard build.code == 0 else {
            throw IosRunnerFailureClassifier.classify(launchOutput: build.err + build.out).asError
        }

        // NOTE: the built runner keeps its embedded `Frameworks/XC*`. Appium's docs
        // say to delete them so devicectl can launch the runner; measured on iOS 26
        // that is wrong — with them removed the test bundle fails to load with
        // `Library not loaded: @rpath/XCTestCore.framework/XCTestCore`, and with
        // them present devicectl launches it fine.
        let appPath = "\(derivedDataPath)/Build/Products/Debug-iphoneos/ReticleRunner-Runner.app"
        let install = Self.shell("/usr/bin/xcrun", ["devicectl", "device", "install", "app",
                                                    "--device", udid, appPath])
        guard install.code == 0 else {
            throw IosRunnerFailureClassifier.classify(launchOutput: install.err + install.out).asError
        }

        return PrepareOutcome(replacedExisting: hadExisting, deviceId: udid, state: .installed)
    }

    func assertDeviceReady() throws {
        let lock = Self.shell("/usr/bin/xcrun", ["devicectl", "device", "info", "lockState",
                                                 "--device", udid])
        guard lock.code == 0 else {
            throw IosRunnerFailureClassifier.classify(launchOutput: lock.err + lock.out).asError
        }
        // A dark screen is not a lock in the passcode sense, but a runner still
        // cannot take the foreground there, so both are refused with the same advice.
        let display = Self.shell("/usr/bin/xcrun", ["devicectl", "device", "info", "displays",
                                                    "--device", udid])
        if display.out.lowercased().contains("backlight is off") {
            throw IosRunnerStartFailure.deviceLocked.asError
        }
    }

    func assertSigningUsable(team: String) throws {
        let usable = Self.usableTeams()
        guard usable.contains(team) else {
            throw HelperError(
                "no usable signing material for team \(team) on this machine. "
                + "Teams with a wildcard provisioning profile here: "
                + (usable.isEmpty ? "(none found)" : usable.sorted().joined(separator: ", "))
                + ". A keychain certificate alone is not enough — the team also needs "
                + "a profile that lists this device"
            )
        }
    }

    /// Teams that have a wildcard provisioning profile cached on this machine.
    ///
    /// Read from the profiles on disk rather than from Xcode's account list,
    /// because automatic signing works off the cached profile: measured on this
    /// machine, Xcode had NO account signed in and signing still succeeded through
    /// a cached wildcard profile.
    public static func usableTeams() -> Set<String> {
        let dir = ("~/Library/Developer/Xcode/UserData/Provisioning Profiles" as NSString)
            .expandingTildeInPath
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        var teams: Set<String> = []
        for name in names where name.hasSuffix(".mobileprovision") {
            let r = shell("/usr/bin/security", ["cms", "-D", "-i", "\(dir)/\(name)"])
            guard r.code == 0 else { continue }
            guard let appId = Self.value(of: "application-identifier", in: r.out),
                  appId.hasSuffix(".*") else { continue }
            teams.insert(String(appId.dropLast(2)))
        }
        return teams
    }

    /// Pulls a plist string value out of decoded profile XML without a full parse.
    static func value(of key: String, in xml: String) -> String? {
        guard let keyRange = xml.range(of: "<key>\(key)</key>") else { return nil }
        let rest = xml[keyRange.upperBound...]
        guard let open = rest.range(of: "<string>"),
              let close = rest.range(of: "</string>"), open.upperBound <= close.lowerBound
        else { return nil }
        return String(rest[open.upperBound..<close.lowerBound])
    }

    // MARK: - Connect / stop (US1-4, NFR-011)

    /// Ensure a live, answering runner. Idempotent: an already-connected channel
    /// returns immediately, so repeated commands do not restart anything (US1-7).
    /// Ensure a live channel, reporting whether THIS call had to start it.
    ///
    /// The flag matters as much as the connection: starting the runner takes the
    /// foreground away from whatever was there, so a caller who is not told will
    /// attribute that interference to the app under test.
    @discardableResult
    public func ensureConnected(timeout: TimeInterval = 30) throws -> (state: SystemChannelState, didStart: Bool) {
        switch state() {
        case .connected:
            return (.connected, false)
        case .notInstalled:
            throw IosRunnerStartFailure.runnerNotInstalled.asError
        case .installed:
            break
        }

        // `devicectl device process launch` does NOT work here, and it is worth
        // stating why because it looks like it should: the runner starts, is
        // granted a backboardd HID connection and prints `Running tests...`, and
        // then exits within seconds without ever executing a test method. Measured
        // on iPhone 13 Pro Max / iOS 26 with a known-good environment (a baseline
        // never-ending test had just served over the same tunnel).
        //
        // What DOES keep it resident is `test-without-building` against the
        // xctestrun produced at prepare time. That still satisfies "no rebuild per
        // session" — the build happened once, in `prepare` — at the cost of the
        // host holding this child process for the channel's lifetime.
        // Clear any orphaned run first, for the same reason `stop` does: the device
        // has exactly one automation session, and an earlier command's child may
        // still be holding it.
        _ = Self.shell("/usr/bin/pkill", ["-f", "test-without-building.*\(udid)"])
        let launch = startServing()
        startTunnel()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isAnswering() { return (.connected, true) }
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Classify rather than surface the raw output — see IosRunnerFailure.
        throw IosRunnerFailureClassifier.classify(
            launchOutput: launch.err + launch.out,
            installed: true
        ).asError
    }

    /// The xctestrun `prepare` left behind, which is what makes a later session
    /// start without building anything.
    public func xctestrunPath(derivedDataPath: String) -> String? {
        let products = "\(derivedDataPath)/Build/Products"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: products) else {
            return nil
        }
        guard let name = names.first(where: { $0.hasSuffix(".xctestrun") }) else { return nil }
        return "\(products)/\(name)"
    }

    /// Launch the resident test run. Held as a child process because ending it is
    /// how the channel goes down — there is no other handle on a never-ending test.
    ///
    /// `Process`, not `Shell`: `Subprocess.run` owns the child for the duration of
    /// the call and reaps it on return, which is the opposite of what this needs —
    /// a process that outlives the function and is killed later by `stop()`.
    private func startServing() -> (out: String, err: String, code: Int32) {
        guard let xctestrun = xctestrunPath(derivedDataPath: derivedDataPath) else {
            return ("", "no xctestrun in \(derivedDataPath); run `system prepare` first", -1)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        p.arguments = [
            "test-without-building",
            "-xctestrun", xctestrun,
            "-destination", "platform=iOS,id=\(udid)",
        ]
        // Its output is a live test log that never ends; keeping a pipe would fill
        // and block. Failures are diagnosed from the health probe and the device
        // log instead.
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return ("", "\(error)", -1) }
        serveProcess.withLock { $0 = p }
        return ("", "", 0)
    }

    func startTunnel() {
        // A device's loopback is not the host's, so the port is forwarded over USB.
        // Same mechanism scripts/inject-ios-device.sh uses; ECID is the id here.
        _ = Self.shell("/usr/bin/pkill", ["-f", "iproxy \(config.port)"])
        // `Process` for the same reason as `startServing`: the tunnel must outlive
        // this call. The `pkill` above is one-shot, so it goes through `Shell`.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["iproxy", "-u", udid, "\(config.port)", "\(config.port)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// Take the channel down. Succeeds when there was nothing to stop (US1-8):
    /// "already gone" is the state the caller asked for.
    public struct StopOutcome: Sendable {
        public var hadLiveInstance: Bool
        public var state: SystemChannelState
    }

    @discardableResult
    public func stop() -> StopOutcome {
        let wasLive = isRunning()
        if wasLive {
            // Ask it to leave on its own first — a clean server shutdown beats a
            // signal, which can strand the port.
            _ = try? IosRunnerClient(config: config).shutdown()
            if isRunning() {
                _ = Self.shell("/usr/bin/xcrun", ["devicectl", "device", "process", "signal",
                                                  "--device", udid,
                                                  "--signal", "SIGTERM",
                                                  "--pid", pidOfRunner() ?? "0"])
            }
        }
        // The host-side child must go too, and an in-process reference is NOT
        // enough to find it: each CLI invocation is its own process, so the
        // xcodebuild started by an EARLIER command is an orphan by the time `stop`
        // runs. Left alive it holds the device's single automation session hostage
        // and the next command fails as "launched but never answered" — a symptom
        // that points nowhere near the cause. Match it on the command line instead.
        let child = serveProcess.withLock { child -> Process? in
            defer { child = nil }
            return child
        }
        if let child, child.isRunning { child.terminate() }
        _ = Self.shell("/usr/bin/pkill", ["-f", "test-without-building.*\(udid)"])
        _ = Self.shell("/usr/bin/pkill", ["-f", "iproxy \(config.port)"])
        return StopOutcome(hadLiveInstance: wasLive, state: isInstalled() ? .installed : .notInstalled)
    }

    func pidOfRunner() -> String? {
        let r = Self.shell("/usr/bin/xcrun", ["devicectl", "device", "info", "processes",
                                              "--device", udid])
        for line in r.out.split(separator: "\n") where line.contains(config.processName) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if let first = fields.first, Int(first) != nil { return String(first) }
        }
        return nil
    }

    // MARK: - Shell

    @discardableResult
    static func shell(_ launchPath: String, _ args: [String]) -> (out: String, err: String, code: Int32) {
        // Both pipes are drained concurrently — mandatory here, because
        // `xcodebuild` writes megabytes to both and a caller blocked on stdout
        // deadlocks the moment stderr's 64KB buffer fills. `Shell` owns that.
        let result = Shell.runSync(launchPath, args)
        return (result.out, result.err, result.code)
    }
}

/// Lock-guarded destination for the two concurrent pipe drains in `shell`.
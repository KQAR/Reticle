package dev.reticle.cli

import dev.reticle.cli.platform.CommandResult
import dev.reticle.cli.platform.DeviceController
import dev.reticle.cli.platform.DeviceState
import dev.reticle.cli.platform.android.Injector
import java.io.File
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * `Injector.inject()` orchestration, with a fake device and a [FakeJdwpVm] standing
 * in behind the adb forward — so the ordering that was only ever proven on a phone
 * is proven here.
 *
 * Two of its decisions are timing-critical and invisible in a normal successful run.
 * The JDWP handshake must happen BEFORE the dex is staged, because a freshly-started
 * debug process accepts attaches for a fraction of a second and then refuses them for
 * ~15s; `adb push` + `run-as` in that gap guarantees landing in the dead zone. And a
 * handshake that IS refused must be retried across the dead zone, re-issuing the
 * forward each time, rather than failing. Both are asserted here.
 */
class InjectorSequenceTest {

    /**
     * A device whose `forwardJdwp` really does put a JDWP server on the host port —
     * the closest in-process stand-in for an adb forward onto a debuggable process.
     */
    private class FakeDevice(
        private val refuseHandshakes: Int = 0,
        private val pid: Int? = 4242,
        private val forwardOk: Boolean = true,
        private val startValue: Int = 41_234,
    ) : DeviceController {
        val shellCommands = mutableListOf<String>()
        val runArgs = mutableListOf<List<String>>()
        val runAsArgs = mutableListOf<List<String>>()
        val forwardedPorts = mutableListOf<Int>()
        val removedForwards = mutableListOf<Int>()
        /** Completed handshakes at the moment the dex was pushed. */
        var handshakesWhenStaged: Int = -1
        var vm: FakeJdwpVm? = null

        override val serialOrNull: String? = "test-serial"

        override fun shell(command: String, timeoutSeconds: Long): CommandResult {
            shellCommands.add(command)
            if (command == "wm size") {
                return CommandResult(0, "Physical size: 1080x2400\nOverride size: 720x1600\n", "")
            }
            return CommandResult(0, "", "")
        }

        override fun run(vararg args: String, timeoutSeconds: Long): CommandResult {
            runArgs.add(args.toList())
            if (args.firstOrNull() == "push") {
                handshakesWhenStaged = vm?.completedHandshakes ?: 0
            }
            return CommandResult(0, "", "")
        }

        override fun runBytes(vararg args: String, timeoutSeconds: Long) = ByteArray(0)
        override fun forward(hostPort: Int, devicePort: Int) = CommandResult(0, "", "")

        override fun forwardJdwp(hostPort: Int, pid: Int): CommandResult {
            forwardedPorts.add(hostPort)
            if (!forwardOk) return CommandResult(1, "", "device offline")
            // A forward is idempotent from the caller's side; keep one VM per port.
            if (vm == null) {
                vm = FakeJdwpVm(
                    refuseHandshakes = refuseHandshakes,
                    startValue = startValue,
                    requestedPort = hostPort,
                ).start()
            }
            return CommandResult(0, "", "")
        }

        override fun removeForward(hostPort: Int): CommandResult {
            removedForwards.add(hostPort)
            return CommandResult(0, "", "")
        }

        override fun runAs(packageName: String, vararg args: String, timeoutSeconds: Long): CommandResult {
            runAsArgs.add(args.toList())
            return CommandResult(0, "", "")
        }

        override fun listDevices() = listOf("test-serial")
        override fun listDeviceStates() = listOf(DeviceState("test-serial", "device"))
        override fun pidOf(packageName: String): Int? = pid
        override fun screencap(timeoutSeconds: Long) = ByteArray(0)
        override fun deviceState(): String? = "device"
        override fun ensureDeviceReady(retries: Int) {}
        override fun agentLog(maxLines: Int) = emptyList<String>()
    }

    private var payload: File? = null
    private val devices = mutableListOf<FakeDevice>()

    private fun stagePayload() {
        val file = File.createTempFile("reticle-payload", ".jar")
        file.writeBytes(ByteArray(64))
        payload = file
        System.setProperty("reticle.payloadDex", file.absolutePath)
    }

    @AfterTest
    fun tearDown() {
        System.clearProperty("reticle.payloadDex")
        payload?.delete()
        devices.forEach { it.vm?.close() }
    }

    private fun device(
        refuseHandshakes: Int = 0,
        pid: Int? = 4242,
        forwardOk: Boolean = true,
        startValue: Int = 41_234,
    ): FakeDevice = FakeDevice(refuseHandshakes, pid, forwardOk, startValue).also { devices.add(it) }

    @Test
    fun injectHandshakesBeforeStagingTheDexAndReportsPidAndPort() {
        stagePayload()
        val device = device()

        val result = Injector.inject(device, "com.example.app", restartUnderDebugger = false)

        assertEquals(4242, result.pid)
        assertEquals(41_234, result.reportedPort)
        // The ordering that the dead-zone measurement forced: attach first, stage after.
        assertTrue(
            device.handshakesWhenStaged >= 1,
            "the dex was pushed before any handshake completed — that burns the short " +
                "accept window a freshly-started debug process has"
        )
        // The forward is always torn down, so a stale one can't shadow the next inject.
        assertTrue(device.removedForwards.isNotEmpty(), "the JDWP forward must be removed")
        assertEquals(device.forwardedPorts.first(), device.removedForwards.last())
    }

    /**
     * The payload lands read-only, after removing any previous copy. Both steps are
     * requirements rather than hygiene: ART's W^X policy refuses a dex writable by the
     * loading app's uid, and `cp` cannot overwrite the 0444 file a previous inject left.
     */
    @Test
    fun theDexIsStagedThroughRunAsAndLeftReadOnly() {
        stagePayload()
        val device = device()

        Injector.inject(device, "com.example.app", restartUnderDebugger = false)

        val verbs = device.runAsArgs.map { it.first() }
        assertEquals(listOf("mkdir", "rm", "cp", "chmod"), verbs, "staging order: $verbs")
        val chmod = device.runAsArgs.last { it.first() == "chmod" }
        assertEquals("0444", chmod[1], "ART's W^X policy refuses a dex the app can write")
        val removed = device.runAsArgs.first { it.first() == "rm" }
        val copied = device.runAsArgs.first { it.first() == "cp" }
        assertEquals(
            copied.last(), removed.last(),
            "the rm must target the same path the cp writes, or re-injection hits " +
                "\"Permission denied\" on the previous 0444 copy"
        )
    }

    /**
     * The looper nudge is a SWIPE at the screen centre from `wm size`, never a tap: a
     * tap at a hardcoded point presses whatever real UI is there (it could dismiss a
     * dialog or submit a form), while a swipe's worst case is scrolling slightly.
     */
    @Test
    fun theLooperNudgeIsASwipeAtTheScreenCentre() {
        stagePayload()
        val device = device()

        Injector.inject(device, "com.example.app", restartUnderDebugger = false)

        val swipes = device.shellCommands.filter { it.startsWith("input swipe") }
        assertTrue(swipes.isNotEmpty(), "the looper must be nudged; saw ${device.shellCommands}")
        // Override size 720x1600 → centre 360,800, dragged 80px up.
        assertEquals("input swipe 360 800 360 720 300", swipes.first())
        assertTrue(
            device.shellCommands.none { it.startsWith("input tap") },
            "a tap could activate real UI; the nudge must never be one"
        )
    }

    /**
     * The dead zone: a process that refuses the first attaches must be retried across
     * it, re-issuing the forward each time, because a forward bound onto the closed
     * transport stays a dud and does not self-heal.
     */
    @Test
    fun aRefusedHandshakeIsRetriedAcrossTheDeadZone() {
        stagePayload()
        val device = device(refuseHandshakes = 3)

        val result = Injector.inject(device, "com.example.app", restartUnderDebugger = false)

        assertEquals(41_234, result.reportedPort, "the inject must ride the refusals out, not fail")
        assertTrue(
            device.forwardedPorts.size > 1,
            "each retry must re-issue the forward; saw ${device.forwardedPorts.size} forward(s)"
        )
        assertTrue(
            device.forwardedPorts.distinct().size == 1,
            "the retries must reuse the same probed-free host port, not walk the range"
        )
        // The staging still happened once, after the handshake finally landed.
        assertEquals(1, device.runArgs.count { it.firstOrNull() == "push" })
    }

    @Test
    fun anAppThatIsNotRunningIsAnErrorSayingHowToStartIt() {
        stagePayload()
        val device = device(pid = null)

        val failure = assertFailsWith<CliError> {
            Injector.inject(device, "com.example.app", restartUnderDebugger = false)
        }
        assertTrue(failure.message!!.contains("is not running"), failure.message!!)
        assertTrue(failure.message!!.contains("monkey"), "the message must say how to start it")
        assertTrue(device.forwardedPorts.isEmpty(), "no forward is opened for a dead app")
    }

    /**
     * A forward that fails is almost always a non-debuggable build, and that is the one
     * thing no retry can fix — so the error says it instead of retrying for 20s.
     */
    @Test
    fun aFailedForwardNamesTheDebuggableRequirement() {
        stagePayload()
        val device = device(forwardOk = false)

        val failure = assertFailsWith<CliError> {
            Injector.inject(device, "com.example.app", restartUnderDebugger = false)
        }
        assertTrue(failure.message!!.contains("could not forward JDWP"), failure.message!!)
        assertTrue(failure.message!!.contains("debuggable"), failure.message!!)
    }

    /**
     * A negative `Bootstrap.ERR_*` is reported as the port, not thrown: the caller
     * verifies liveness over HTTP anyway, and the code is the only diagnosis the
     * injected side can give.
     */
    @Test
    fun aBootstrapErrorCodeIsReportedRatherThanThrown() {
        stagePayload()
        val device = device(startValue = -2)

        val result = Injector.inject(device, "com.example.app", restartUnderDebugger = false)

        assertEquals(-2, result.reportedPort)
        assertTrue(device.removedForwards.isNotEmpty(), "the forward is still cleaned up")
    }
}

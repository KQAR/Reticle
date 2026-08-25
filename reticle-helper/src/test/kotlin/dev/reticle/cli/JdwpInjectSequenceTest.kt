package dev.reticle.cli

import dev.reticle.cli.platform.android.JdwpClient
import java.io.DataInputStream
import java.net.Socket
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * `JdwpClient.inject()` against [FakeJdwpVm]: the breakpoint/InvokeMethod sequence
 * that was previously proven only on a device.
 *
 * The comments in `inject()` make several load-bearing ordering claims — the
 * argument Strings are created only AFTER the thread is suspended (a CreateString
 * result has no GC root and was measured being collected during the wait, surfacing
 * as JDWP error 20); the breakpoint is one method rather than METHOD_ENTRY, so ART
 * doesn't deoptimize the whole app; the thread is resumed whatever happens. Each of
 * those is an assertion here, because each is invisible in a passing device run and
 * catastrophic when it silently regresses.
 */
class JdwpInjectSequenceTest {

    private val vms = mutableListOf<FakeJdwpVm>()

    @AfterTest
    fun tearDown() {
        vms.forEach { it.close() }
    }

    private fun vm(
        eventDelayMillis: Long = 0,
        deliverEvent: Boolean = true,
        constructorException: Long = 0,
        loadedClassObject: Long? = null,
        startTag: Int = FakeJdwpVm.TAG_INT,
        startValue: Int = 41_234,
    ): FakeJdwpVm = FakeJdwpVm(
        eventDelayMillis = eventDelayMillis,
        deliverEvent = deliverEvent,
        constructorException = constructorException,
        loadedClassObject = loadedClassObject,
        startTag = startTag,
        startValue = startValue,
    ).start().also { vms.add(it) }

    private fun <T> connected(vm: FakeJdwpVm, block: (JdwpClient) -> T): T =
        JdwpClient(Socket("127.0.0.1", vm.port)).use { client ->
            client.handshake()
            client.negotiateIdSizes()
            block(client)
        }

    @Test
    fun injectRunsTheWholeSequenceAndReturnsTheReportedPort() {
        val vm = vm()
        var triggers = 0
        val port = connected(vm) { it.inject("/data/data/app/code_cache/payload.jar") { triggers++ } }

        assertEquals(41_234, port, "the port Bootstrap.start() reported is the return value")
        assertTrue(triggers >= 1, "the trigger must be fired at least once to drive the looper")

        // The strings the injection needs, and no others: the loader class name, the
        // dex path, and the bootstrap class name.
        assertEquals(
            listOf(
                "dalvik.system.PathClassLoader",
                "/data/data/app/code_cache/payload.jar",
                "dev.reticle.agent.Bootstrap",
            ),
            vm.createdStrings
        )
        // Every created String is pinned against GC (ObjectReference.DisableCollection),
        // which is what the measured JDWP error 20 forced.
        assertEquals(3, vm.commands.count { it == 9 to 7 }, "each created String must be pinned")
        // The thread is resumed, and the breakpoint cleared, so the app runs full speed
        // again after we detach.
        assertTrue(vm.commands.contains(11 to 3), "the suspended thread must be resumed")
        assertTrue(vm.commands.contains(15 to 2), "the breakpoint must be cleared")
    }

    /**
     * The GC-window claim, as an ordering assertion: no String may be created before
     * the thread is suspended at the event. Creating them earlier is what produced
     * INVALID_OBJECT on a busy app, and nothing about a passing run would show it.
     */
    @Test
    fun argumentStringsAreCreatedOnlyAfterTheBreakpointIsArmed() {
        val vm = vm()
        connected(vm) { it.inject("/data/payload.jar") {} }

        val breakpointArmed = vm.indexOf(15, 1)
        val firstString = vm.indexOf(1, 11)
        assertTrue(breakpointArmed >= 0, "a breakpoint must be armed")
        assertTrue(firstString >= 0, "argument strings must be created")
        assertTrue(
            breakpointArmed < firstString,
            "strings must be created after the thread is suspended, not before the wait: " +
                "breakpoint at $breakpointArmed, first CreateString at $firstString"
        )
    }

    /**
     * A BREAKPOINT at `Handler.dispatchMessage` code index 0, `Count(1)`, suspending
     * only the event thread. Every part of that is deliberate: METHOD_ENTRY forces a
     * whole-app deoptimization that ANR-kills a heavy app, `Count(1)` makes ART drop
     * the breakpoint after one hit, and suspending only the event thread keeps the
     * rest of the app alive.
     */
    @Test
    fun theBreakpointIsOneMethodWithCountOneOnTheEventThread() {
        val vm = vm()
        connected(vm) { it.inject("/data/payload.jar") {} }

        val body = vm.bodiesOf(15, 1).single()
        val reader = DataInputStream(body.inputStream())
        assertEquals(2, reader.readByte().toInt(), "eventKind must be BREAKPOINT (2), not METHOD_ENTRY")
        assertEquals(1, reader.readByte().toInt(), "suspendPolicy must be EVENT_THREAD")
        assertEquals(2, reader.readInt(), "two modifiers: Count and LocationOnly")
        assertEquals(1, reader.readByte().toInt(), "first modifier is Count")
        assertEquals(1, reader.readInt(), "Count(1) — ART removes the breakpoint after one hit")
        assertEquals(7, reader.readByte().toInt(), "second modifier is LocationOnly")
        assertEquals(1, reader.readByte().toInt(), "location typeTag CLASS")
        assertEquals(FakeJdwpVm.HANDLER_TYPE, reader.readLong(), "instrumented class is android.os.Handler")
        assertEquals(FakeJdwpVm.DISPATCH_MESSAGE, reader.readLong(), "instrumented method is dispatchMessage")
        assertEquals(0L, reader.readLong(), "code index 0 — the method entry")
    }

    /**
     * The loader is built as `PathClassLoader(dexPath, systemClassLoader)`. The parent
     * matters: with the boot loader the injected agent could not see the app's own
     * classes, and `DexClassLoader`'s legacy 4-arg constructor NPEs on modern ART —
     * both of which are silent-wrong-loader failures rather than errors.
     */
    @Test
    fun theLoaderIsBuiltOnTheAppsOwnClassLoader() {
        val vm = vm()
        connected(vm) { it.inject("/data/data/app/code_cache/payload.jar") {} }

        val body = vm.bodiesOf(3, 4).single()
        val reader = DataInputStream(body.inputStream())
        assertEquals(FakeJdwpVm.PATH_LOADER_TYPE, reader.readLong(), "constructs a PathClassLoader")
        assertEquals(FakeJdwpVm.THREAD_ID, reader.readLong(), "on the thread the breakpoint suspended")
        assertEquals(FakeJdwpVm.PATH_LOADER_CTOR, reader.readLong())
        assertEquals(2, reader.readInt(), "(String dexPath, ClassLoader parent)")
        reader.readByte()                                  // arg tag
        val dexPathString = reader.readLong()
        reader.readByte()
        assertEquals(FakeJdwpVm.SYSTEM_LOADER, reader.readLong(), "parent is the app's own loader")
        assertTrue(dexPathString != 0L, "the dex path argument must be a real String object")
    }

    /** The trigger keeps firing while the event has not arrived — one nudge may not land. */
    @Test
    fun theTriggerIsRepeatedUntilTheEventArrives() {
        val vm = vm(eventDelayMillis = 1_500)
        var triggers = 0
        val port = connected(vm) { it.inject("/data/payload.jar") { triggers++ } }

        assertEquals(41_234, port)
        assertTrue(triggers >= 2, "a single nudge is not enough to rely on; saw $triggers")
    }

    /**
     * `Bootstrap.start()` answers a negative `ERR_*` code instead of a port when the
     * agent started but could not bind. That is a RESULT, not a failure: the caller
     * reports it (and verifies liveness over HTTP), so swallowing or throwing here
     * would lose the only diagnosis the injected side can give.
     */
    @Test
    fun aNegativeBootstrapResultIsReturnedRatherThanThrown() {
        val vm = vm(startValue = -3)
        val port = connected(vm) { it.inject("/data/payload.jar") {} }
        assertEquals(-3, port)
    }

    @Test
    fun aNonIntBootstrapResultIsAnErrorThatNamesTheTag() {
        val vm = vm(startTag = FakeJdwpVm.TAG_VOID, startValue = 0)
        val failure = assertFailsWith<IllegalStateException> {
            connected(vm) { it.inject("/data/payload.jar") {} }
        }
        assertTrue(
            failure.message!!.contains("non-int"),
            "the failure must name the tag mismatch: ${failure.message}"
        )
        assertTrue(vm.commands.contains(11 to 3), "the thread is resumed even on a bad result")
    }

    /**
     * A constructor that throws inside the target is reported with the exception's
     * class and message, read back over the still-suspended thread. The alternative —
     * "objectId=700" — is the error text that sent someone to a device to find out
     * that the dex was unreadable.
     */
    @Test
    fun aConstructorThrowIsDescribedRatherThanReportedAsAnObjectId() {
        val vm = vm(constructorException = FakeJdwpVm.EXCEPTION_OBJECT)
        val failure = assertFailsWith<IllegalStateException> {
            connected(vm) { it.inject("/data/payload.jar") {} }
        }

        val message = failure.message!!
        assertTrue(message.contains("java.io.IOException"), "expected the exception class: $message")
        assertTrue(message.contains(FakeJdwpVm.EXCEPTION_MESSAGE), "expected getMessage(): $message")
        assertTrue(vm.commands.contains(11 to 3), "the thread is resumed even after a throw")
    }

    @Test
    fun aLoaderThatResolvesNothingIsAnErrorNamingTheClass() {
        val vm = vm(loadedClassObject = 0)
        val failure = assertFailsWith<IllegalStateException> {
            connected(vm) { it.inject("/data/payload.jar") {} }
        }
        assertTrue(
            failure.message!!.contains("dev.reticle.agent.Bootstrap"),
            "the failure must name what failed to load: ${failure.message}"
        )
        assertTrue(vm.commands.contains(11 to 3), "the thread is resumed even when loadClass fails")
    }

    /**
     * An app whose looper never runs the instrumented method: the wait must end with
     * an actionable message, and the breakpoint must be cleared on the way out — a
     * leaked breakpoint keeps that method deoptimized after we detach.
     */
    @Test
    fun anEventThatNeverArrivesTimesOutAndClearsTheBreakpoint() {
        val vm = vm(deliverEvent = false)
        System.setProperty("reticle.jdwp.eventTimeoutMs", "600")
        try {
            val failure = assertFailsWith<IllegalStateException> {
                connected(vm) { it.inject("/data/payload.jar") {} }
            }
            assertTrue(
                failure.message!!.contains("timed out waiting for a JDWP event"),
                "the failure must say no thread was available: ${failure.message}"
            )
        } finally {
            System.clearProperty("reticle.jdwp.eventTimeoutMs")
        }
        assertTrue(
            vm.commands.contains(15 to 2),
            "the breakpoint must be cleared even when the event never fires"
        )
        assertTrue(
            vm.commands.none { it == 11 to 3 },
            "there is no thread to resume — resuming an arbitrary one would be a guess"
        )
    }
}

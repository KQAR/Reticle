package dev.reticle.cli

import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.ServerSocket
import java.net.Socket
import kotlin.concurrent.thread

/**
 * A fake JDWP virtual machine: enough of the protocol for `JdwpClient.inject()` to
 * run its whole sequence end to end, in-process, with no device and no adb.
 *
 * Why this exists at all: the injection sequence — arm a breakpoint, wait for the
 * event, create the argument Strings only once a thread is suspended, build a
 * PathClassLoader, `loadClass`, call `Bootstrap.start()`, resume — was proven only
 * on a device, so every ordering claim in its comments (and there are several load-
 * bearing ones) was unpinned. Everything a test needs to *see* is recorded here:
 * each command in arrival order, the bodies of the ones whose shape matters, and
 * the failure a caller staged.
 *
 * The VM answers with a small fixed class world, described in [refTypes] below. Ids
 * are chosen to be distinguishable on sight in a failure message rather than
 * realistic.
 */
class FakeJdwpVm(
    /** Milliseconds after `EventRequest.Set` before the breakpoint event is delivered. */
    private val eventDelayMillis: Long = 0,
    /** When false, the breakpoint event is never delivered — the wedged-app shape. */
    private val deliverEvent: Boolean = true,
    /** Object id of the exception the PathClassLoader constructor "threw", or 0. */
    private val constructorException: Long = 0,
    /** Value `loadClass` returns; 0 models a loader that resolved nothing. */
    private val loadedClassObject: Long? = null,
    /** Tag `Bootstrap.start()` answers with. Non-int models a signature mismatch. */
    private val startTag: Int = TAG_INT,
    /** Value `Bootstrap.start()` answers with — a port, or a negative `ERR_*`. */
    private val startValue: Int = 41_234,
    /** Refuse the handshake this many times before serving properly (the dead zone). */
    private val refuseHandshakes: Int = 0,
    /** Bind this port instead of an ephemeral one — for standing in behind an adb forward. */
    requestedPort: Int = 0,
) {
    private val server = ServerSocket(requestedPort)
    val port: Int get() = server.localPort

    private val lock = Object()
    private val commandLog = mutableListOf<Pair<Int, Int>>()
    private val bodies = mutableMapOf<Pair<Int, Int>, MutableList<ByteArray>>()
    private val strings = mutableMapOf<Long, String>()
    private var handshakesRefused = 0
    private var handshakesCompleted = 0

    /** Every command the client sent, as `set to command`, in arrival order. */
    val commands: List<Pair<Int, Int>> get() = synchronized(lock) { commandLog.toList() }

    /** Bodies of every `set`/`command` packet received, in arrival order. */
    fun bodiesOf(set: Int, command: Int): List<ByteArray> =
        synchronized(lock) { bodies[set to command]?.toList() ?: emptyList() }

    /** Content of every String the client created, in creation order. */
    val createdStrings: List<String> get() = synchronized(lock) { strings.values.toList() }

    val completedHandshakes: Int get() = synchronized(lock) { handshakesCompleted }

    /** Index of the first occurrence of `set`/`command`, or -1. */
    fun indexOf(set: Int, command: Int): Int = commands.indexOfFirst { it == set to command }

    fun start(): FakeJdwpVm {
        thread(isDaemon = true) {
            while (!server.isClosed) {
                val client = runCatching { server.accept() }.getOrNull() ?: return@thread
                thread(isDaemon = true) { runCatching { serve(client) } }
            }
        }
        return this
    }

    fun close() {
        runCatching { server.close() }
    }

    private fun serve(socket: Socket) {
        socket.use { connection ->
            val input = DataInputStream(connection.getInputStream())
            val output = DataOutputStream(connection.getOutputStream())
            val echo = ByteArray(HANDSHAKE.size)
            input.readFully(echo)
            synchronized(lock) {
                if (handshakesRefused < refuseHandshakes) {
                    handshakesRefused++
                    return  // close without echoing: an attach the VM refused
                }
                handshakesCompleted++
            }
            output.write(HANDSHAKE)
            output.flush()

            while (true) {
                val length = input.readInt()
                val id = input.readInt()
                input.readByte()  // flags
                val set = input.readByte().toInt() and 0xFF
                val command = input.readByte().toInt() and 0xFF
                val body = ByteArray(length - 11).also { input.readFully(it) }
                synchronized(lock) {
                    commandLog.add(set to command)
                    bodies.getOrPut(set to command) { mutableListOf() }.add(body)
                }
                val reply = reply(set, command, body) ?: ByteArray(0)
                synchronized(output) {
                    output.writeInt(11 + reply.size)
                    output.writeInt(id)
                    output.writeByte(0x80)
                    output.writeShort(0)
                    output.write(reply)
                    output.flush()
                }
                if (set == EVENT_REQUEST_SET && command == EVENT_REQUEST_SET_CMD && deliverEvent) {
                    val requestId = 7
                    thread(isDaemon = true) {
                        Thread.sleep(eventDelayMillis)
                        runCatching { writeBreakpointEvent(output, requestId) }
                    }
                }
            }
        }
    }

    /** The composite BREAKPOINT event: what suspends the thread invokes then run on. */
    private fun writeBreakpointEvent(output: DataOutputStream, requestId: Int) {
        val body = ByteArrayOutputStream()
        DataOutputStream(body).apply {
            writeByte(1)                 // suspendPolicy: EVENT_THREAD
            writeInt(1)                  // one event
            writeByte(2)                 // BREAKPOINT
            writeInt(requestId)
            writeLong(THREAD_ID)
            writeByte(1)                 // location tag: CLASS
            writeLong(HANDLER_TYPE)
            writeLong(DISPATCH_MESSAGE)
            writeLong(0)                 // code index
        }
        val bytes = body.toByteArray()
        synchronized(output) {
            output.writeInt(11 + bytes.size)
            output.writeInt(-1)          // event packets carry their own id space
            output.writeByte(0)          // flags: command
            output.writeByte(64)         // Event command set
            output.writeByte(100)        // Composite
            output.write(bytes)
            output.flush()
        }
    }

    private fun reply(set: Int, command: Int, body: ByteArray): ByteArray? = when (set to command) {
        1 to 7 -> bytes { repeat(5) { writeInt(8) } }               // VM.IDSizes
        1 to 2 -> classesBySignature(readString(body))              // VM.ClassesBySignature
        1 to 11 -> createString(readString(body))                   // VM.CreateString
        2 to 1 -> bytes { writeJdwpString(signatureOf(readLong(body, 0))) }  // RefType.Signature
        2 to 5 -> methodsOf(readLong(body, 0))                      // RefType.Methods
        3 to 4 -> newInstance()                                     // ClassType.NewInstance
        3 to 3 -> staticInvoke(body)                                // ClassType.InvokeMethod
        9 to 1 -> bytes { writeByte(1); writeLong(IO_EXCEPTION_TYPE) }       // ObjRef.ReferenceType
        9 to 6 -> instanceInvoke(body)                              // ObjRef.InvokeMethod
        9 to 7 -> ByteArray(0)                                      // ObjRef.DisableCollection
        10 to 1 -> bytes { writeJdwpString(strings[readLong(body, 0)] ?: "") } // StringRef.Value
        17 to 1 -> bytes { writeByte(1); writeLong(reflectedType(readLong(body, 0))) }
        11 to 3 -> ByteArray(0)                                     // ThreadRef.Resume
        15 to 1 -> bytes { writeInt(7) }                            // EventRequest.Set
        15 to 2 -> ByteArray(0)                                     // EventRequest.Clear
        else -> ByteArray(0)
    }

    private fun classesBySignature(signature: String): ByteArray {
        val typeId = refTypes.entries.firstOrNull { it.value == signature }?.key
            ?: return bytes { writeInt(0) }
        return bytes {
            writeInt(1)
            writeByte(1)          // refTypeTag: CLASS
            writeLong(typeId)
            writeInt(7)           // status
        }
    }

    private fun methodsOf(refTypeId: Long): ByteArray {
        val declared = methods.filterValues { it.first == refTypeId }
        return bytes {
            writeInt(declared.size)
            declared.forEach { (methodId, method) ->
                writeLong(methodId)
                writeJdwpString(method.second)
                writeJdwpString(method.third)
                writeInt(9)       // modBits
            }
        }
    }

    private fun createString(content: String): ByteArray {
        val id = synchronized(lock) {
            val id = NEXT_STRING + strings.size
            strings[id] = content
            id
        }
        return bytes { writeLong(id) }
    }

    private fun newInstance(): ByteArray = bytes {
        writeByte(TAG_OBJECT)
        writeLong(if (constructorException == 0L) LOADER_OBJECT else 0L)
        writeByte(TAG_OBJECT)
        writeLong(constructorException)
    }

    /** `Class.forName`, `ClassLoader.getSystemClassLoader`, and `Bootstrap.start`. */
    private fun staticInvoke(body: ByteArray): ByteArray {
        val classId = readLong(body, 0)
        return when (classId) {
            CLASS_TYPE -> {                       // Class.forName(String)
                val argStringId = readLong(body, 8 + 8 + 8 + 4 + 1)
                val named = strings[argStringId]
                val refType = refTypes.entries.firstOrNull { binaryName(it.value) == named }?.key ?: 0L
                bytes {
                    writeByte(TAG_CLASS_OBJECT)
                    writeLong(classObjectFor(refType))
                    writeByte(TAG_OBJECT)
                    writeLong(0)
                }
            }
            CLASS_LOADER_TYPE -> bytes {          // getSystemClassLoader()
                writeByte(TAG_CLASS_LOADER)
                writeLong(SYSTEM_LOADER)
                writeByte(TAG_OBJECT)
                writeLong(0)
            }
            else -> bytes {                       // Bootstrap.start()
                writeByte(startTag)
                if (startTag == TAG_INT) writeInt(startValue) else writeLong(startValue.toLong())
                writeByte(TAG_OBJECT)
                writeLong(0)
            }
        }
    }

    /** `ClassLoader.loadClass(String)` on the built loader, and `Throwable.getMessage()`. */
    private fun instanceInvoke(body: ByteArray): ByteArray {
        val objectId = readLong(body, 0)
        if (objectId != LOADER_OBJECT) {          // getMessage() on the thrown exception
            val id = synchronized(lock) {
                val id = NEXT_STRING + strings.size
                strings[id] = EXCEPTION_MESSAGE
                id
            }
            return bytes {
                writeByte(TAG_STRING)
                writeLong(id)
                writeByte(TAG_OBJECT)
                writeLong(0)
            }
        }
        val argStringId = readLong(body, 8 + 8 + 8 + 8 + 4 + 1)
        val named = strings[argStringId]
        val refType = refTypes.entries.firstOrNull { binaryName(it.value) == named }?.key ?: 0L
        val value = loadedClassObject ?: classObjectFor(refType)
        return bytes {
            writeByte(TAG_CLASS_OBJECT)
            writeLong(value)
            writeByte(TAG_OBJECT)
            writeLong(0)
        }
    }

    private fun classObjectFor(refTypeId: Long) = if (refTypeId == 0L) 0L else refTypeId + CLASS_OBJECT_OFFSET
    private fun reflectedType(classObjectId: Long) = classObjectId - CLASS_OBJECT_OFFSET
    private fun signatureOf(refTypeId: Long) = refTypes[refTypeId] ?: "Lunknown;"
    private fun binaryName(signature: String) =
        signature.removePrefix("L").removeSuffix(";").replace('/', '.')

    private fun bytes(write: DataOutputStream.() -> Unit): ByteArray {
        val buffer = ByteArrayOutputStream()
        DataOutputStream(buffer).write()
        return buffer.toByteArray()
    }

    private fun DataOutputStream.writeJdwpString(value: String) {
        val encoded = value.toByteArray(Charsets.UTF_8)
        writeInt(encoded.size)
        write(encoded)
    }

    private fun readString(body: ByteArray): String {
        val stream = DataInputStream(body.inputStream())
        val length = stream.readInt()
        return String(ByteArray(length).also { stream.readFully(it) }, Charsets.UTF_8)
    }

    private fun readLong(body: ByteArray, offset: Int): Long {
        var value = 0L
        for (index in offset until offset + 8) {
            value = (value shl 8) or (body[index].toLong() and 0xFF)
        }
        return value
    }

    companion object {
        val HANDSHAKE: ByteArray = "JDWP-Handshake".toByteArray(Charsets.US_ASCII)

        const val THREAD_ID = 900L
        const val SYSTEM_LOADER = 500L
        const val LOADER_OBJECT = 600L
        const val EXCEPTION_OBJECT = 700L
        const val EXCEPTION_MESSAGE = "Optimized data directory is unusable"
        private const val NEXT_STRING = 800L
        private const val CLASS_OBJECT_OFFSET = 10_000L

        const val CLASS_TYPE = 100L
        const val HANDLER_TYPE = 101L
        const val CLASS_LOADER_TYPE = 102L
        const val THROWABLE_TYPE = 103L
        const val IO_EXCEPTION_TYPE = 104L
        const val PATH_LOADER_TYPE = 105L
        const val BOOTSTRAP_TYPE = 106L

        const val DISPATCH_MESSAGE = 1001L
        const val PATH_LOADER_CTOR = 1005L
        const val BOOTSTRAP_START = 1006L

        const val TAG_OBJECT = 76
        const val TAG_INT = 73
        const val TAG_STRING = 115
        const val TAG_CLASS_OBJECT = 99
        const val TAG_CLASS_LOADER = 108
        const val TAG_VOID = 86

        const val EVENT_REQUEST_SET = 15
        const val EVENT_REQUEST_SET_CMD = 1

        val refTypes = mapOf(
            CLASS_TYPE to "Ljava/lang/Class;",
            HANDLER_TYPE to "Landroid/os/Handler;",
            CLASS_LOADER_TYPE to "Ljava/lang/ClassLoader;",
            THROWABLE_TYPE to "Ljava/lang/Throwable;",
            IO_EXCEPTION_TYPE to "Ljava/io/IOException;",
            PATH_LOADER_TYPE to "Ldalvik/system/PathClassLoader;",
            BOOTSTRAP_TYPE to "Ldev/reticle/agent/Bootstrap;",
        )

        /** methodId → (declaring refType, name, signature). */
        val methods = mapOf(
            1000L to Triple(CLASS_TYPE, "forName", "(Ljava/lang/String;)Ljava/lang/Class;"),
            DISPATCH_MESSAGE to Triple(HANDLER_TYPE, "dispatchMessage", "(Landroid/os/Message;)V"),
            1002L to Triple(CLASS_LOADER_TYPE, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;"),
            1003L to Triple(CLASS_LOADER_TYPE, "getSystemClassLoader", "()Ljava/lang/ClassLoader;"),
            1004L to Triple(THROWABLE_TYPE, "getMessage", "()Ljava/lang/String;"),
            PATH_LOADER_CTOR to Triple(
                PATH_LOADER_TYPE, "<init>", "(Ljava/lang/String;Ljava/lang/ClassLoader;)V"
            ),
            BOOTSTRAP_START to Triple(BOOTSTRAP_TYPE, "start", "()I"),
        )
    }
}

package dev.reticle.cli

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.Closeable
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.Socket

/**
 * Minimal JDWP client — just enough to inject and start the Reticle runtime in a
 * debuggable app that does not link the agent AAR.
 *
 * Dependency-free on purpose (raw `java.net` sockets + DataInput/OutputStream),
 * matching the hand-rolled style of [Adb] and the in-app `ReticleServer`. JDWP is
 * big-endian, which is exactly what DataInput/OutputStream produce, so no manual
 * byte juggling is needed beyond the variable-width IDs the VM negotiates.
 *
 * The hard requirement JDWP places on us: `InvokeMethod` only works on a thread
 * that is suspended **at an event** (a real Java frame). A thread parked in native
 * code (the idle main looper) yields OPAQUE_FRAME. So we arm a `METHOD_ENTRY`
 * event, let it fire on a thread, and run all method invocations on that thread.
 *
 * The injection itself (see [inject]) is the textbook sequence:
 *   new DexClassLoader(dexPath, null, null, null)   // null parent => boot loader
 *     .loadClass("dev.reticle.agent.Bootstrap")
 *   Bootstrap.start()  // @JvmStatic, returns the bound loopback port
 */
class JdwpClient(private val socket: Socket) : Closeable {

    private val input = DataInputStream(BufferedInputStream(socket.getInputStream()))
    private val output = DataOutputStream(BufferedOutputStream(socket.getOutputStream()))
    private var nextId = 1

    // Negotiated via VirtualMachine.IDSizes; default to 8 until then.
    private var fieldIdSize = 8
    private var methodIdSize = 8
    private var objectIdSize = 8
    private var refTypeIdSize = 8
    private var frameIdSize = 8

    // Composite event packets arrive asynchronously, interleaved with our
    // command replies. Any event packet seen while waiting for a reply is parked
    // here for [waitForEventThread] to consume.
    private val pendingEvents = ArrayDeque<Packet>()

    // --- public injection API ------------------------------------------------

    fun handshake() {
        output.write(HANDSHAKE)
        output.flush()
        val echo = ByteArray(HANDSHAKE.size)
        input.readFully(echo)
        require(echo.contentEquals(HANDSHAKE)) { "JDWP handshake failed (got ${String(echo)})" }
    }

    fun negotiateIdSizes() {
        val reply = command(CMD_SET_VM, CMD_VM_IDSIZES)
        val d = DataInputStream(reply.data.inputStream())
        fieldIdSize = d.readInt()
        methodIdSize = d.readInt()
        objectIdSize = d.readInt()
        refTypeIdSize = d.readInt()
        frameIdSize = d.readInt()
    }

    /**
     * Load [dexDevicePath] inside the target process and call
     * `dev.reticle.agent.Bootstrap.start()`. Returns its result — the bound
     * loopback port, or a negative `Bootstrap.ERR_*` code.
     *
     * [trigger] is invoked after the METHOD_ENTRY event is armed; it must cause
     * the app's looper to run Java (e.g. send a benign input event) so the event
     * fires. It may be called more than once.
     */
    fun inject(dexDevicePath: String, trigger: () -> Unit): Int {
        // java.lang.Class is always loaded; resolve it + Class.forName up front so
        // we can force-load any core class that isn't loaded yet (ClassesBySignature
        // only returns ALREADY-loaded types — on a fresh process DexClassLoader may
        // not be loaded, which is why we can't assume it).
        val classClass = classBySignature("Ljava/lang/Class;")
            ?: error("java.lang.Class not found in target VM (impossible?)")
        val forNameMethod = findMethod(classClass, "forName", "(Ljava/lang/String;)Ljava/lang/Class;")
            ?: error("Class.forName(String) not found")

        // NOTE: the argument Strings are created AFTER the breakpoint fires (below),
        // not here. A JDWP CreateString result isn't held by any GC root, so on a
        // busy app (heavy GC) it can be collected during the multi-second wait for
        // the event — which surfaced as JDWP error 20 (INVALID_OBJECT) on the next
        // invoke. Creating them while the thread is already suspended closes that
        // window.

        // Set a BREAKPOINT at the entry (code index 0) of
        // android.os.Handler.dispatchMessage. A breakpoint instruments ONE method,
        // not the whole VM — unlike METHOD_ENTRY, which forces a full-app
        // deoptimization that ANR-kills a heavy app. Handler.dispatchMessage is the
        // single chokepoint EVERY main-looper message runs through (pure Java, main
        // thread, a live Java frame — the only state ART allows InvokeMethod from),
        // so ANY looper activity fires it. That's far more reliable than
        // Activity.dispatchTouchEvent, which needs a tap to land on a standard
        // Activity (a custom/overlay foreground or a swallowed touch breaks it). The
        // trigger still nudges input to guarantee the looper has work to dispatch.
        val handlerClass = classBySignature(HANDLER_SIGNATURE)
            ?: error("android.os.Handler not found in target VM")
        val dispatchMessage = findMethod(handlerClass, "dispatchMessage", "(Landroid/os/Message;)V")
            ?: error("Handler.dispatchMessage(Message) not found")
        val requestId = setBreakpoint(handlerClass, dispatchMessage, index = 0L)
        val threadId = try {
            waitForEventThread(requestId, EVENT_BREAKPOINT, trigger)
        } finally {
            clearEvent(EVENT_BREAKPOINT, requestId)
        }

        try {
            // Resolve types now that we have a thread to load on (Class.forName
            // works even for not-yet-loaded core classes). We use PathClassLoader,
            // not DexClassLoader: DexClassLoader's legacy
            // (dexPath, optimizedDirectory, libPath, parent) ctor NPEs on a null
            // optimizedDirectory on modern ART, whereas PathClassLoader(dexPath,
            // parent) lets ART manage optimization itself.
            val classLoaderType = classBySignature("Ljava/lang/ClassLoader;")
                ?: error("java.lang.ClassLoader not found in target VM")
            val loadClassMethod = findMethod(classLoaderType, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;")
                ?: error("ClassLoader.loadClass(String) not found")
            // Parent = the system classloader (the app's PathClassLoader), so the
            // injected agent resolves both Android framework AND app classes; our
            // dex only adds dev.reticle.agent.* + bundled kotlin on top.
            val getSystemLoader = findMethod(classLoaderType, "getSystemClassLoader", "()Ljava/lang/ClassLoader;")
                ?: error("ClassLoader.getSystemClassLoader() not found")
            val parentLoaderId = invokeStatic(threadId, classLoaderType, getSystemLoader, emptyList()).value

            // Create argument Strings now (thread already suspended) so they can't be
            // GC'd before use — see the note above about JDWP error 20.
            val pathLoaderNameStr = createString("dalvik.system.PathClassLoader")
            val dexPathStr = createString(dexDevicePath)
            val bootstrapNameStr = createString(BOOTSTRAP_CLASS)

            val pathLoaderType = forNameType(threadId, classClass, forNameMethod, pathLoaderNameStr)
            val pathLoaderCtor = findMethod(pathLoaderType, "<init>", PATH_CLASSLOADER_CTOR_SIG)
                ?: error("PathClassLoader(String,ClassLoader) constructor not found")

            // --- suspended-thread critical section (kept minimal) ---
            val (loaderId, ctorExc) = newInstance(
                threadId, pathLoaderType, pathLoaderCtor,
                listOf(objectArg(dexPathStr), objectArg(parentLoaderId)),
            )
            if (ctorExc != 0L) {
                error("PathClassLoader constructor threw in target: ${describeException(threadId, ctorExc)}")
            }
            if (loaderId == 0L) error("PathClassLoader constructor returned null")

            // loadClass on the loader instance -> the Class object (forces our dex
            // to define dev.reticle.agent.Bootstrap).
            val loaded = invokeInstance(
                threadId, loaderId, classLoaderType, loadClassMethod, listOf(objectArg(bootstrapNameStr)),
            )
            if (loaded.exceptionId != 0L) {
                error("loadClass(\"$BOOTSTRAP_CLASS\") threw in target: ${describeException(threadId, loaded.exceptionId)}")
            }
            if (loaded.value == 0L) error("loadClass(\"$BOOTSTRAP_CLASS\") returned null")

            // Call the static Bootstrap.start() via the loaded class's reference type.
            val bootstrapTypeId = reflectedType(loaded.value)
            val startMethod = findMethod(bootstrapTypeId, "start", "()I")
                ?: error("Bootstrap.start()I not found on injected class")
            val result = invokeStatic(threadId, bootstrapTypeId, startMethod, emptyList())
            if (result.tag != TAG_INT) error("Bootstrap.start() returned non-int (tag=${result.tag})")
            return result.value.toInt()
        } finally {
            // Whether or not the invokes succeeded, let the app run again.
            resumeThread(threadId)
        }
    }

    /** Force-load a class by binary name via Class.forName and return its reference type. */
    private fun forNameType(threadId: Long, classClass: Long, forName: Long, nameStringId: Long): Long {
        val res = invokeStatic(threadId, classClass, forName, listOf(objectArg(nameStringId)))
        if (res.exceptionId != 0L) error("Class.forName threw resolving a core class (objectId=${res.exceptionId})")
        if (res.value == 0L) error("Class.forName returned null")
        return reflectedType(res.value)
    }

    /** The reference-type id backing a `java.lang.Class` object (ClassObjectReference.ReflectedType). */
    private fun reflectedType(classObjectId: Long): Long {
        val buf = java.io.ByteArrayOutputStream()
        DataOutputStream(buf).writeId(classObjectId, objectIdSize)
        val reply = command(CMD_SET_CLASSOBJREF, CMD_CLASSOBJREF_REFLECTEDTYPE, buf.toByteArray())
        val d = DataInputStream(reply.data.inputStream())
        d.readByte() // refTypeTag
        return d.readId(refTypeIdSize)
    }

    /**
     * Best-effort human description of a thrown exception object: its class
     * signature plus getMessage(). Turns an opaque "objectId=13" into something
     * like "java.io.IOException: Optimized data directory ... unusable". Runs on
     * the still-suspended [threadId] (invokes are allowed there). Never throws —
     * diagnostics must not mask the original failure.
     */
    private fun describeException(threadId: Long, exceptionId: Long): String = try {
        val typeId = referenceType(exceptionId)
        val sig = signature(typeId)
        val readable = sig.removePrefix("L").removeSuffix(";").replace('/', '.')
        val msg = runCatching {
            val throwableType = classBySignature("Ljava/lang/Throwable;") ?: typeId
            val getMessage = findMethod(throwableType, "getMessage", "()Ljava/lang/String;")
            if (getMessage != null) {
                val r = invokeInstance(threadId, exceptionId, throwableType, getMessage, emptyList())
                if (r.value != 0L) ": " + readStringValue(r.value) else ""
            } else ""
        }.getOrDefault("")
        "$readable$msg"
    } catch (t: Throwable) {
        "objectId=$exceptionId (could not introspect: ${t.message})"
    }

    /** ObjectReference.ReferenceType — the runtime type of an object id. */
    private fun referenceType(objectId: Long): Long {
        val buf = java.io.ByteArrayOutputStream()
        DataOutputStream(buf).writeId(objectId, objectIdSize)
        val reply = command(CMD_SET_OBJREF, CMD_OBJREF_REFERENCETYPE, buf.toByteArray())
        val d = DataInputStream(reply.data.inputStream())
        d.readByte() // refTypeTag
        return d.readId(refTypeIdSize)
    }

    /** ReferenceType.Signature — the JNI type signature of a reference type. */
    private fun signature(refTypeId: Long): String {
        val buf = java.io.ByteArrayOutputStream()
        DataOutputStream(buf).writeId(refTypeId, refTypeIdSize)
        val reply = command(CMD_SET_REFTYPE, CMD_REFTYPE_SIGNATURE, buf.toByteArray())
        return DataInputStream(reply.data.inputStream()).readJdwpString()
    }

    /** StringReference.Value — the chars of a String object id. */
    private fun readStringValue(stringId: Long): String {
        val buf = java.io.ByteArrayOutputStream()
        DataOutputStream(buf).writeId(stringId, objectIdSize)
        val reply = command(CMD_SET_STRINGREF, CMD_STRINGREF_VALUE, buf.toByteArray())
        return DataInputStream(reply.data.inputStream()).readJdwpString()
    }

    override fun close() {
        try { socket.close() } catch (_: Throwable) {}
    }

    // --- JDWP command wrappers ----------------------------------------------

    private fun createString(s: String): Long {
        val payload = encodeString(s)
        val reply = command(CMD_SET_VM, CMD_VM_CREATESTRING, payload)
        val id = DataInputStream(reply.data.inputStream()).readId(objectIdSize)
        // Pin it: a CreateString result is held by no GC root, so on a busy app it
        // can be collected before we pass it to an invoke (seen as JDWP error 20,
        // INVALID_OBJECT). DisableCollection keeps it alive until the VM detaches.
        disableCollection(id)
        return id
    }

    /** ObjectReference.DisableCollection — pin [objectId] against GC for this session. */
    private fun disableCollection(objectId: Long) {
        val buf = java.io.ByteArrayOutputStream()
        DataOutputStream(buf).writeId(objectId, objectIdSize)
        runCatching { command(CMD_SET_OBJREF, CMD_OBJREF_DISABLECOLLECTION, buf.toByteArray()) }
    }

    /** First loaded reference type matching [signature], or null. */
    private fun classBySignature(signature: String): Long? {
        val reply = command(CMD_SET_VM, CMD_VM_CLASSESBYSIGNATURE, encodeString(signature))
        val d = DataInputStream(reply.data.inputStream())
        val count = d.readInt()
        if (count == 0) return null
        d.readByte()                 // refTypeTag
        val typeId = d.readId(refTypeIdSize)
        return typeId
    }

    private fun findMethod(refTypeId: Long, name: String, signature: String): Long? {
        val buf = java.io.ByteArrayOutputStream()
        DataOutputStream(buf).writeId(refTypeId, refTypeIdSize)
        val reply = command(CMD_SET_REFTYPE, CMD_REFTYPE_METHODS, buf.toByteArray())
        val d = DataInputStream(reply.data.inputStream())
        val declared = d.readInt()
        repeat(declared) {
            val methodId = d.readId(methodIdSize)
            val mName = d.readJdwpString()
            val mSig = d.readJdwpString()
            d.readInt() // modBits
            if (mName == name && mSig == signature) return methodId
        }
        return null
    }

    private fun newInstance(
        threadId: Long,
        classId: Long,
        methodId: Long,
        args: List<ByteArray>,
    ): Pair<Long, Long> {
        val buf = java.io.ByteArrayOutputStream()
        val o = DataOutputStream(buf)
        o.writeId(classId, refTypeIdSize)
        o.writeId(threadId, objectIdSize)
        o.writeId(methodId, methodIdSize)
        o.writeInt(args.size)
        args.forEach { o.write(it) }
        o.writeInt(INVOKE_RESUME_ALL)
        val reply = command(CMD_SET_CLASSTYPE, CMD_CLASSTYPE_NEWINSTANCE, buf.toByteArray())
        val d = DataInputStream(reply.data.inputStream())
        val (_, obj) = d.readTaggedObjectId()
        val (_, exc) = d.readTaggedObjectId()
        return obj to exc
    }

    private fun invokeStatic(
        threadId: Long,
        classId: Long,
        methodId: Long,
        args: List<ByteArray>,
    ): InvokeResult {
        val buf = java.io.ByteArrayOutputStream()
        val o = DataOutputStream(buf)
        o.writeId(classId, refTypeIdSize)
        o.writeId(threadId, objectIdSize)
        o.writeId(methodId, methodIdSize)
        o.writeInt(args.size)
        args.forEach { o.write(it) }
        o.writeInt(INVOKE_RESUME_ALL)
        val reply = command(CMD_SET_CLASSTYPE, CMD_CLASSTYPE_INVOKEMETHOD, buf.toByteArray())
        return parseInvokeReply(reply)
    }

    private fun invokeInstance(
        threadId: Long,
        objectId: Long,
        classId: Long,
        methodId: Long,
        args: List<ByteArray>,
    ): InvokeResult {
        val buf = java.io.ByteArrayOutputStream()
        val o = DataOutputStream(buf)
        o.writeId(objectId, objectIdSize)
        o.writeId(threadId, objectIdSize)
        o.writeId(classId, refTypeIdSize)
        o.writeId(methodId, methodIdSize)
        o.writeInt(args.size)
        args.forEach { o.write(it) }
        o.writeInt(INVOKE_RESUME_ALL)
        val reply = command(CMD_SET_OBJREF, CMD_OBJREF_INVOKEMETHOD, buf.toByteArray())
        return parseInvokeReply(reply)
    }

    private fun parseInvokeReply(reply: Packet): InvokeResult {
        val d = DataInputStream(reply.data.inputStream())
        val tag = d.readByte().toInt() and 0xFF
        val value = readValueByTag(d, tag)
        val (_, excId) = d.readTaggedObjectId()
        return InvokeResult(tag, value, excId)
    }

    // --- events --------------------------------------------------------------

    /**
     * Arm a BREAKPOINT at [classId].[methodId] code [index] with EVENT_THREAD
     * suspend and Count(1). A breakpoint instruments a single method (ART only
     * deoptimizes that one), so — unlike METHOD_ENTRY — it doesn't deopt the whole
     * app and ANR-kill it. Count(1) means ART removes the breakpoint after it fires
     * once, so the app runs full-speed again immediately after we detach.
     */
    private fun setBreakpoint(classId: Long, methodId: Long, index: Long): Int {
        val buf = java.io.ByteArrayOutputStream()
        val o = DataOutputStream(buf)
        o.writeByte(EVENT_BREAKPOINT)
        o.writeByte(SUSPEND_EVENT_THREAD)
        o.writeInt(2)                        // two modifiers: Count + LocationOnly
        o.writeByte(MOD_COUNT)
        o.writeInt(1)
        o.writeByte(MOD_LOCATION_ONLY)
        // LocationOnly modifier carries a Location: tag(1) + classId + methodId + index(8).
        o.writeByte(TYPE_TAG_CLASS)
        o.writeId(classId, refTypeIdSize)
        o.writeId(methodId, methodIdSize)
        o.writeLong(index)
        val reply = command(CMD_SET_EVENTREQUEST, CMD_EVENTREQUEST_SET, buf.toByteArray())
        val id = DataInputStream(reply.data.inputStream()).readInt()
        if (DEBUG) System.err.println("jdwp: BREAKPOINT set requestId=$id at code index #$index")
        return id
    }

    private fun clearEvent(eventKind: Int, requestId: Int) {
        val buf = java.io.ByteArrayOutputStream()
        val o = DataOutputStream(buf)
        o.writeByte(eventKind)
        o.writeInt(requestId)
        runCatching { command(CMD_SET_EVENTREQUEST, CMD_EVENTREQUEST_CLEAR, buf.toByteArray()) }
    }

    /**
     * Poll for the composite event [requestId]/[eventKind] triggers, calling
     * [trigger] to drive the app through the instrumented location. Returns the
     * threadID suspended at the event.
     */
    private fun waitForEventThread(requestId: Int, eventKind: Int, trigger: () -> Unit): Long {
        val deadline = System.nanoTime() + EVENT_TIMEOUT_NANOS
        var triggered = 0
        while (System.nanoTime() < deadline) {
            // Nudge the app a few times up front, then keep nudging as we poll.
            if (triggered < MAX_TRIGGERS) {
                trigger()
                triggered++
            }
            val packet = nextEventPacketOrNull(POLL_SLICE_MILLIS) ?: continue
            if (DEBUG) System.err.println(
                "jdwp: event packet set=${packet.commandSet} cmd=${packet.command} len=${packet.data.size}"
            )
            val thread = parseEventThread(packet, requestId, eventKind)
            if (thread != null) return thread
        }
        error(
            "timed out waiting for a JDWP event (no thread to inject on). The app's " +
                "foreground Activity never ran the instrumented method — is it foregrounded?"
        )
    }

    private fun parseEventThread(packet: Packet, requestId: Int, eventKind: Int): Long? {
        val d = DataInputStream(packet.data.inputStream())
        d.readByte()                         // suspendPolicy
        val events = d.readInt()
        repeat(events) {
            val kind = d.readByte().toInt() and 0xFF
            // BREAKPOINT and METHOD_ENTRY share the same body shape:
            // requestId(4) + threadId + location(tag+classId+methodId+index).
            if (kind == eventKind) {
                val reqId = d.readInt()
                val threadId = d.readId(objectIdSize)
                d.readByte()                 // location tag
                d.readId(refTypeIdSize)
                d.readId(methodIdSize)
                d.readLong()                 // code index
                if (reqId == requestId) return threadId
            } else {
                // An event shape we didn't arm: can't skip its body safely, so bail
                // to the outer poll loop for the next packet.
                return null
            }
        }
        return null
    }

    private fun resumeThread(threadId: Long) {
        val buf = java.io.ByteArrayOutputStream()
        DataOutputStream(buf).writeId(threadId, objectIdSize)
        runCatching { command(CMD_SET_THREADREF, CMD_THREADREF_RESUME, buf.toByteArray()) }
    }

    // --- packet plumbing -----------------------------------------------------

    private class Packet(
        val id: Int,
        val flags: Int,
        val errorCode: Int,
        val commandSet: Int,
        val command: Int,
        val data: ByteArray,
    ) {
        val isReply: Boolean get() = (flags and 0x80) != 0
    }

    private fun command(set: Int, cmd: Int, data: ByteArray = ByteArray(0)): Packet {
        val id = nextId++
        synchronized(output) {
            output.writeInt(11 + data.size)
            output.writeInt(id)
            output.writeByte(0)              // flags: command
            output.writeByte(set)
            output.writeByte(cmd)
            output.write(data)
            output.flush()
        }
        // Read packets until the matching reply; park any events.
        while (true) {
            val packet = readPacket()
            if (packet.isReply && packet.id == id) {
                if (packet.errorCode != 0) {
                    error("JDWP command $set/$cmd failed: error ${packet.errorCode} (${jdwpError(packet.errorCode)})")
                }
                return packet
            }
            if (!packet.isReply) pendingEvents.addLast(packet)
            // A stray mismatched reply (shouldn't happen with synchronous use) is dropped.
        }
    }

    private fun nextEventPacketOrNull(timeoutMillis: Int): Packet? {
        pendingEvents.removeFirstOrNull()?.let { return it }
        socket.soTimeout = timeoutMillis
        return try {
            val packet = readPacket()
            if (packet.isReply) null else packet
        } catch (_: java.net.SocketTimeoutException) {
            null
        } finally {
            socket.soTimeout = 0
        }
    }

    private fun readPacket(): Packet {
        val length = input.readInt()
        val id = input.readInt()
        val flags = input.readByte().toInt() and 0xFF
        val body = ByteArray(length - 11)
        if ((flags and 0x80) != 0) {
            val errorCode = input.readUnsignedShort()
            input.readFully(body)
            return Packet(id, flags, errorCode, 0, 0, body)
        } else {
            val set = input.readByte().toInt() and 0xFF
            val cmd = input.readByte().toInt() and 0xFF
            input.readFully(body)
            return Packet(id, flags, 0, set, cmd, body)
        }
    }

    // --- value/id encoding ---------------------------------------------------

    private data class InvokeResult(val tag: Int, val value: Long, val exceptionId: Long)

    /** A tagged OBJECT value for an InvokeMethod/NewInstance argument list. */
    private fun objectArg(objectId: Long): ByteArray {
        val buf = java.io.ByteArrayOutputStream()
        val o = DataOutputStream(buf)
        o.writeByte(TAG_OBJECT)
        o.writeId(objectId, objectIdSize)
        return buf.toByteArray()
    }

    private fun encodeString(s: String): ByteArray {
        val bytes = s.toByteArray(Charsets.UTF_8)
        val buf = java.io.ByteArrayOutputStream()
        val o = DataOutputStream(buf)
        o.writeInt(bytes.size)
        o.write(bytes)
        return buf.toByteArray()
    }

    private fun DataInputStream.readJdwpString(): String {
        val len = readInt()
        val bytes = ByteArray(len)
        readFully(bytes)
        return String(bytes, Charsets.UTF_8)
    }

    private fun DataInputStream.readId(size: Int): Long = when (size) {
        8 -> readLong()
        4 -> readInt().toLong() and 0xFFFFFFFFL
        2 -> readUnsignedShort().toLong()
        else -> error("unsupported JDWP id size $size")
    }

    private fun DataOutputStream.writeId(value: Long, size: Int) = when (size) {
        8 -> writeLong(value)
        4 -> writeInt(value.toInt())
        2 -> writeShort(value.toInt())
        else -> error("unsupported JDWP id size $size")
    }

    private fun DataInputStream.readTaggedObjectId(): Pair<Int, Long> {
        val tag = readByte().toInt() and 0xFF
        return tag to readId(objectIdSize)
    }

    /** Read a JDWP value body given its tag; only the tags we may receive. */
    private fun readValueByTag(d: DataInputStream, tag: Int): Long = when (tag) {
        TAG_INT -> d.readInt().toLong()
        TAG_VOID -> 0L
        TAG_BOOLEAN, TAG_BYTE -> (d.readByte().toInt() and 0xFF).toLong()
        TAG_SHORT -> d.readShort().toLong()
        TAG_LONG -> d.readLong()
        TAG_OBJECT, TAG_STRING, TAG_ARRAY, TAG_THREAD, TAG_CLASS_OBJECT, TAG_CLASS_LOADER ->
            d.readId(objectIdSize)
        TAG_FLOAT -> d.readInt().toLong()
        TAG_DOUBLE -> d.readLong()
        TAG_CHAR -> d.readUnsignedShort().toLong()
        else -> error("unexpected JDWP value tag $tag")
    }

    companion object {
        private val DEBUG = System.getenv("RETICLE_JDWP_DEBUG") == "1"
        private val HANDSHAKE = "JDWP-Handshake".toByteArray(Charsets.US_ASCII)

        // Command sets / commands (JDWP spec).
        private const val CMD_SET_VM = 1
        private const val CMD_VM_CLASSESBYSIGNATURE = 2
        private const val CMD_VM_IDSIZES = 7
        private const val CMD_VM_CREATESTRING = 11
        private const val CMD_SET_REFTYPE = 2
        private const val CMD_REFTYPE_SIGNATURE = 1
        private const val CMD_REFTYPE_METHODS = 5
        private const val CMD_SET_CLASSTYPE = 3
        private const val CMD_CLASSTYPE_INVOKEMETHOD = 3
        private const val CMD_CLASSTYPE_NEWINSTANCE = 4
        private const val CMD_SET_OBJREF = 9
        private const val CMD_OBJREF_REFERENCETYPE = 1
        private const val CMD_OBJREF_INVOKEMETHOD = 6
        private const val CMD_OBJREF_DISABLECOLLECTION = 7
        private const val CMD_SET_STRINGREF = 10
        private const val CMD_STRINGREF_VALUE = 1
        private const val CMD_SET_CLASSOBJREF = 17
        private const val CMD_CLASSOBJREF_REFLECTEDTYPE = 1
        private const val CMD_SET_THREADREF = 11
        private const val CMD_THREADREF_RESUME = 3
        private const val CMD_SET_EVENTREQUEST = 15
        private const val CMD_EVENTREQUEST_SET = 1
        private const val CMD_EVENTREQUEST_CLEAR = 2

        private const val EVENT_BREAKPOINT = 2
        private const val SUSPEND_EVENT_THREAD = 1
        private const val MOD_COUNT = 1
        private const val MOD_LOCATION_ONLY = 7
        private const val TYPE_TAG_CLASS = 1     // Location typeTag for a normal class
        // invokeOptions = 0: resume ALL threads while the invoke runs. The
        // alternative, INVOKE_SINGLE_THREADED(1), keeps every other thread frozen
        // for the duration — and ART's dex loading / class init can block on a
        // background daemon (dexopt, GC, the finalizer). With those frozen the
        // invoke deadlocks until the watchdog ANR-kills the app. Resuming all
        // threads lets the daemons make progress; only the invoking thread blocks.
        private const val INVOKE_RESUME_ALL = 0

        // JDWP value tags.
        private const val TAG_ARRAY = 91        // '['
        private const val TAG_BYTE = 66         // 'B'
        private const val TAG_CHAR = 67         // 'C'
        private const val TAG_OBJECT = 76       // 'L'
        private const val TAG_FLOAT = 70        // 'F'
        private const val TAG_DOUBLE = 68       // 'D'
        private const val TAG_INT = 73          // 'I'
        private const val TAG_LONG = 74         // 'J'
        private const val TAG_SHORT = 83        // 'S'
        private const val TAG_VOID = 86         // 'V'
        private const val TAG_BOOLEAN = 90      // 'Z'
        private const val TAG_STRING = 115      // 's'
        private const val TAG_THREAD = 116      // 't'
        private const val TAG_CLASS_OBJECT = 99 // 'c'
        private const val TAG_CLASS_LOADER = 108 // 'l'

        private const val BOOTSTRAP_CLASS = "dev.reticle.agent.Bootstrap"
        private const val HANDLER_SIGNATURE = "Landroid/os/Handler;"
        private const val PATH_CLASSLOADER_CTOR_SIG =
            "(Ljava/lang/String;Ljava/lang/ClassLoader;)V"

        private const val EVENT_TIMEOUT_NANOS = 8_000_000_000L  // 8s
        private const val POLL_SLICE_MILLIS = 400
        private const val MAX_TRIGGERS = 8

        private fun jdwpError(code: Int): String = when (code) {
            10 -> "INVALID_THREAD"
            13 -> "THREAD_NOT_SUSPENDED"
            20 -> "INVALID_OBJECT (a passed object id was collected/invalid — GC during the wait?)"
            21 -> "INVALID_OBJECT"
            22 -> "INVALID_CLASS"
            23 -> "CLASS_NOT_PREPARED"
            25 -> "INVALID_METHODID"
            34 -> "INVALID_FRAMEID"
            35 -> "OPAQUE_FRAME (thread not suspended at a Java frame)"
            502 -> "ABSENT_INFORMATION"
            else -> "see JDWP error constants"
        }
    }
}

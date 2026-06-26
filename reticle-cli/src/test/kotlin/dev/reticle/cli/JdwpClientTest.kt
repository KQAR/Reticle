package dev.reticle.cli

import dev.reticle.cli.platform.android.JdwpClient
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.ServerSocket
import java.net.Socket
import kotlin.concurrent.thread
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * Tests the [JdwpClient] wire codec against a fake in-process JDWP server: the
 * handshake exchange and the IDSizes negotiation, which are the two pieces every
 * later command depends on. No device or adb involved — just a [ServerSocket]
 * speaking the JDWP framing the spec defines.
 */
class JdwpClientTest {

    private var server: ServerSocket? = null

    @AfterTest
    fun tearDown() {
        server?.close()
    }

    private val handshake = "JDWP-Handshake".toByteArray(Charsets.US_ASCII)

    /** Start a fake JDWP server; [onConnect] gets the accepted socket's streams. */
    private fun serve(onConnect: (DataInputStream, DataOutputStream) -> Unit): Int {
        val socket = ServerSocket(0)
        server = socket
        thread(isDaemon = true) {
            val client = runCatching { socket.accept() }.getOrNull() ?: return@thread
            client.use { c ->
                val input = DataInputStream(c.getInputStream())
                val output = DataOutputStream(c.getOutputStream())
                runCatching { onConnect(input, output) }
            }
        }
        return socket.localPort
    }

    /** Read the 14-byte handshake from the client and echo it back. */
    private fun DataInputStream.expectHandshake(echo: DataOutputStream) {
        val buf = ByteArray(handshake.size)
        readFully(buf)
        assertTrue(buf.contentEquals(handshake), "client must send the JDWP handshake")
        echo.write(handshake)
        echo.flush()
    }

    /** Read one JDWP command packet header + body. */
    private data class Cmd(val id: Int, val set: Int, val command: Int, val data: ByteArray)

    private fun DataInputStream.readCommand(): Cmd {
        val length = readInt()
        val id = readInt()
        readByte()                // flags (0 = command)
        val set = readByte().toInt() and 0xFF
        val command = readByte().toInt() and 0xFF
        val data = ByteArray(length - 11)
        readFully(data)
        return Cmd(id, set, command, data)
    }

    /** Write a JDWP reply packet (flags 0x80) for [id] with [data] and no error. */
    private fun DataOutputStream.writeReply(id: Int, data: ByteArray) {
        writeInt(11 + data.size)
        writeInt(id)
        writeByte(0x80)           // reply flag
        writeShort(0)             // error code 0
        write(data)
        flush()
    }

    @Test
    fun handshakeSucceedsAgainstEchoingServer() {
        val port = serve { input, output -> input.expectHandshake(output) }
        JdwpClient(Socket("127.0.0.1", port)).use { it.handshake() }
    }

    @Test
    fun handshakeFailsWhenServerClosesEarly() {
        // Server accepts then immediately closes. The client must fail with an
        // IOException — either EOF (clean FIN) or "connection reset" (RST), both of
        // which Injector's handshake-retry treats as a not-ready channel.
        val port = serve { _, _ -> /* return → socket closes */ }
        assertFailsWith<java.io.IOException> {
            JdwpClient(Socket("127.0.0.1", port)).use { it.handshake() }
        }
    }

    @Test
    fun negotiateIdSizesParsesTheReply() {
        // After the handshake the client sends VirtualMachine.IDSizes (set 1, cmd 7);
        // we reply with the five sizes and confirm the client consumed exactly that
        // packet (correct framing) by replying only to that id.
        val port = serve { input, output ->
            input.expectHandshake(output)
            val cmd = input.readCommand()
            assertEquals(1, cmd.set, "expected VirtualMachine command set")
            assertEquals(7, cmd.command, "expected IDSizes command")
            val body = java.io.ByteArrayOutputStream()
            DataOutputStream(body).apply {
                writeInt(8); writeInt(8); writeInt(8); writeInt(8); writeInt(8) // field/method/object/refType/frame
            }
            output.writeReply(cmd.id, body.toByteArray())
        }
        JdwpClient(Socket("127.0.0.1", port)).use { jdwp ->
            jdwp.handshake()
            jdwp.negotiateIdSizes()  // must not throw; reply framing parsed correctly
        }
    }
}

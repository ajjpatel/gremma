package com.gremma.android

import android.util.Log
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.io.RandomAccessFile
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import kotlin.concurrent.thread

private const val TAG = "GremmaReceiver"

/**
 * Receives the board's clips (video_stream/docs/receiver-contract.md), over plain HTTP on the home network.
 * POST multipart `metadata` (JSON) then `video` (MP4) with a Bearer token. Replies {"clip_id", "stored": true}
 * only once the clip is synced to disk, so the board retries anything we did not keep.
 * Each clip lands in the inbox as <clip_id>.mp4 with its metadata beside it as <clip_id>.json.
 */
class ClipReceiver(
    private val inbox: File,
    private val token: () -> String,
    val port: Int = 8080,
    private val onStored: (String) -> Unit = {},
) {
    private class HttpError(val status: Int, message: String) : Exception(message)

    @Volatile private var server: ServerSocket? = null
    @Volatile var stored = 0; private set

    val url: String get() = "http://${lanAddress() ?: "<phone-ip>"}:$port/v1/clips"

    fun start() {
        if (server != null) return
        val s = runCatching { ServerSocket().apply { reuseAddress = true; bind(InetSocketAddress(port)) } }
            .onFailure { Log.e(TAG, "cannot listen on $port", it) }.getOrNull() ?: return
        server = s
        thread(name = "clip-receiver", isDaemon = true) {
            while (!s.isClosed) {
                val c = runCatching { s.accept() }.getOrNull() ?: continue
                thread(name = "clip-upload", isDaemon = true) { c.use { serve(it) } }
            }
        }
        Log.i(TAG, "listening on $url")
    }

    private fun serve(sock: Socket) {
        sock.soTimeout = 60_000
        val input = BufferedInputStream(sock.getInputStream(), 256 * 1024)
        val out = sock.getOutputStream()
        val (status, body) = try {
            handle(input, out) ?: return
        } catch (e: HttpError) {
            Log.w(TAG, "rejected upload from ${sock.inetAddress.hostAddress}: ${e.status} ${e.message}")
            e.status to JSONObject().put("error", e.message).toString()
        } catch (e: Exception) {
            Log.e(TAG, "upload failed", e)
            500 to JSONObject().put("error", e.javaClass.simpleName).toString()
        }
        runCatching { respond(out, status, body) }
    }

    private fun handle(input: InputStream, out: OutputStream): Pair<Int, String>? {
        val request = readLine(input) ?: return null
        val method = request.substringBefore(' ')
        val headers = mutableMapOf<String, String>()
        while (true) {
            val line = readLine(input) ?: break
            if (line.isEmpty()) break
            val i = line.indexOf(':')
            if (i > 0) headers[line.substring(0, i).trim().lowercase()] = line.substring(i + 1).trim()
        }
        if (method == "GET") return 200 to JSONObject().put("app", "gremma").put("receiving", true).put("stored", stored).toString()
        if (method != "POST") throw HttpError(405, "POST clips here")
        if (headers["authorization"] != "Bearer ${token()}") throw HttpError(401, "bad or missing bearer token")
        val length = headers["content-length"]?.toLongOrNull() ?: throw HttpError(411, "Content-Length required")
        if (length > MAX_BYTES) throw HttpError(413, "clip too large")
        val boundary = Regex("boundary=\"?([^\";]+)\"?").find(headers["content-type"].orEmpty())?.groupValues?.get(1)
            ?: throw HttpError(400, "multipart boundary missing")
        if (headers["expect"].equals("100-continue", true)) { out.write("HTTP/1.1 100 Continue\r\n\r\n".toByteArray()); out.flush() }

        val body = Limited(input, length)
        var meta: JSONObject? = null
        val part = File(inbox, ".incoming_${System.nanoTime()}")
        try {
            // Parts before the video are small (metadata); the video runs to the closing boundary.
            while (true) {
                val delim = readLine(body) ?: throw HttpError(400, "no video part")
                if (delim != "--$boundary") throw HttpError(400, "malformed multipart")
                val partHeaders = generateSequence { readLine(body)?.takeIf { it.isNotEmpty() } }.toList()
                val name = partHeaders.firstNotNullOfOrNull { Regex("name=\"([^\"]+)\"").find(it)?.groupValues?.get(1) }
                if (name == "video") break
                val text = StringBuilder()
                while (true) {
                    val l = readLine(body) ?: throw HttpError(400, "truncated part")
                    if (l == "--$boundary" || l == "--$boundary--") { body.unread(l); break }
                    if (text.isNotEmpty()) text.append("\r\n")
                    text.append(l)
                    if (text.length > 65536) throw HttpError(400, "part too large")
                }
                if (name == "metadata") meta = runCatching { JSONObject(text.toString()) }.getOrNull() ?: throw HttpError(400, "metadata is not JSON")
            }
            val m = meta ?: throw HttpError(400, "metadata must come before video")
            val id = m.optString("clip_id")
            if (!Regex("[A-Za-z0-9_-][A-Za-z0-9._-]{0,99}").matches(id)) throw HttpError(400, "bad clip_id")

            FileOutputStream(part).use { f ->
                body.copyTo(f, 256 * 1024)
                f.fd.sync()
            }
            stripClosingBoundary(part, boundary)
            val sha = sha256(part)
            if (m.has("size_bytes") && m.optLong("size_bytes") != part.length()) throw HttpError(400, "size_bytes does not match video")
            if (m.has("sha256") && !m.optString("sha256").equals(sha, true)) throw HttpError(400, "sha256 does not match video")

            synchronized(this) {
                val video = File(inbox, "$id.mp4"); val sidecar = File(inbox, "$id.json")
                if (video.exists()) {
                    val old = runCatching { JSONObject(sidecar.readText()).optString("received_sha256") }.getOrDefault("")
                    if (!old.equals(sha, true)) throw HttpError(409, "clip_id already stored with different content")
                    Log.i(TAG, "duplicate $id acknowledged")
                } else {
                    sidecar.writeText(m.put("received_sha256", sha).put("received_at_ms", System.currentTimeMillis()).toString())
                    if (!part.renameTo(video)) throw HttpError(500, "could not store clip")
                    stored++
                    Log.i(TAG, "stored $id (${video.length()} bytes)")
                    onStored(id)
                }
            }
            return 200 to JSONObject().put("clip_id", id).put("stored", true).toString()
        } finally {
            part.delete()
        }
    }

    /** The video part ends with CRLF--boundary--CRLF; cut it off the file. */
    private fun stripClosingBoundary(f: File, boundary: String) {
        RandomAccessFile(f, "rw").use { raf ->
            val tailLen = minOf(raf.length(), boundary.length + 64L).toInt()
            val tail = ByteArray(tailLen)
            raf.seek(raf.length() - tailLen); raf.readFully(tail)
            val marker = "\r\n--$boundary--".toByteArray()
            val at = (tailLen - marker.size downTo 0).firstOrNull { i -> marker.indices.all { tail[i + it] == marker[it] } }
                ?: throw HttpError(400, "closing boundary missing")
            raf.setLength(raf.length() - tailLen + at)
        }
    }

    private fun sha256(f: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        f.inputStream().use { s -> val buf = ByteArray(256 * 1024); while (true) { val n = s.read(buf); if (n < 0) break; md.update(buf, 0, n) } }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    private fun readLine(input: InputStream): String? {
        if (input is Limited) input.pushedBack?.let { input.pushedBack = null; return it }
        val b = ByteArrayOutputStream()
        while (true) {
            val c = input.read()
            if (c < 0) return if (b.size() == 0) null else b.toString("ISO-8859-1")
            if (c == '\n'.code) break
            if (c != '\r'.code) b.write(c)
            if (b.size() > 70_000) throw HttpError(431, "line too long")
        }
        return b.toString("ISO-8859-1")
    }

    private fun respond(out: OutputStream, status: Int, body: String) {
        val bytes = body.toByteArray()
        val reason = mapOf(200 to "OK", 400 to "Bad Request", 401 to "Unauthorized", 405 to "Method Not Allowed", 409 to "Conflict",
            411 to "Length Required", 413 to "Payload Too Large", 431 to "Header Too Large")[status] ?: "Error"
        out.write("HTTP/1.1 $status $reason\r\nContent-Type: application/json\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n".toByteArray())
        out.write(bytes); out.flush()
    }

    /** Reads at most [left] bytes: the request body, so the next request's bytes are never consumed. */
    private class Limited(private val src: InputStream, private var left: Long) : InputStream() {
        var pushedBack: String? = null
        fun unread(line: String) { pushedBack = line }
        override fun read(): Int = if (left <= 0) -1 else src.read().also { if (it >= 0) left-- }
        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (left <= 0) return -1
            val n = src.read(b, off, minOf(len.toLong(), left).toInt())
            if (n > 0) left -= n
            return n
        }
    }

    companion object {
        private const val MAX_BYTES = 200_000_000L

        fun lanAddress(): String? = runCatching {
            NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp && !it.isLoopback }
                .sortedBy { if (it.name.startsWith("wlan")) 0 else 1 }
                .flatMap { it.inetAddresses.toList() }.filterIsInstance<Inet4Address>().firstOrNull()?.hostAddress
        }.getOrNull()
    }
}

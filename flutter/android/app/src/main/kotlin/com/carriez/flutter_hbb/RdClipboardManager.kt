package com.carriez.flutter_hbb

import android.content.ClipData
import android.content.ClipboardManager
import android.os.Handler
import android.os.Looper
import androidx.annotation.Keep
import com.google.protobuf.ByteString
import com.google.protobuf.InvalidProtocolBufferException
import ffi.FFI
import hbb.MessageOuterClass.Clipboard
import hbb.MessageOuterClass.ClipboardFormat
import hbb.MessageOuterClass.MultiClipboards
import java.nio.ByteBuffer
import java.security.MessageDigest

class RdClipboardManager(private val clipboardManager: ClipboardManager) {
    private val main = Handler(Looper.getMainLooper())
    private var foreground = false
    private var allowedBySession = false
    private var allowedByEngine = false
    private var lastSentOrReceived: ByteArray? = null

    fun setForeground(focused: Boolean) {
        foreground = focused
    }

    fun setSessionAllowed(allowed: Boolean) {
        allowedBySession = allowed
        if (!allowed) lastSentOrReceived = null
    }

    @Keep
    fun rustEnableClientClipboard(enable: Boolean) {
        main.post {
            allowedByEngine = enable
            if (!enable) lastSentOrReceived = null
        }
    }

    fun syncClipboard(isClient: Boolean) {
        if (isClient) main.post(::sendIfAllowed)
    }

    private fun sendIfAllowed() {
        if (!foreground || !allowedBySession || !allowedByEngine) return
        val clip = clipboardManager.primaryClip ?: return
        if (clip.itemCount == 0) return
        val text = clip.getItemAt(0).text ?: return
        if (text.length > MAX_BYTES) return
        val bytes = text.toString().toByteArray(Charsets.UTF_8)
        if (bytes.isEmpty() || bytes.size > MAX_BYTES) return
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        if (lastSentOrReceived?.contentEquals(digest) == true) return
        val clipboard = Clipboard.newBuilder()
            .setFormat(ClipboardFormat.Text)
            .setContent(ByteString.copyFrom(bytes))
            .build()
        val payload = MultiClipboards.newBuilder().addClipboards(clipboard).build().toByteArray()
        val buffer = ByteBuffer.allocateDirect(payload.size + 1)
        buffer.put(1.toByte()) // Client, never host.
        buffer.put(payload)
        buffer.flip()
        lastSentOrReceived = digest
        FFI.onClipboardUpdate(buffer)
    }

    @Keep
    fun rustUpdateClipboard(clips: ByteArray) {
        if (clips.size > MAX_BYTES + 256) return
        val data = try {
            MultiClipboards.parseFrom(clips).clipboardsList
                .firstOrNull { it.format == ClipboardFormat.Text }?.content
        } catch (_: InvalidProtocolBufferException) {
            return
        } ?: return
        if (data.isEmpty || data.size() > MAX_BYTES || !data.isValidUtf8) return
        main.post {
            if (!foreground || !allowedBySession || !allowedByEngine) return@post
            val digest = MessageDigest.getInstance("SHA-256").digest(data.toByteArray())
            if (lastSentOrReceived?.contentEquals(digest) == true) return@post
            lastSentOrReceived = digest
            clipboardManager.setPrimaryClip(ClipData.newPlainText("Rymu", data.toStringUtf8()))
        }
    }

    // Compatibility for host source retained in the fork. Its Android services
    // are absent from the Rymu manifest and no clipboard data is exposed there.
    val isCaptureStarted: Boolean get() = false
    @Suppress("UNUSED_PARAMETER")
    fun setCaptureStarted(started: Boolean) = Unit
    fun checkPrimaryClip(isClient: Boolean) = syncClipboard(isClient)

    private companion object {
        const val MAX_BYTES = 64 * 1024
    }
}

package com.carriez.flutter_hbb

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicReference
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal class RymuAccountChannel(activity: Activity, messenger: BinaryMessenger) {
    private val preferences = activity.getSharedPreferences("rymu_account", Context.MODE_PRIVATE)
    private val callback = AtomicReference<String?>(null)
    private val channel = MethodChannel(
        messenger,
        "app.rymu/account",
        StandardMethodCodec.INSTANCE,
        messenger.makeBackgroundTaskQueue()
    )

    init {
        channel.setMethodCallHandler(::handle)
    }

    fun acceptCallback(intent: Intent?) {
        val uri = intent?.data ?: return
        if (intent.action != Intent.ACTION_VIEW || uri.scheme != "app.rymu" ||
            uri.encodedAuthority != "oauth" || uri.encodedPath != "/callback" ||
            uri.fragment != null || uri.toString().length > 512) return
        if (uri.queryParameterNames != setOf("code", "state") ||
            uri.getQueryParameters("code").singleOrNull()?.matches(TOKEN) != true ||
            uri.getQueryParameters("state").singleOrNull()?.matches(TOKEN) != true) return
        callback.set(uri.toString())
        channel.invokeMethod("oauthCallback", null)
    }

    fun close() = channel.setMethodCallHandler(null)

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "takeCallback" -> result.success(callback.getAndSet(null))
                "createPkce" -> {
                    val verifier = encode(randomBytes())
                    val challenge = MessageDigest.getInstance("SHA-256")
                        .digest(verifier.toByteArray(Charsets.US_ASCII))
                    result.success(mapOf(
                        "verifier" to verifier,
                        "challenge" to encode(challenge),
                        "state" to encode(randomBytes())
                    ))
                }
                "readAccount" -> result.success(read(ACCOUNT))
                "writeAccount" -> {
                    val account = call.arguments as String
                    require(account.toByteArray(Charsets.UTF_8).size <= 32768)
                    write(ACCOUNT, account)
                    result.success(null)
                }
                "clearAccount" -> {
                    check(preferences.edit().remove(ACCOUNT).remove(IDENTITY).commit())
                    callback.set(null)
                    result.success(null)
                }
                "signingSeed" -> {
                    val seed = read(IDENTITY) ?: encode(randomBytes()).also { write(IDENTITY, it) }
                    result.success(seed)
                }
                else -> result.notImplemented()
            }
        } catch (_: Exception) {
            // Exceptions may contain intent URIs or provider paths. Keep them out of logs.
            result.error("account_storage_unavailable", "Rymu account storage is unavailable.", null)
        }
    }

    private fun wrappingKey(create: Boolean): SecretKey {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        check(create)
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE).run {
            init(KeyGenParameterSpec.Builder(
                KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            ).setKeySize(256)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build())
            generateKey()
        }
    }

    private fun write(slot: String, value: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, wrappingKey(create = true))
        cipher.updateAAD(slot.toByteArray(Charsets.UTF_8))
        val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        check(preferences.edit().putString(slot, encode(cipher.iv + encrypted)).commit())
    }

    private fun read(slot: String): String? {
        val record = preferences.getString(slot, null) ?: return null
        val bytes = Base64.decode(record, BASE64_FLAGS)
        require(bytes.size >= 12 + 16)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, wrappingKey(create = false), GCMParameterSpec(128, bytes, 0, 12))
        cipher.updateAAD(slot.toByteArray(Charsets.UTF_8))
        return cipher.doFinal(bytes, 12, bytes.size - 12).toString(Charsets.UTF_8)
    }

    private fun randomBytes(): ByteArray = ByteArray(32).also(SecureRandom()::nextBytes)

    private fun encode(bytes: ByteArray): String = Base64.encodeToString(bytes, BASE64_FLAGS)

    private companion object {
        private const val KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "app.rymu.controller.account.v1"
        private const val ACCOUNT = "account-v1"
        private const val IDENTITY = "identity-v1"
        private val BASE64_FLAGS = Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP
        private val TOKEN = Regex("[A-Za-z0-9_-]{43,128}")
    }
}

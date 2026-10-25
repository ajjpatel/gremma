package com.gremma.android

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.IOException
import java.math.BigInteger
import java.net.Inet4Address
import java.net.NetworkInterface
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.spec.ECGenParameterSpec
import java.util.Collections
import java.util.Date
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.security.auth.x500.X500Principal

data class CameraLink(
    val running: Boolean = false,
    val status: String = "Camera receiver stopped.",
    val endpoint: String = "",
    val token: String = "",
    val certificateSha256: String = "",
) {
    fun pairingText() = """
        upload_url = "$endpoint"
        upload_cert_sha256 = "$certificateSha256"
        upload_timeout_seconds = 300

        # Put the following line in /etc/gremma-video/upload.env (not config.toml):
        GREMMA_UPLOAD_TOKEN=$token
    """.trimIndent()
}

/** Foreground receiver. Clips persist in private storage across activity/process restarts. */
class HomeCameraReceiver(context: Context, inbox: File, onStatus: (String) -> Unit) {
    companion object {
        const val PORT = 8443
        private const val ALIAS = "gremma-home-camera-tls-v1"

        fun endpoint(): String = runCatching {
            val interfaces = NetworkInterface.getNetworkInterfaces() ?: return@runCatching ""
            Collections.list(interfaces).filter { it.isUp && !it.isLoopback }
                .sortedBy { !it.name.startsWith("wlan") }
                .flatMap { Collections.list(it.inetAddresses) }
                .filterIsInstance<Inet4Address>()
                .firstOrNull { !it.isLoopbackAddress && !it.isLinkLocalAddress && it.isSiteLocalAddress }
                ?.hostAddress?.let { "https://$it:$PORT/v1/clips" }.orEmpty()
        }.getOrDefault("")
    }

    private val prefs = context.getSharedPreferences("gremma-camera-pairing", Context.MODE_PRIVATE)
    val token: String = prefs.getString("token", null) ?: run {
        val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
        ClipUploadServer.hex(bytes).also {
            check(prefs.edit().putString("token", it).commit()) { "Could not save camera pairing" }
        }
    }
    val certificateSha256: String
    private val server: ClipUploadServer

    init {
        val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!keys.containsAlias(ALIAS)) {
            KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore").apply {
                initialize(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    .setDigests(KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA384, KeyProperties.DIGEST_SHA512)
                    .setCertificateSubject(X500Principal("CN=Gremma Home Camera"))
                    .setCertificateSerialNumber(BigInteger.ONE)
                    .setCertificateNotBefore(Date(System.currentTimeMillis() - 86_400_000L))
                    .setCertificateNotAfter(Date(System.currentTimeMillis() + 10L * 365 * 86_400_000))
                    .build())
            }.generateKeyPair()
        }
        certificateSha256 = ClipUploadServer.hex(MessageDigest.getInstance("SHA-256").digest(keys.getCertificate(ALIAS).encoded))
        val managers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply { init(keys, null) }
        val tls = SSLContext.getInstance("TLS").apply { init(managers.keyManagers, null, SecureRandom()) }
        server = ClipUploadServer(PORT, inbox, File(context.cacheDir, "camera-uploads"), token, { directory ->
            // Android's FileInputStream cannot open directories; use the OS API for a durable rename.
            try {
                val fd = Os.open(directory.absolutePath, OsConstants.O_RDONLY or OsConstants.O_DIRECTORY, 0)
                try { Os.fsync(fd) } finally { Os.close(fd) }
            } catch (e: Exception) { throw IOException("Could not sync clip directory", e) }
        }, { message -> onStatus(message) })
        server.makeSecure(tls.serverSocketFactory, arrayOf("TLSv1.2", "TLSv1.3"))
    }

    fun start() = server.start(300_000, true)
    fun stop() = server.stop()
    fun link() = CameraLink(true, "Ready to receive camera clips.", endpoint(), token, certificateSha256)
}

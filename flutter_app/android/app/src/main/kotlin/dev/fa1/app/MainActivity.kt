package dev.fa1.app

import android.content.Context
import android.content.Intent
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.view.WindowManager
import dev.fa1.app.mobile.MobileChannels
import dev.fa1.app.mobile.MobileProviders
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.util.concurrent.Executors
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

class MainActivity : FlutterActivity() {
    /// Keychain ops run off the main thread (Keystore + disk I/O); answers
    /// hop back to the UI thread like the wakelock call below.
    private val keychainExecutor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(
            messenger,
            "fah/background",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setIdleTimerDisabled" -> {
                    // Wakelock: an in-flight agent run must not let the
                    // phone lock itself mid-stream.
                    val disabled = call.argument<Boolean>("disabled") ?: false
                    runOnUiThread {
                        if (disabled) {
                            window.addFlags(
                                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
                            )
                        } else {
                            window.clearFlags(
                                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
                            )
                        }
                        result.success(null)
                    }
                }
                "begin" ->
                    // Android grants no ~30 s extended-execution budget; a
                    // backgrounded process keeps running as a cached
                    // process without one. Answer the iOS "refused"
                    // contract (-1 → the Dart side maps it to null) instead
                    // of notImplemented(), whose MissingPluginException
                    // spammed every run's log (issue #329).
                    result.success(-1)
                "end" -> result.success(null)
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            messenger,
            "fah/keychain",
        ).setMethodCallHandler { call, result ->
            keychainExecutor.execute {
                val answer: Any? = try {
                    when (call.method) {
                        "isAvailable" -> keychainAvailable()
                        "readAll" -> keychainReadAll()
                        "set" -> keychainSet(
                            call.argument<String>("name") ?: "",
                            call.argument<String>("value") ?: "",
                        )
                        "delete" -> keychainDelete(
                            call.argument<String>("name") ?: "",
                        )
                        else -> null
                    }
                } catch (e: Exception) {
                    // Keystore/prefs failure: the store reads as absent —
                    // isAvailable answers false, everything else degrades
                    // to the iOS channel's failure shapes. Never crashes
                    // boot (issue #329 E2).
                    when (call.method) {
                        "isAvailable" -> false
                        "readAll" -> emptyMap<String, String>()
                        else -> false
                    }
                }
                runOnUiThread { result.success(answer) }
            }
        }
        // ── dev.fa1.app/mobile* (issue #622) ────────────────────────────
        // Control + launch channels answer on both flavors; automation +
        // shell need the god providers, which live in src/god and are
        // absent from the store APK entirely.
        val mobileProviders = if (BuildConfig.FLAVOR == "god") {
            // The store variant compiles without src/god, so the god class
            // is resolved reflectively — on a god build it is always there.
            try {
                Class.forName("dev.fa1.app.mobile.GodProviders")
                    .getConstructor(Context::class.java)
                    .newInstance(this) as MobileProviders
            } catch (_: ReflectiveOperationException) {
                MobileProviders(this)
            }
        } else {
            MobileProviders(this)
        }
        MobileChannels.register(messenger, mobileProviders)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        // Projection consent (god flavor) routes through the channel layer.
        if (MobileChannels.handleActivityResult(requestCode, resultCode, data)) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    // ── fah/keychain ─────────────────────────────────────────────────────
    // App-scoped secure storage for API keys, parity with the iOS/macOS
    // Keychain handler (isAvailable / readAll / set {name, value} /
    // delete {name}, same response shapes). Values encrypt with AES-256-GCM
    // (KeychainCodec) under a non-exportable AndroidKeyStore master key:
    // device-bound (uninstall clears — E3), and the ciphertext-only prefs
    // file is excluded from cloud backup in the manifest rules (E4 — a
    // restored blob is undecryptable without the key, which never migrates).

    private fun keychainPrefs() =
        getSharedPreferences("fah_keychain", MODE_PRIVATE)

    private fun keychainMasterKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore")
        keyStore.load(null)
        (keyStore.getKey("fah_keychain_master", null) as? SecretKey)
            ?.let { return it }
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            "AndroidKeyStore",
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                "fah_keychain_master",
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private fun keychainAvailable(): Boolean =
        // The AES/GCM AndroidKeyStore floor; below it the store reports
        // absent and the app shows the session-only warning instead.
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && try {
            keychainMasterKey()
            true
        } catch (e: Exception) {
            false
        }

    private fun keychainReadAll(): Map<String, String> {
        val key = keychainMasterKey()
        val out = mutableMapOf<String, String>()
        for ((name, blob) in keychainPrefs().all) {
            val raw = blob as? String ?: continue
            val value = raw.decodeBase64()?.let {
                KeychainCodec.decrypt(key, it)
            } ?: continue
            out[name] = String(value, Charsets.UTF_8)
        }
        return out
    }

    private fun keychainSet(name: String, value: String): Boolean {
        if (name.isEmpty()) return false
        val blob = KeychainCodec.encrypt(
            keychainMasterKey(),
            value.toByteArray(Charsets.UTF_8),
        )
        return keychainPrefs().edit()
            .putString(name, Base64.encodeToString(blob, Base64.NO_WRAP))
            .commit()
    }

    private fun keychainDelete(name: String): Boolean {
        if (name.isEmpty()) return false
        // True also when the name was absent, like the iOS handler.
        return keychainPrefs().edit().remove(name).commit()
    }

    private fun String.decodeBase64(): ByteArray? = try {
        Base64.decode(this, Base64.NO_WRAP)
    } catch (e: IllegalArgumentException) {
        null
    }
}

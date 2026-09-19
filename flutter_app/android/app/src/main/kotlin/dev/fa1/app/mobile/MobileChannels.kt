package dev.fa1.app.mobile

import android.content.Intent
import android.os.Handler
import android.os.Looper
import dev.fa1.app.BuildConfig
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/// The four dev.fa1.app/mobile* channels (issue #622 contract, slice B is
/// the Dart counterpart). Control answers on every flavor; launch works on
/// both (manifest `<queries>`); automation + shell answer notImplemented()
/// unless a provider is wired — the god flavor supplies real ones via
/// GodProviders, the store flavor ships MobileProviders with nulls.
object MobileChannels {
    private const val CONTROL = "dev.fa1.app/mobile"
    private const val LAUNCH = "dev.fa1.app/mobile_launch"
    private const val AUTOMATION = "dev.fa1.app/mobile_automation"
    private const val SHELL = "dev.fa1.app/mobile_shell"

    /// startActivityForResult code for the projection consent dialog.
    const val PROJECTION_CONSENT_REQUEST = 4231

    private val mainHandler = Handler(Looper.getMainLooper())

    // Single worker: automation is a strict sequence (dump → tap → dump),
    // serializing beats juggling reentrancy. ponytail: single-thread executor;
    // parallel per-channel pools only if a dump ever visibly blocks taps.
    private val worker = Executors.newSingleThreadExecutor()

    @Volatile
    private var providers: MobileProviders? = null

    fun register(messenger: BinaryMessenger, providers: MobileProviders, flavor: String = BuildConfig.FLAVOR) {
        this.providers = providers
        registerControl(messenger, providers, flavor)
        registerLaunch(messenger, providers)
        registerAutomation(messenger, providers)
        registerShell(messenger, providers)
    }

    /// MainActivity.onActivityResult forwards here; true = consumed by the
    /// projection consent flow.
    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean =
        (providers as? MobileActivityResultDelegate)
            ?.onActivityResult(requestCode, resultCode, data) ?: false

    // ── dev.fa1.app/mobile ────────────────────────────────────────────────

    private fun registerControl(messenger: BinaryMessenger, providers: MobileProviders, flavor: String) {
        MethodChannel(messenger, CONTROL).setMethodCallHandler { call, result ->
            when (call.method) {
                "flavor" -> result.success(flavor)
                "accessibilityEnabled" -> result.success(providers.automation?.isConnected == true)
                else -> {
                    val delegate = providers as? MobileControlDelegate
                    when (call.method) {
                        "openAccessibilitySettings" ->
                            if (delegate != null) {
                                delegate.openAccessibilitySettings()
                                result.success(null)
                            } else {
                                result.notImplemented()
                            }
                        "disableAccessibility" ->
                            if (delegate != null) {
                                delegate.disableAccessibility()
                                result.success(null)
                            } else {
                                result.notImplemented()
                            }
                        "projectionConsent" ->
                            if (delegate != null) {
                                result.success(delegate.projectionConsent())
                            } else {
                                result.notImplemented()
                            }
                        else -> result.notImplemented()
                    }
                }
            }
        }
    }

    // ── dev.fa1.app/mobile_launch ─────────────────────────────────────────

    private fun registerLaunch(messenger: BinaryMessenger, providers: MobileProviders) {
        MethodChannel(messenger, LAUNCH).setMethodCallHandler { call, result ->
            when (call.method) {
                "launch" -> worker.execute {
                    val ok = providers.launch(
                        call.argument<String>("packageName"),
                        call.argument<String>("deepLink"),
                    )
                    mainHandler.post { result.success(ok) }
                }
                "launcherApps" -> worker.execute {
                    val apps = providers.launcherApps()
                    mainHandler.post { result.success(apps) }
                }
                "allPackages" -> worker.execute {
                    // null on store (no QUERY_ALL_PACKAGES) — an honest
                    // "unavailable", not an error.
                    val packages = providers.allPackages()
                    mainHandler.post { result.success(packages) }
                }
                else -> result.notImplemented()
            }
        }
    }

    // ── dev.fa1.app/mobile_automation ─────────────────────────────────────

    private fun registerAutomation(messenger: BinaryMessenger, providers: MobileProviders) {
        MethodChannel(messenger, AUTOMATION).setMethodCallHandler { call, result ->
            val automation = providers.automation
            when {
                automation == null -> result.notImplemented()
                !automation.isConnected -> result.error(
                    "automation-offline",
                    "accessibility service is not connected — enable it in system settings",
                    null,
                )
                else -> worker.execute {
                    val answer: Any? = try {
                        when (call.method) {
                            "dumpHierarchy" -> automation.dumpHierarchy()
                            "screenshot" -> automation.screenshot()
                            "tap" -> {
                                automation.tap(
                                    call.argument<String>("elementId"),
                                    call.num("x"),
                                    call.num("y"),
                                )
                                null
                            }
                            "swipe" -> {
                                automation.swipe(
                                    call.num("fromX"),
                                    call.num("fromY"),
                                    call.num("toX"),
                                    call.num("toY"),
                                    call.num("durationMs")?.toLong(),
                                )
                                null
                            }
                            "text" -> {
                                automation.text(
                                    call.argument<String>("elementId"),
                                    call.argument<String>("text") ?: "",
                                    call.argument<Boolean>("clear") ?: false,
                                )
                                null
                            }
                            else -> NotImplemented
                        }
                    } catch (e: Exception) {
                        Failure(e)
                    }
                    mainHandler.post {
                        when (answer) {
                            is Failure -> result.error("automation-error", answer.error.message, null)
                            NotImplemented -> result.notImplemented()
                            else -> result.success(answer)
                        }
                    }
                }
            }
        }
    }

    // ── dev.fa1.app/mobile_shell ──────────────────────────────────────────

    private fun registerShell(messenger: BinaryMessenger, providers: MobileProviders) {
        MethodChannel(messenger, SHELL).setMethodCallHandler { call, result ->
            val shell = providers.shell
            when {
                shell == null -> result.notImplemented()
                call.method == "isRunning" -> result.success(shell.isRunning())
                call.method == "run" -> {
                    if (!shell.isRunning()) {
                        result.error(
                            "shizuku-not-running",
                            "Shizuku binder unavailable or permission not granted",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                    worker.execute {
                        val answer: Any? = try {
                            shell.run(
                                call.argument<String>("command") ?: "",
                                call.num("timeoutMs")?.toLong() ?: 10_000L,
                            )
                        } catch (e: Exception) {
                            Failure(e)
                        }
                        mainHandler.post {
                            when (answer) {
                                is Failure -> result.error("shell-error", answer.error.message, null)
                                else -> result.success(answer)
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun MethodCall.num(key: String): Double? = (argument<Any>(key) as? Number)?.toDouble()

    private object NotImplemented

    private class Failure(val error: Exception)
}

/// Launch-channel capability. Real on both flavors: the main manifest's
/// `<queries>` LAUNCHER intent is enough to enumerate + launch visible apps.
interface MobileLaunchProvider {
    fun launch(packageName: String?, deepLink: String?): Boolean

    /// [{packageName, label?}] — launcher-visible apps.
    fun launcherApps(): List<Map<String, Any?>>

    /// Full inventory; null on flavors without QUERY_ALL_PACKAGES (store).
    fun allPackages(): List<Map<String, Any?>>?
}

/// Automation-channel capability (god flavor): accessibility-backed
/// hierarchy access plus projection-backed screenshots.
interface MobileAutomationProvider {
    /// True only while the accessibility service is bound.
    val isConnected: Boolean

    /// uiautomator-shaped XML; `id="eN"` attributes carry the tap cache.
    fun dumpHierarchy(): String

    /// PNG bytes of the current screen.
    fun screenshot(): ByteArray

    /// elementId from the last dump, or absolute screen coordinates.
    fun tap(elementId: String?, x: Double?, y: Double?)
    fun swipe(fromX: Double?, fromY: Double?, toX: Double?, toY: Double?, durationMs: Long?)
    fun text(elementId: String?, text: String, clear: Boolean)
}

/// Shell-channel capability (god flavor, Shizuku-backed).
interface MobileShellProvider {
    fun isRunning(): Boolean

    /// {exitCode, stdout, stderr}; exitCode is null when the timeout fired.
    fun run(command: String, timeoutMs: Long): Map<String, Any?>
}

/// Control-channel extras only the god provider stack can answer.
interface MobileControlDelegate {
    fun openAccessibilitySettings()
    fun disableAccessibility()

    /// Launches the system consent dialog; true when it started (or
    /// projection is already active).
    fun projectionConsent(): Boolean
}

/// Receives activity results routed through MainActivity.
interface MobileActivityResultDelegate {
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean
}

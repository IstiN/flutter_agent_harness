package dev.fa1.app.mobile

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.provider.Settings

/// god-flavor provider stack (issue #622): real automation + shell over the
/// accessibility, projection and Shizuku services; launch/allPackages are
/// inherited from MobileProviders. Lives only under src/god — the store APK
/// never compiles or ships it.
class GodProviders(context: Context) :
    MobileProviders(context), MobileControlDelegate, MobileActivityResultDelegate {

    override val automation: MobileAutomationProvider = GodAutomation()
    override val shell: MobileShellProvider = MobileShellBridge()

    // ── MobileControlDelegate ─────────────────────────────────────────────

    override fun openAccessibilitySettings() {
        context.startActivity(
            Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }

    override fun disableAccessibility() {
        // Clean opt-out; onDestroy clears the static instance.
        MobileAccessibilityService.instance?.disableSelf()
    }

    override fun projectionConsent(): Boolean {
        if (MobileProjectionService.instance != null) return true
        val activity = context as? Activity ?: return false
        val manager =
            activity.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as? MediaProjectionManager
                ?: return false
        return try {
            activity.startActivityForResult(
                manager.createScreenCaptureIntent(),
                MobileChannels.PROJECTION_CONSENT_REQUEST,
            )
            true
        } catch (_: Exception) {
            false
        }
    }

    // ── MobileActivityResultDelegate ───────────────────────────────────────

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != MobileChannels.PROJECTION_CONSENT_REQUEST) return false
        if (resultCode == Activity.RESULT_OK && data != null) {
            val service = Intent(context, MobileProjectionService::class.java)
                .putExtra(MobileProjectionService.EXTRA_RESULT_CODE, resultCode)
                .putExtra(MobileProjectionService.EXTRA_RESULT_DATA, data)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(service)
            } else {
                context.startService(service)
            }
        }
        return true
    }

    // ── MobileLaunchProvider additions ────────────────────────────────────

    // QUERY_ALL_PACKAGES (god manifest) unlocks the full inventory.
    override fun allPackages(): List<Map<String, Any?>>? = try {
        val pm = context.packageManager
        pm.getInstalledPackages(0).map { info ->
            mapOf(
                "packageName" to info.packageName,
                "label" to info.applicationInfo?.loadLabel(pm)?.toString(),
            )
        }
    } catch (_: Exception) {
        null
    }

    /// Accessibility drives the hierarchy + gestures; the projection service
    /// owns screenshots.
    private inner class GodAutomation : MobileAutomationProvider {
        override val isConnected: Boolean
            get() = MobileAccessibilityService.instance != null

        override fun dumpHierarchy(): String =
            MobileAccessibilityService.instance?.dumpHierarchy() ?: "<hierarchy />\n"

        override fun screenshot(): ByteArray =
            MobileProjectionService.instance?.screenshot()
                ?: throw IllegalStateException(
                    "screen projection not active — call projectionConsent first",
                )

        override fun tap(elementId: String?, x: Double?, y: Double?) {
            MobileAccessibilityService.instance?.tap(elementId, x, y)
        }

        override fun swipe(
            fromX: Double?,
            fromY: Double?,
            toX: Double?,
            toY: Double?,
            durationMs: Long?,
        ) {
            MobileAccessibilityService.instance?.swipe(fromX, fromY, toX, toY, durationMs)
        }

        override fun text(elementId: String?, text: String, clear: Boolean) {
            MobileAccessibilityService.instance?.text(elementId, text, clear)
        }
    }
}

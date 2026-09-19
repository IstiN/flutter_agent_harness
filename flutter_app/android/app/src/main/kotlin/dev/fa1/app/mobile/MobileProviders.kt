package dev.fa1.app.mobile

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri

/// Store-flavor provider stack (issue #622): launch + launcherApps work on
/// every flavor via the main manifest `<queries>` LAUNCHER intent;
/// automation/shell stay null so their channels answer notImplemented() and
/// Dart reports honest unavailable states. GodProviders overrides the nulls.
open class MobileProviders(val context: Context) : MobileLaunchProvider {
    open val automation: MobileAutomationProvider? get() = null
    open val shell: MobileShellProvider? get() = null

    override fun launch(packageName: String?, deepLink: String?): Boolean {
        val intent = when {
            !deepLink.isNullOrBlank() -> Intent(Intent.ACTION_VIEW, Uri.parse(deepLink))
            !packageName.isNullOrBlank() ->
                context.packageManager.getLaunchIntentForPackage(packageName)
            else -> null
        }?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) ?: return false
        return try {
            context.startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }

    override fun launcherApps(): List<Map<String, Any?>> {
        val pm = context.packageManager
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        return pm.queryIntentActivities(launcher, 0)
            .distinctBy { it.activityInfo.packageName }
            .map {
                mapOf(
                    "packageName" to it.activityInfo.packageName,
                    "label" to it.loadLabel(pm).toString(),
                )
            }
    }

    // Store: no QUERY_ALL_PACKAGES → null, never a partial list.
    override fun allPackages(): List<Map<String, Any?>>? = null
}

package dev.fa1.android

import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
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
                else -> result.notImplemented()
            }
        }
    }
}

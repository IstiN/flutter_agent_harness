package dev.fa1.app.mobile

import android.content.pm.PackageManager
import rikka.shizuku.Shizuku
import java.lang.Process
import java.util.concurrent.TimeUnit

/// god-flavor Shizuku shell (issue #622). Requires the Shizuku app (or Sui)
/// running on-device; the binder arrives via ShizukuProvider (god manifest).
class MobileShellBridge : MobileShellProvider {

    override fun isRunning(): Boolean = try {
        // Binder up + permission granted — without the grant `run` would
        // fail anyway, so the pair collapses into one "available" answer.
        // ponytail: permission grant still needs a manual first run in the
        // Shizuku app; wire Shizuku.OnRequestPermissionResultListener if the
        // Dart UI ever wants an in-app grant prompt.
        Shizuku.pingBinder() &&
            Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
    } catch (_: Throwable) {
        false
    }

    override fun run(command: String, timeoutMs: Long): Map<String, Any?> {
        if (!isRunning()) throw ShellNotRunningException()
        val process = newShizukuProcess(command)
        val stdout = StringBuilder()
        val stderr = StringBuilder()
        val outThread = Thread {
            stdout.append(process.inputStream.readBytes().toString(Charsets.UTF_8))
        }
        val errThread = Thread {
            stderr.append(process.errorStream.readBytes().toString(Charsets.UTF_8))
        }
        outThread.start()
        errThread.start()
        // ponytail: timed waitFor needs API 26; the god flavor targets
        // modern sideloaded devices — add a watchdog fallback for 24/25 if
        // one ever shows up in the wild.
        val finished = process.waitFor(timeoutMs.coerceAtLeast(1), TimeUnit.MILLISECONDS)
        if (!finished) {
            process.destroy()
            // Stream readers exit at EOF; destroy() closes the pipes.
            outThread.join(1_000)
            errThread.join(1_000)
            return mapOf(
                "exitCode" to null,
                "stdout" to stdout.toString(),
                "stderr" to stderr.toString(),
            )
        }
        outThread.join(1_000)
        errThread.join(1_000)
        return mapOf(
            "exitCode" to process.exitValue(),
            "stdout" to stdout.toString(),
            "stderr" to stderr.toString(),
        )
    }

    /// Shizuku.newProcess' static return type moved between api releases —
    /// resolve it reflectively so this file compiles against any 13.x
    /// artifact; the returned object is a java.lang.Process at runtime.
    private fun newShizukuProcess(command: String): Process =
        Shizuku::class.java
            .getMethod(
                "newProcess",
                Array<String>::class.java,
                Array<String>::class.java,
                String::class.java,
            )
            .invoke(null, arrayOf("sh", "-c", command), null, null) as Process
}

/// Maps to the channel layer's named "shizuku-not-running" absence.
class ShellNotRunningException :
    IllegalStateException("Shizuku is not running or permission not granted")

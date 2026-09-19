package dev.fa1.app.mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/// god-flavor screen capture (issue #622). Holds the MediaProjection +
/// VirtualDisplay + ImageReader; screenshot() encodes the latest frame as
/// PNG. The projection token is session-bound (dies on reboot/stop) — no
/// persistence beyond this object. Android 14 requires startForeground()
/// BEFORE getMediaProjection(), so onStartCommand calls it first.
class MobileProjectionService : Service() {
    companion object {
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"

        private const val CHANNEL_ID = "fa1_projection"
        private const val NOTIFICATION_ID = 6220

        @Volatile
        var instance: MobileProjectionService? = null
            private set
    }

    private val handler = Handler(Looper.getMainLooper())
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null

    /// Latest rendered frame, held until screenshot() drains it.
    private var pending: Image? = null
    private var frameLatch: CountDownLatch? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val resultCode = intent?.getIntExtra(EXTRA_RESULT_CODE, -1) ?: -1
        val resultData = intent?.getParcelableExtra<Intent>(EXTRA_RESULT_DATA)
        if (resultCode == -1 || resultData == null) {
            stopSelf()
            return START_NOT_STICKY
        }

        ensureChannel()
        // FGS with the mediaProjection type must be entered before the
        // projection is created (Android 14 enforces with a SecurityException).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                buildNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } else {
            startForeground(NOTIFICATION_ID, buildNotification())
        }

        val metrics = resources.displayMetrics
        val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        // getMediaProjection returns null on an invalid/expired consent
        // token (@Nullable in recent SDKs): nothing to project — stop
        // cleanly like the missing-intent guard above instead of crashing
        // the foreground service.
        val mediaProjection = manager.getMediaProjection(resultCode, resultData) ?: run {
            stopSelf()
            return START_NOT_STICKY
        }
        projection = mediaProjection
        mediaProjection.registerCallback(
            object : MediaProjection.Callback() {
                override fun onStop() {
                    // User revoked capture from the status bar tile.
                    stopSelf()
                }
            },
            handler,
        )

        val imageReader = ImageReader.newInstance(
            metrics.widthPixels,
            metrics.heightPixels,
            PixelFormat.RGBA_8888,
            2,
        )
        imageReader.setOnImageAvailableListener({ r ->
            val image = r.acquireLatestImage() ?: return@setOnImageAvailableListener
            synchronized(this) {
                pending?.close()
                pending = image
            }
            frameLatch?.countDown()
        }, handler)
        reader = imageReader

        display = mediaProjection.createVirtualDisplay(
            "fa1-capture",
            metrics.widthPixels,
            metrics.heightPixels,
            metrics.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            imageReader.surface,
            null,
            handler,
        )

        instance = this
        return START_NOT_STICKY
    }

    /// PNG bytes of the most recent frame. Runs on the channel worker
    /// thread; the ImageReader callback owns delivery on the main looper.
    fun screenshot(): ByteArray {
        val image = acquireFrame() ?: error("no screen frame available yet — try again")
        try {
            val plane = image.planes[0]
            val buffer = plane.buffer
            buffer.rewind()
            val pixelStride = plane.pixelStride
            val rowStride = plane.rowStride
            val rowPad = rowStride - pixelStride * image.width
            // Row padding (stride ≠ width·pixelStride) needs a wide bitmap
            // followed by a crop.
            val full = Bitmap.createBitmap(
                image.width + rowPad / pixelStride,
                image.height,
                Bitmap.Config.ARGB_8888,
            )
            full.copyPixelsFromBuffer(buffer)
            val bitmap =
                if (rowPad == 0) full else Bitmap.createBitmap(full, 0, 0, image.width, image.height)
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            if (bitmap !== full) {
                full.recycle()
                bitmap.recycle()
            }
            return out.toByteArray()
        } finally {
            image.close()
        }
    }

    private fun acquireFrame(): Image? {
        // Awaiting happens OUTSIDE the monitor: the ImageReader callback
        // needs `this` to deliver the frame.
        var latch: CountDownLatch? = null
        synchronized(this) {
            pending?.let { image ->
                pending = null
                return image
            }
            latch = CountDownLatch(1)
            frameLatch = latch
        }
        if (latch?.await(500, TimeUnit.MILLISECONDS) != true) {
            synchronized(this) { frameLatch = null }
            return null
        }
        return synchronized(this) {
            frameLatch = null
            val image = pending
            pending = null
            image
        }
    }

    private fun ensureChannel() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Screen capture", NotificationManager.IMPORTANCE_LOW),
        )
    }

    private fun buildNotification(): Notification =
        Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Fa is capturing the screen")
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .build()

    override fun onDestroy() {
        if (instance === this) instance = null
        synchronized(this) {
            pending?.close()
            pending = null
        }
        display?.release()
        display = null
        reader?.close()
        reader = null
        projection?.stop()
        projection = null
        super.onDestroy()
    }
}

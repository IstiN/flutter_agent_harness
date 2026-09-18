package dev.fa1.app.mobile

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityEvent
import android.view.GestureDescription
import android.graphics.Path

/// god-flavor accessibility service (issue #622): serializes the active
/// window to uiautomator-shaped XML and dispatches taps/swipes/text. The
/// store APK never compiles this file — it lives in src/god only.
class MobileAccessibilityService : AccessibilityService() {
    companion object {
        @Volatile
        var instance: MobileAccessibilityService? = null
            private set
    }

    /// id ("e1"…) → node from the LAST dump; rebuilt on every dumpHierarchy.
    @Volatile
    private var nodeCache: Map<String, AccessibilityNodeInfo> = emptyMap()

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit

    override fun onInterrupt() = Unit

    fun dumpHierarchy(): String {
        val root = rootInActiveWindow
        val cache = HashMap<String, AccessibilityNodeInfo>()
        val xml = StringBuilder()
        val rotation = @Suppress("DEPRECATION")
        (getSystemService(Context.WINDOW_SERVICE) as WindowManager)
            .defaultDisplay.rotation
        xml.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        xml.append("<hierarchy rotation=\"").append(rotation).append("\">\n")
        if (root != null) {
            appendNode(root, 0, xml, cache)
        } else {
            // No active window yet — honest empty dump, cache reset.
            xml.append("  <node bounds=\"[0,0][0,0]\" />\n")
        }
        xml.append("</hierarchy>\n")
        nodeCache = cache
        return xml.toString()
    }

    /// Document-order walk; every node gets `id="eN"` so Dart can filter the
    /// XML freely while elementIds stay stable for tap/text.
    private fun appendNode(
        node: AccessibilityNodeInfo,
        depth: Int,
        xml: StringBuilder,
        cache: HashMap<String, AccessibilityNodeInfo>,
    ) {
        val id = "e${cache.size + 1}"
        cache[id] = node
        val bounds = Rect()
        node.getBoundsInScreen(bounds)
        val indent = "  ".repeat(depth + 2)
        xml.append(indent)
            .append("<node id=\"").append(id).append('"')
            .append(" text=").append(q(node.text?.toString()))
            .append(" content-desc=").append(q(node.contentDescription?.toString()))
            .append(" class=").append(q(node.className?.toString()))
            .append(" package=").append(q(node.packageName?.toString()))
            .append(" resource-id=").append(q(node.viewIdResourceName))
            .append(" checkable=\"").append(node.isCheckable).append('"')
            .append(" checked=\"").append(node.isChecked).append('"')
            .append(" clickable=\"").append(node.isClickable).append('"')
            .append(" scrollable=\"").append(node.isScrollable).append('"')
            .append(" password=\"").append(node.isPassword).append('"')
            .append(" bounds=\"[").append(bounds.left).append(',')
            .append(bounds.top).append("][").append(bounds.right)
            .append(',').append(bounds.bottom).append("]\"")
        if (node.childCount == 0) {
            xml.append(" />\n")
            return
        }
        xml.append(">\n")
        for (i in 0 until node.childCount) {
            node.getChild(i)?.let { appendNode(it, depth + 1, xml, cache) }
        }
        xml.append(indent).append("</node>\n")
    }

    fun tap(elementId: String?, x: Double?, y: Double?): Boolean {
        if (elementId != null) {
            val node = nodeCache[elementId] ?: return false
            if (node.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return true
            // Stale/unclickable node: fall back to a coordinate tap at center.
            val bounds = Rect()
            node.getBoundsInScreen(bounds)
            return gestureTap(
                (bounds.left + bounds.right) / 2f,
                (bounds.top + bounds.bottom) / 2f,
            )
        }
        if (x != null && y != null) return gestureTap(x.toFloat(), y.toFloat())
        return false
    }

    fun swipe(
        fromX: Double?,
        fromY: Double?,
        toX: Double?,
        toY: Double?,
        durationMs: Long?,
    ): Boolean {
        if (fromX == null || fromY == null || toX == null || toY == null) return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return false
        val path = Path().apply {
            moveTo(fromX.toFloat(), fromY.toFloat())
            lineTo(toX.toFloat(), toY.toFloat())
        }
        val stroke = GestureDescription.StrokeDescription(
            path, 0, (durationMs ?: 300L).coerceIn(1L, 60_000L),
        )
        return dispatchGesture(
            GestureDescription.Builder().addStroke(stroke).build(),
            null,
            null,
        )
    }

    fun text(elementId: String?, value: String, clear: Boolean): Boolean {
        val node = nodeCache[elementId] ?: return false
        if (clear) {
            // Null argument with ACTION_SET_TEXT clears the field.
            node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, null)
        }
        val args = Bundle().apply {
            putCharSequence(
                AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                value,
            )
        }
        return node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }
    private fun gestureTap(x: Float, y: Float): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return false
        val path = Path().apply {
            moveTo(x, y)
            lineTo(x, y)
        }
        val stroke = GestureDescription.StrokeDescription(path, 0, 50)
        return dispatchGesture(
            GestureDescription.Builder().addStroke(stroke).build(),
            null,
            null,
        )
    }
}

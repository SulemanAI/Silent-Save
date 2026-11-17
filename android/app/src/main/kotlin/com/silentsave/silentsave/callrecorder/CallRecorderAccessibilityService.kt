package com.silentsave.silentsave.callrecorder

import android.accessibilityservice.AccessibilityService
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.TextUtils
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent

/**
 * Lightweight Android [AccessibilityService] for Option 1 (Zero-Tap Voice Call Auto-Recording
 * + Instant 1-Tap Video Screen-Capture Prompt).
 *
 * Concurrent Audio Capture compliance on Android 10–16:
 *  - Exposes its bound [Context] ([instance]) so [CallMediaRecorderEngine] can attribute
 *    `AudioRecord.Builder().setContext(...)` directly to the AccessibilityService context.
 *  - Attaches a tiny non-focusable `TYPE_ACCESSIBILITY_OVERLAY` window while a call recording
 *    is active so Android's `AudioPolicyService::UidPolicy::isA11yOnTop()` recognizes the
 *    Accessibility UID as active on top during concurrent VoIP capture.
 *  - Configured with `android:canRetrieveWindowContent="false"` — never reads or scrapes
 *    WhatsApp screen text.
 */
class CallRecorderAccessibilityService : AccessibilityService() {

    companion object {
        private const val TAG = "CallRecA11y"
        private val mainHandler = Handler(Looper.getMainLooper())

        @Volatile
        var instance: CallRecorderAccessibilityService? = null
            private set

        /**
         * Returns the bound [CallRecorderAccessibilityService] context if connected,
         * or falls back to [fallbackContext].
         */
        fun getCaptureAttributionContext(fallbackContext: Context): Context {
            return instance ?: fallbackContext
        }

        /**
         * Shows or hides the 1x1 `TYPE_ACCESSIBILITY_OVERLAY` active-recording indicator window
         * so `WindowManagerService` and `AudioPolicyService` (`isA11yOnTop()`) treat the
         * AccessibilityService as actively in use while a call is being recorded.
         */
        fun setRecordingOverlayActive(active: Boolean) {
            val action = Runnable {
                val svc = instance ?: return@Runnable
                if (active) {
                    svc.attachOverlayWindowIfNeeded()
                } else {
                    svc.detachOverlayWindowIfPresent()
                }
            }
            if (Looper.myLooper() == Looper.getMainLooper()) {
                action.run()
            } else {
                mainHandler.post(action)
            }
        }

        /**
         * Returns `true` if [CallRecorderAccessibilityService] is currently bound OR enabled
         * in `Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES`.
         */
        fun isEnabled(context: Context): Boolean {
            if (instance != null) return true
            return try {
                val expected = ComponentName(context, CallRecorderAccessibilityService::class.java)
                val enabledServices = Settings.Secure.getString(
                    context.contentResolver,
                    Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
                ) ?: return false

                val splitter = TextUtils.SimpleStringSplitter(':')
                splitter.setString(enabledServices)
                while (splitter.hasNext()) {
                    val componentStr = splitter.next()
                    val parsed = ComponentName.unflattenFromString(componentStr)
                    if (parsed == expected) {
                        return true
                    }
                }
                false
            } catch (e: Exception) {
                Log.w(TAG, "Error checking accessibility enabled status: ${e.message}")
                false
            }
        }

        /**
         * Opens Android's system Accessibility Settings screen so the user can toggle
         * "SilentSave Auto Call Recorder" ON.
         */
        fun openAccessibilitySettings(context: Context) {
            try {
                val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                context.startActivity(intent)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to open Accessibility settings: ${e.message}")
            }
        }
    }

    private var overlayView: View? = null

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        Log.i(TAG, "=== CallRecorderAccessibilityService CONNECTED (0-tap voice auto-record ready) ===")
        if (CallRecorderService.isActivelyRecording) {
            attachOverlayWindowIfNeeded()
        }
    }

    private fun attachOverlayWindowIfNeeded() {
        if (overlayView != null) return
        try {
            val wm = getSystemService(WINDOW_SERVICE) as? WindowManager ?: return
            val view = View(this).apply {
                // Subtle 2x2 pixel indicator in top-right status bar corner
                setBackgroundColor(Color.argb(18, 0, 230, 180))
            }
            val lp = WindowManager.LayoutParams(
                2,
                2,
                WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                PixelFormat.TRANSLUCENT
            ).apply {
                gravity = Gravity.TOP or Gravity.END
                x = 0
                y = 0
            }
            wm.addView(view, lp)
            overlayView = view
            Log.i(TAG, "✓ Attached TYPE_ACCESSIBILITY_OVERLAY active-recording window (isA11yOnTop active)")
        } catch (e: Exception) {
            Log.w(TAG, "Could not attach TYPE_ACCESSIBILITY_OVERLAY: ${e.message}")
        }
    }

    private fun detachOverlayWindowIfPresent() {
        val view = overlayView ?: return
        overlayView = null
        try {
            val wm = getSystemService(WINDOW_SERVICE) as? WindowManager
            wm?.removeViewImmediate(view)
            Log.i(TAG, "Detached TYPE_ACCESSIBILITY_OVERLAY active-recording window")
        } catch (e: Exception) {
            Log.w(TAG, "Could not detach TYPE_ACCESSIBILITY_OVERLAY: ${e.message}")
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Intentionally minimal: call lifecycle detection is driven cleanly via
        // NotificationListener + CallAutoRecordCoordinator without reading window content.
    }

    override fun onInterrupt() {
        Log.w(TAG, "CallRecorderAccessibilityService interrupted")
    }

    override fun onUnbind(intent: Intent?): Boolean {
        detachOverlayWindowIfPresent()
        instance = null
        Log.w(TAG, "=== CallRecorderAccessibilityService UNBOUND ===")
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        detachOverlayWindowIfPresent()
        instance = null
        super.onDestroy()
    }
}

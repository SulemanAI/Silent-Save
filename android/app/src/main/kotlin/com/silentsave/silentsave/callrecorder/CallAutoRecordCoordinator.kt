package com.silentsave.silentsave.callrecorder

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.service.notification.StatusBarNotification
import android.util.Log
import androidx.core.content.ContextCompat
import com.silentsave.silentsave.NotificationListener

/**
 * Coordinates Option 1 automatic WhatsApp Call Recording:
 *  - **Voice calls:** Zero-tap automatic start via [CallRecorderService] (backed by
 *    [CallRecorderAccessibilityService] for Android 11–14 background microphone eligibility,
 *    with automatic 1-tap heads-up prompt fallback if Accessibility is not yet enabled).
 *  - **Video calls:** Automatic 1-tap `MediaProjection` prompt over WhatsApp via
 *    [CallRecordPromptActivity] + silent high-priority heads-up notification fallback.
 *  - **Auto-Stop (Voice & Video):** Automatically stops and finalizes the recording into
 *    `MediaStore` + SQLite (`call_recordings`) 2.5s after the WhatsApp call ends.
 *
 * Completely decoupled from chat-message archiving in [NotificationListener].
 */
object CallAutoRecordCoordinator {

    private const val TAG = "CallAutoRecord"
    private const val WHATSAPP_PKG = "com.whatsapp"
    private const val WHATSAPP_BUSINESS_PKG = "com.whatsapp.w4b"

    private const val FLUTTER_PREFS_NAME = "FlutterSharedPreferences"
    private const val KEY_AUTO_RECORD_ENABLED = "flutter.call_recorder_auto_record_enabled"
    private const val KEY_AUDIO_SOURCE = "flutter.call_recorder_audio_source"

    private const val PROMPT_CHANNEL_ID = "silentsave_call_recorder_prompt"
    const val PROMPT_NOTIFICATION_ID = 9021

    // Wait 400ms after call connects so WhatsApp switches AudioManager to MODE_IN_COMMUNICATION
    private const val START_SETTLE_DELAY_MS = 400L
    // Debounce notification updates/re-posts by 2.5s before declaring the call ended
    private const val STOP_DEBOUNCE_DELAY_MS = 2500L

    private val mainHandler = Handler(Looper.getMainLooper())
    private val activeCallKeys = LinkedHashSet<String>()

    @Volatile
    private var isWhatsAppCallConnected: Boolean = false

    @Volatile
    private var handledCurrentCall: Boolean = false

    @Volatile
    private var lastRingingMode: RecordingMode? = null

    @Volatile
    private var lastRingingTimestampMs: Long = 0L

    private var pendingStartRunnable: Runnable? = null
    private var pendingStopRunnable: Runnable? = null

    private enum class CallPhase {
        NOT_A_CALL,
        ENDED_OR_MISSED,
        RINGING_OR_DIALING,
        CONNECTED_ONGOING
    }

    private data class ParsedCallNotification(
        val phase: CallPhase,
        val mode: RecordingMode,
        val callerName: String
    )

    fun isAutoRecordEnabled(context: Context): Boolean {
        return try {
            val prefs = context.getSharedPreferences(FLUTTER_PREFS_NAME, Context.MODE_PRIVATE)
            // Default to true since Option 1 automatic call recording is enabled by default
            prefs.getBoolean(KEY_AUTO_RECORD_ENABLED, true)
        } catch (_: Exception) {
            true
        }
    }

    fun getPreferredAudioSource(context: Context): AudioSourceOption {
        return try {
            val prefs = context.getSharedPreferences(FLUTTER_PREFS_NAME, Context.MODE_PRIVATE)
            val raw = prefs.getString(KEY_AUDIO_SOURCE, null)
            if (raw.isNullOrBlank()) {
                AudioSourceOption.VOICE_RECOGNITION
            } else {
                AudioSourceOption.fromWire(raw)
            }
        } catch (_: Exception) {
            AudioSourceOption.VOICE_RECOGNITION
        }
    }

    /**
     * Called from [NotificationListener.onNotificationPosted] for WhatsApp packages BEFORE
     * the chat-archiver skips `FLAG_ONGOING_EVENT`.
     */
    fun onWhatsAppNotificationPosted(
        context: Context,
        sbn: StatusBarNotification,
        activeNotificationsProvider: () -> Array<StatusBarNotification>?
    ) {
        val pkg = sbn.packageName ?: return
        if (pkg != WHATSAPP_PKG && pkg != WHATSAPP_BUSINESS_PKG) return

        val parsed = classifyNotification(sbn)
        when (parsed.phase) {
            CallPhase.NOT_A_CALL -> return

            CallPhase.RINGING_OR_DIALING -> {
                lastRingingMode = parsed.mode
                lastRingingTimestampMs = SystemClock.elapsedRealtime()
                CallRecorderAccessibilityService.setRecordingOverlayActive(true)
                Log.d(TAG, "WhatsApp call ringing/dialing detected (mode=${parsed.mode.wireValue}, caller='${parsed.callerName}')")
            }

            CallPhase.ENDED_OR_MISSED -> {
                val appCtx = context.applicationContext
                mainHandler.post {
                    activeCallKeys.remove(sbn.key)
                    if (isWhatsAppCallConnected) {
                        scheduleDebouncedStopCheck(appCtx, activeNotificationsProvider)
                    }
                }
            }

            CallPhase.CONNECTED_ONGOING -> {
                val appCtx = context.applicationContext
                mainHandler.post {
                    // Cancel any pending call-end stop timer (e.g. if WhatsApp swapped notification IDs)
                    pendingStopRunnable?.let { mainHandler.removeCallbacks(it) }
                    pendingStopRunnable = null

                    activeCallKeys.add(sbn.key)
                    isWhatsAppCallConnected = true

                    if (CallRecorderService.isActivelyRecording || handledCurrentCall) {
                        return@post
                    }

                    if (!isAutoRecordEnabled(appCtx)) {
                        Log.d(TAG, "WhatsApp ongoing call detected, but auto-record is disabled in settings")
                        return@post
                    }

                    scheduleAutoStart(appCtx, parsed.mode, parsed.callerName)
                }
            }
        }
    }

    /**
     * Called from [NotificationListener.onNotificationRemoved] for WhatsApp packages.
     */
    fun onWhatsAppNotificationRemoved(
        context: Context,
        sbn: StatusBarNotification,
        activeNotificationsProvider: () -> Array<StatusBarNotification>?
    ) {
        val pkg = sbn.packageName ?: return
        if (pkg != WHATSAPP_PKG && pkg != WHATSAPP_BUSINESS_PKG) return

        val appCtx = context.applicationContext
        val key = sbn.key
        val parsed = classifyNotification(sbn)

        mainHandler.post {
            val wasTracked = activeCallKeys.remove(key)
            if (wasTracked || parsed.phase != CallPhase.NOT_A_CALL) {
                if (isWhatsAppCallConnected) {
                    scheduleDebouncedStopCheck(appCtx, activeNotificationsProvider)
                } else {
                    // Ringing call ended unanswered — cancel any pending start/prompt
                    cancelPendingStart()
                    cancelPromptNotification(appCtx)
                    if (!CallRecorderService.isActivelyRecording) {
                        CallRecorderAccessibilityService.setRecordingOverlayActive(false)
                    }
                }
            }
        }
    }

    /**
     * Invoked if [CallRecordPromptActivity] was cancelled by the user so we don't re-pop
     * the prompt repeatedly during the same ongoing call.
     */
    fun onPromptDismissedForCurrentCall() {
        handledCurrentCall = true
    }

    /**
     * Fallback invoked by [CallRecorderService] if Android blocked starting the `microphone`
     * foreground service from background (e.g. user hasn't enabled Accessibility Service yet).
     * Immediately posts a 1-tap heads-up banner so the call can still be recorded!
     */
    fun onBackgroundStartBlocked(
        context: Context,
        mode: RecordingMode,
        audioSource: AudioSourceOption
    ) {
        val appCtx = context.applicationContext
        mainHandler.post {
            Log.w(TAG, "Background FGS start blocked — posting 1-tap fallback notification")
            postCallPromptNotification(
                context = appCtx,
                mode = mode,
                audioSource = audioSource,
                callerName = ""
            )
        }
    }

    private fun scheduleAutoStart(
        appCtx: Context,
        mode: RecordingMode,
        callerName: String
    ) {
        if (pendingStartRunnable != null) return

        // Pre-attach the Accessibility overlay immediately so AudioPolicyService registers
        // UID 10333 as on-top (isA11yOnTop) before AudioRecord.startRecording() is invoked.
        CallRecorderAccessibilityService.setRecordingOverlayActive(true)

        val runnable = Runnable {
            pendingStartRunnable = null
            if (!isWhatsAppCallConnected || CallRecorderService.isActivelyRecording || handledCurrentCall) {
                return@Runnable
            }

            handledCurrentCall = true
            val audioSource = getPreferredAudioSource(appCtx)
            val hasMicPermission = ContextCompat.checkSelfPermission(
                appCtx,
                Manifest.permission.RECORD_AUDIO
            ) == PackageManager.PERMISSION_GRANTED
            val a11yEnabled = CallRecorderAccessibilityService.isEnabled(appCtx)

            Log.i(
                TAG,
                "Auto-triggering WhatsApp ${mode.wireValue} call recording " +
                    "(a11y=$a11yEnabled, hasMic=$hasMicPermission, source=${audioSource.wireValue})"
            )

            if (mode == RecordingMode.VOICE) {
                if (hasMicPermission && a11yEnabled) {
                    // Option 1 Zero-Tap Voice Auto-Start!
                    try {
                        CallRecorderService.startVoiceSession(
                            context = appCtx,
                            audioSource = audioSource,
                            autoStarted = true
                        )
                        return@Runnable
                    } catch (e: Exception) {
                        Log.w(TAG, "Direct background voice start threw (${e.message}) — falling back to prompt")
                    }
                }

                // Fallback if Accessibility Service or Mic permission isn't enabled yet:
                if (a11yEnabled) {
                    launchPromptActivitySafely(appCtx, RecordingMode.VOICE, audioSource, callerName)
                } else {
                    postCallPromptNotification(appCtx, RecordingMode.VOICE, audioSource, callerName)
                }
            } else {
                // Video Call mode: Android 14 requires 1-tap approval on the system MediaProjection dialog.
                // Post silent heads-up banner AND (when Accessibility is enabled) pop the transparent
                // system screen-capture prompt directly over WhatsApp!
                postCallPromptNotification(appCtx, RecordingMode.VIDEO, audioSource, callerName)
                if (a11yEnabled) {
                    launchPromptActivitySafely(appCtx, RecordingMode.VIDEO, audioSource, callerName)
                }
            }
        }

        pendingStartRunnable = runnable
        mainHandler.postDelayed(runnable, START_SETTLE_DELAY_MS)
    }

    private fun launchPromptActivitySafely(
        appCtx: Context,
        mode: RecordingMode,
        audioSource: AudioSourceOption,
        callerName: String
    ) {
        try {
            val promptIntent = CallRecordPromptActivity.createIntent(appCtx, mode, audioSource)
            appCtx.startActivity(promptIntent)
        } catch (e: Exception) {
            Log.w(TAG, "Direct prompt activity launch blocked (${e.message}) — relying on heads-up notification")
            postCallPromptNotification(appCtx, mode, audioSource, callerName)
        }
    }

    private fun scheduleDebouncedStopCheck(
        appCtx: Context,
        activeNotificationsProvider: () -> Array<StatusBarNotification>?
    ) {
        pendingStopRunnable?.let { mainHandler.removeCallbacks(it) }
        val runnable = Runnable {
            pendingStopRunnable = null

            // 1. Check Android AudioManager call mode: during an active WhatsApp call (including
            //    floating Picture-in-Picture mode), audio mode stays MODE_IN_COMMUNICATION or MODE_IN_CALL.
            val isAudioInCallMode = try {
                val am = appCtx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
                val audioMode = am?.mode ?: AudioManager.MODE_NORMAL
                audioMode == AudioManager.MODE_IN_COMMUNICATION || audioMode == AudioManager.MODE_IN_CALL
            } catch (_: Exception) {
                false
            }

            // 2. Double-check live status bar notifications in case WhatsApp posted a replacement ongoing call notification
            val stillHasOngoingCall = try {
                val activeList = activeNotificationsProvider()
                activeList?.any { sbn ->
                    val pkg = sbn.packageName
                    (pkg == WHATSAPP_PKG || pkg == WHATSAPP_BUSINESS_PKG) &&
                        classifyNotification(sbn).phase == CallPhase.CONNECTED_ONGOING
                } ?: activeCallKeys.isNotEmpty()
            } catch (_: Exception) {
                activeCallKeys.isNotEmpty()
            }

            if (stillHasOngoingCall || isAudioInCallMode) {
                Log.d(
                    TAG,
                    "Stop check: WhatsApp call still active (notif=$stillHasOngoingCall, inCommAudio=$isAudioInCallMode) — continuing recording"
                )
                if (!stillHasOngoingCall && isAudioInCallMode) {
                    // Notification was hidden/updated (e.g. PiP transition), re-check in 2.5s
                    scheduleDebouncedStopCheck(appCtx, activeNotificationsProvider)
                }
                return@Runnable
            }

            Log.i(TAG, "WhatsApp call ended — resetting state and auto-stopping active recording")
            activeCallKeys.clear()
            isWhatsAppCallConnected = false
            handledCurrentCall = false
            lastRingingMode = null
            cancelPendingStart()
            cancelPromptNotification(appCtx)

            if (CallRecorderService.isActivelyRecording) {
                CallRecorderService.requestStop(appCtx)
            } else {
                CallRecorderAccessibilityService.setRecordingOverlayActive(false)
            }
        }
        pendingStopRunnable = runnable
        mainHandler.postDelayed(runnable, STOP_DEBOUNCE_DELAY_MS)
    }

    private fun cancelPendingStart() {
        pendingStartRunnable?.let { mainHandler.removeCallbacks(it) }
        pendingStartRunnable = null
    }

    // ──────────────────────────────────────────────────────────────────────
    // WhatsApp Call Notification Classifier (Android 10–14 + CallStyle)
    // ──────────────────────────────────────────────────────────────────────

    private fun classifyNotification(sbn: StatusBarNotification): ParsedCallNotification {
        val notification = sbn.notification
            ?: return ParsedCallNotification(CallPhase.NOT_A_CALL, RecordingMode.VOICE, "")
        val extras = notification.extras
            ?: return ParsedCallNotification(CallPhase.NOT_A_CALL, RecordingMode.VOICE, "")

        val title = extras.getCharSequence("android.title")?.toString()?.trim() ?: ""
        val text = extras.getCharSequence("android.text")?.toString()?.trim() ?: ""
        val bigText = extras.getCharSequence("android.bigText")?.toString()?.trim() ?: ""
        val subText = extras.getCharSequence("android.subText")?.toString()?.trim() ?: ""
        val combinedLower = "$text $bigText $subText".lowercase()

        val isOngoingFlag = (notification.flags and Notification.FLAG_ONGOING_EVENT) != 0
        val isCategoryCall = notification.category == Notification.CATEGORY_CALL
        // Android 12+ Notification.CallStyle extras: 1 = INCOMING, 2 = ONGOING, 3 = SCREENING
        val callType = extras.getInt("android.callType", 0)
        val hasCallIsVideo = extras.containsKey("android.callIsVideo")
        val callIsVideo = extras.getBoolean("android.callIsVideo", false)
        val showChronometer = extras.getBoolean("android.showChronometer", false)

        // Exclude non-call ongoing WhatsApp notifications (backups, media transfers, WhatsApp Web)
        if (callType == 0 && !isCategoryCall) {
            if (combinedLower.contains("backup") ||
                combinedLower.contains("backing up") ||
                combinedLower.contains("restoring") ||
                combinedLower.contains("whatsapp web") ||
                combinedLower.contains("checking for new messages") ||
                combinedLower.contains("sending ") ||
                combinedLower.contains("downloading")
            ) {
                return ParsedCallNotification(CallPhase.NOT_A_CALL, RecordingMode.VOICE, title)
            }
        }

        val matchesCallText = NotificationListener.isCallNotification(text) ||
            NotificationListener.isCallNotification(bigText) ||
            combinedLower.contains("ongoing voice call") ||
            combinedLower.contains("ongoing video call") ||
            combinedLower.contains("incoming voice call") ||
            combinedLower.contains("incoming video call") ||
            combinedLower.contains("return to call") ||
            combinedLower.contains("group voice call") ||
            combinedLower.contains("group video call")

        if (callType == 0 && !isCategoryCall && !matchesCallText) {
            return ParsedCallNotification(CallPhase.NOT_A_CALL, RecordingMode.VOICE, title)
        }

        // Determine Voice vs Video mode
        val actionTitlesLower = notification.actions
            ?.mapNotNull { it.title?.toString()?.lowercase() }
            ?: emptyList()

        val resolvedMode = when {
            hasCallIsVideo -> if (callIsVideo) RecordingMode.VIDEO else RecordingMode.VOICE
            combinedLower.contains("video") || title.lowercase().contains("video") -> RecordingMode.VIDEO
            actionTitlesLower.any { it.contains("video") && it.contains("answer") } -> RecordingMode.VIDEO
            combinedLower.contains("voice") || combinedLower.contains("audio") -> RecordingMode.VOICE
            lastRingingMode != null && (SystemClock.elapsedRealtime() - lastRingingTimestampMs) < 90_000L ->
                lastRingingMode!!
            else -> RecordingMode.VOICE
        }

        // Non-ongoing call notifications are Missed / Ended call alerts
        if (!isOngoingFlag) {
            return ParsedCallNotification(CallPhase.ENDED_OR_MISSED, resolvedMode, title)
        }

        // Distinguish Ringing / Dialing vs Connected Ongoing call
        val hasIncomingAnswerAction = actionTitlesLower.any {
            it.contains("answer") || it.contains("accept") || it.contains("decline") || it.contains("reject")
        }
        val isRingingOrDialingText = combinedLower.contains("incoming") ||
            combinedLower.contains("ringing") ||
            combinedLower.contains("calling")

        if (callType == 1 || hasIncomingAnswerAction || (isRingingOrDialingText && !showChronometer)) {
            return ParsedCallNotification(CallPhase.RINGING_OR_DIALING, resolvedMode, title)
        }

        return ParsedCallNotification(CallPhase.CONNECTED_ONGOING, resolvedMode, title)
    }

    // ──────────────────────────────────────────────────────────────────────
    // Silent High-Priority Prompt Notification (Video 1-Tap & Voice Fallback)
    // ──────────────────────────────────────────────────────────────────────

    private fun ensurePromptChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // IMPORTANCE_HIGH shows a heads-up banner over WhatsApp, while null sound + disabled
            // vibration prevents any notification chime from bleeding into the call audio!
            val channel = NotificationChannel(
                PROMPT_CHANNEL_ID,
                "Call Recording Prompts",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Instant 1-tap prompt when a WhatsApp video call starts"
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
            }
            context.getSystemService(NotificationManager::class.java)
                ?.createNotificationChannel(channel)
        }
    }

    private fun postCallPromptNotification(
        context: Context,
        mode: RecordingMode,
        audioSource: AudioSourceOption,
        callerName: String
    ) {
        ensurePromptChannel(context)

        val promptIntent = CallRecordPromptActivity.createIntent(context, mode, audioSource)
        val promptPi = PendingIntent.getActivity(
            context,
            210,
            promptIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val callerSuffix = if (callerName.isNotBlank() && !callerName.equals("WhatsApp", ignoreCase = true)) {
            " with $callerName"
        } else {
            ""
        }

        val notifTitle = if (mode == RecordingMode.VIDEO) {
            "WhatsApp Video Call$callerSuffix"
        } else {
            "WhatsApp Voice Call$callerSuffix"
        }

        val notifBody = if (mode == RecordingMode.VIDEO) {
            "Tap to approve screen + audio recording (auto-stops when call ends)"
        } else {
            "Tap to start recording (enable Accessibility in SilentSave for 0-tap auto-start)"
        }

        val notification = Notification.Builder(context, PROMPT_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle(notifTitle)
            .setContentText(notifBody)
            .setContentIntent(promptPi)
            .setFullScreenIntent(promptPi, true)
            .setAutoCancel(true)
            .setOngoing(false)
            .setCategory(Notification.CATEGORY_CALL)
            .addAction(
                Notification.Action.Builder(
                    null,
                    "🔴 Record Call",
                    promptPi
                ).build()
            )
            .build()

        try {
            context.getSystemService(NotificationManager::class.java)
                ?.notify(PROMPT_NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            Log.w(TAG, "Could not post call prompt notification: ${e.message}")
        }
    }

    fun cancelPromptNotification(context: Context) {
        try {
            context.getSystemService(NotificationManager::class.java)
                ?.cancel(PROMPT_NOTIFICATION_ID)
        } catch (_: Exception) {}
    }
}


package com.silentsave.silentsave.callrecorder

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.content.ContextCompat
import com.silentsave.silentsave.MainActivity
import java.io.File
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.Executors

/**
 * In-process event broadcaster connecting [CallRecorderService] to [CallRecorderChannelHandler]
 * (and therefore Flutter's `EventChannel("com.silentsave/call_recorder_events")`).
 * Retains [latestEvent] so reconnecting Flutter UI gets an immediate state snapshot.
 */
object CallRecorderEventBus {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val listeners = CopyOnWriteArraySet<(RecorderEvent) -> Unit>()

    @Volatile
    var latestEvent: RecorderEvent = RecorderEvent(state = RecorderState.IDLE)
        private set

    fun emit(event: RecorderEvent) {
        latestEvent = event
        mainHandler.post {
            for (listener in listeners) {
                try {
                    listener(event)
                } catch (_: Exception) {}
            }
        }
    }

    fun addListener(listener: (RecorderEvent) -> Unit) {
        listeners.add(listener)
    }

    fun removeListener(listener: (RecorderEvent) -> Unit) {
        listeners.remove(listener)
    }
}

/**
 * Foreground service executing WhatsApp video call (`MediaProjection` + mic -> MP4)
 * or voice call (mic-only -> M4A/AAC) recording.
 *
 * Android 10–14 compliance:
 *  - Dynamically passes `FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION` (video) and/or
 *    `FOREGROUND_SERVICE_TYPE_MICROPHONE` (voice/video, API 30+) to `startForeground()`
 *    BEFORE calling `MediaProjectionManager.getMediaProjection()`.
 *  - Registers `MediaProjection.Callback` BEFORE `createVirtualDisplay()` (mandatory on API 34).
 *  - Never caches or reuses `MediaProjection` consent intents/tokens across sessions.
 *  - Gracefully finalizes and saves partial recordings on `MediaProjection` revocation,
 *    low storage, or service destruction.
 */
class CallRecorderService : Service() {

    companion object {
        private const val TAG = "CallRecorderService"
        private const val CHANNEL_ID = "silentsave_call_recorder"
        private const val NOTIFICATION_ID = 9020

        const val ACTION_START_RECORDING = "com.silentsave.callrecorder.START_RECORDING"
        const val ACTION_STOP_RECORDING = "com.silentsave.callrecorder.STOP_RECORDING"

        const val EXTRA_MODE = "extra_mode"
        const val EXTRA_AUDIO_SOURCE = "extra_audio_source"
        const val EXTRA_RESULT_CODE = "extra_projection_result_code"
        const val EXTRA_RESULT_DATA = "extra_projection_result_data"
        const val EXTRA_AUTO_STARTED = "extra_auto_started"

        @Volatile
        var isActivelyRecording: Boolean = false
            private set

        @Volatile
        var activeMode: RecordingMode? = null
            private set

        @Volatile
        var activeAudioSource: AudioSourceOption? = null
            private set

        @Volatile
        var activeFileName: String? = null
            private set

        @Volatile
        private var startElapsedRealtimeMs: Long = 0L

        fun currentElapsedMs(): Long {
            if (!isActivelyRecording || startElapsedRealtimeMs <= 0L) return 0L
            return (SystemClock.elapsedRealtime() - startElapsedRealtimeMs).coerceAtLeast(0L)
        }

        fun startVoiceSession(
            context: Context,
            audioSource: AudioSourceOption,
            autoStarted: Boolean = false
        ) {
            val intent = Intent(context, CallRecorderService::class.java).apply {
                action = ACTION_START_RECORDING
                putExtra(EXTRA_MODE, RecordingMode.VOICE.wireValue)
                putExtra(EXTRA_AUDIO_SOURCE, audioSource.wireValue)
                putExtra(EXTRA_AUTO_STARTED, autoStarted)
            }
            ContextCompat.startForegroundService(context, intent)
        }

        fun startVideoSession(
            context: Context,
            audioSource: AudioSourceOption,
            projectionResultCode: Int,
            projectionData: Intent,
            autoStarted: Boolean = false
        ) {
            val intent = Intent(context, CallRecorderService::class.java).apply {
                action = ACTION_START_RECORDING
                putExtra(EXTRA_MODE, RecordingMode.VIDEO.wireValue)
                putExtra(EXTRA_AUDIO_SOURCE, audioSource.wireValue)
                putExtra(EXTRA_RESULT_CODE, projectionResultCode)
                putExtra(EXTRA_RESULT_DATA, projectionData)
                putExtra(EXTRA_AUTO_STARTED, autoStarted)
            }
            ContextCompat.startForegroundService(context, intent)
        }

        fun requestStop(context: Context) {
            if (!isActivelyRecording) return
            val intent = Intent(context, CallRecorderService::class.java).apply {
                action = ACTION_STOP_RECORDING
            }
            context.startService(intent)
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val ioExecutor = Executors.newSingleThreadExecutor()

    private lateinit var repository: CallRecordingRepository
    private var engine: CallMediaRecorderEngine? = null
    private var activeProjection: MediaProjection? = null

    private var stagingFile: File? = null
    private var startedWallClockMs: Long = 0L
    private var isStopping: Boolean = false

    // Silent-mic detection state
    private var consecutiveSilentTicks: Int = 0
    private var currentWarningMessage: String? = null
    private var tickCount: Int = 0

    // WakeLock renewed periodically while recording
    private var wakeLock: PowerManager.WakeLock? = null

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            Log.w(TAG, "MediaProjection.Callback.onStop() invoked")
            if (isActivelyRecording && !isStopping) {
                finalizeSessionAsync(
                    stopProjection = false,
                    isPartial = true,
                    errorCode = RecorderErrorCodes.PROJECTION_REVOKED,
                    errorMessage = "Screen capture stopped or permission was revoked. Your partial recording has been saved."
                )
            }
        }
    }

    private val tickRunnable = object : Runnable {
        override fun run() {
            if (!isActivelyRecording || isStopping) return

            tickCount++
            val elapsedMs = currentElapsedMs()

            // Renew bounded WakeLock every 180 seconds
            if (tickCount % 180 == 0) {
                acquireBoundedWakeLock()
        CallRecorderAccessibilityService.setRecordingOverlayActive(true)
            }

            // Check critical storage every 5 seconds
            if (tickCount % 5 == 0 && repository.isStorageCriticallyLow()) {
                Log.w(TAG, "Critically low storage detected — auto-finalizing recording")
                finalizeSessionAsync(
                    stopProjection = true,
                    isPartial = true,
                    errorCode = RecorderErrorCodes.LOW_STORAGE,
                    errorMessage = "Device storage is critically low (<25 MB). Recording was stopped and saved safely."
                )
                return
            }

            // Detect prolonged 0-amplitude microphone stream (common when VoIP holds mic exclusively)
            val amp = engine?.pollMaxAmplitude() ?: 0
            if (tickCount > 2) {
                if (amp <= 5) {
                    consecutiveSilentTicks++
                    if (consecutiveSilentTicks >= 8 && currentWarningMessage == null) {
                        currentWarningMessage =
                            "No microphone signal detected yet. If a call is active, Android/OEM policy may be muting concurrent mic access — try enabling Speakerphone or switching Audio Source in Settings."
                    }
                } else {
                    consecutiveSilentTicks = 0
                    currentWarningMessage = null
                }
            }

            CallRecorderEventBus.emit(
                RecorderEvent(
                    state = RecorderState.RECORDING,
                    mode = activeMode,
                    audioSource = activeAudioSource,
                    elapsedMs = elapsedMs,
                    fileName = activeFileName,
                    warningMessage = currentWarningMessage
                )
            )

            mainHandler.postDelayed(this, 1000L)
        }
    }

    override fun onCreate() {
        super.onCreate()
        repository = CallRecordingRepository.getInstance(applicationContext)
        createNotificationChannel()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        Log.i(TAG, "onStartCommand action=$action isActivelyRecording=$isActivelyRecording")

        when (action) {
            ACTION_START_RECORDING -> {
                if (isActivelyRecording || isStopping) {
                    Log.w(TAG, "Ignoring START_RECORDING: session already active/stopping")
                    return START_NOT_STICKY
                }
                handleStartRecording(intent)
            }
            ACTION_STOP_RECORDING -> {
                if (isActivelyRecording && !isStopping) {
                    finalizeSessionAsync(
                        stopProjection = true,
                        isPartial = false,
                        errorCode = null,
                        errorMessage = null
                    )
                } else {
                    stopSelf()
                }
            }
            else -> {
                if (!isActivelyRecording) {
                    stopSelf()
                }
            }
        }

        // START_NOT_STICKY: MediaProjection tokens cannot be resurrected after process death;
        // startup recovery handles any interrupted staging file cleanly instead.
        return START_NOT_STICKY
    }

    private fun handleStartRecording(intent: Intent) {
        val mode = RecordingMode.fromWire(intent.getStringExtra(EXTRA_MODE))
        val audioSource = AudioSourceOption.fromWire(intent.getStringExtra(EXTRA_AUDIO_SOURCE))
        val autoStarted = intent.getBooleanExtra(EXTRA_AUTO_STARTED, false)

        CallAutoRecordCoordinator.cancelPromptNotification(applicationContext)

        val nowWallMs = System.currentTimeMillis()
        val targetStagingFile = repository.createStagingFile(mode, nowWallMs)

        // 1. Promote to foreground IMMEDIATELY with the exact mode-specific service type.
        //    Mandatory on Android 14 BEFORE obtaining a MediaProjection instance.
        val promoted = promoteToForeground(mode, targetStagingFile.name, nowWallMs)
        if (!promoted) {
            if (autoStarted) {
                CallAutoRecordCoordinator.onBackgroundStartBlocked(
                    applicationContext,
                    mode,
                    audioSource
                )
            }
            CallRecorderEventBus.emit(
                RecorderEvent(
                    state = RecorderState.ERROR,
                    mode = mode,
                    audioSource = audioSource,
                    errorCode = RecorderErrorCodes.PERMISSION_DENIED,
                    errorMessage = "Android blocked starting the foreground recording service. Ensure microphone permission is granted while SilentSave is open."
                )
            )
            stopSelf()
            return
        }

        // 2. Check available disk space
        if (!repository.hasEnoughStorageToStart()) {
            CallRecorderEventBus.emit(
                RecorderEvent(
                    state = RecorderState.ERROR,
                    mode = mode,
                    audioSource = audioSource,
                    errorCode = RecorderErrorCodes.LOW_STORAGE,
                    errorMessage = "Insufficient free storage (<50 MB available). Free up space and try again."
                )
            )
            stopForegroundAndSelf()
            return
        }

        CallRecorderEventBus.emit(
            RecorderEvent(
                state = RecorderState.PREPARING,
                mode = mode,
                audioSource = audioSource,
                elapsedMs = 0L,
                fileName = targetStagingFile.name
            )
        )

        acquireBoundedWakeLock()
        CallRecorderAccessibilityService.setRecordingOverlayActive(true)

        val recorderEngine = CallMediaRecorderEngine(applicationContext) { errCode, errMsg ->
            if (isActivelyRecording && !isStopping) {
                finalizeSessionAsync(
                    stopProjection = true,
                    isPartial = true,
                    errorCode = errCode,
                    errorMessage = errMsg
                )
            }
        }
        engine = recorderEngine

        try {
            if (mode == RecordingMode.VIDEO) {
                val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
                val resultData: Intent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(EXTRA_RESULT_DATA)
                }

                if (resultData == null) {
                    throw RecorderEngineException(
                        RecorderErrorCodes.PROJECTION_DENIED,
                        "Screen capture permission data was missing. Please grant screen capture access."
                    )
                }

                val projManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                val projection = projManager.getMediaProjection(resultCode, resultData)
                    ?: throw RecorderEngineException(
                        RecorderErrorCodes.PROJECTION_DENIED,
                        "Android refused MediaProjection token. Please re-approve screen capture."
                    )

                // Mandatory on Android 14 (API 34): register callback BEFORE createVirtualDisplay
                projection.registerCallback(projectionCallback, mainHandler)
                activeProjection = projection

                recorderEngine.startVideoRecording(
                    outputFile = targetStagingFile,
                    audioSource = audioSource,
                    projection = projection
                )
            } else {
                recorderEngine.startVoiceRecording(
                    outputFile = targetStagingFile,
                    audioSource = audioSource
                )
            }

            // Mark session active in memory + crash-recovery SharedPreferences
            stagingFile = targetStagingFile
            startedWallClockMs = nowWallMs
            startElapsedRealtimeMs = SystemClock.elapsedRealtime()
            activeMode = mode
            activeAudioSource = audioSource
            activeFileName = targetStagingFile.name
            isActivelyRecording = true
            isStopping = false
            consecutiveSilentTicks = 0
            currentWarningMessage = null
            tickCount = 0

            repository.markActiveSession(targetStagingFile, mode, audioSource, nowWallMs)

            CallRecorderEventBus.emit(
                RecorderEvent(
                    state = RecorderState.RECORDING,
                    mode = mode,
                    audioSource = audioSource,
                    elapsedMs = 0L,
                    fileName = targetStagingFile.name
                )
            )

            mainHandler.postDelayed(tickRunnable, 1000L)
            Log.i(TAG, "✓ Call recording session active: ${targetStagingFile.name}")
        } catch (e: RecorderEngineException) {
            Log.e(TAG, "RecorderEngineException on start (${e.errorCode}): ${e.message}")
            cleanupFailedStart(targetStagingFile)
            CallRecorderEventBus.emit(
                RecorderEvent(
                    state = RecorderState.ERROR,
                    mode = mode,
                    audioSource = audioSource,
                    errorCode = e.errorCode,
                    errorMessage = e.message
                )
            )
            stopForegroundAndSelf()
        } catch (e: Exception) {
            Log.e(TAG, "Unexpected start error: ${e.message}", e)
            cleanupFailedStart(targetStagingFile)
            CallRecorderEventBus.emit(
                RecorderEvent(
                    state = RecorderState.ERROR,
                    mode = mode,
                    audioSource = audioSource,
                    errorCode = RecorderErrorCodes.RECORDER_ERROR,
                    errorMessage = "Could not start recording: ${e.message ?: "unknown error"}"
                )
            )
            stopForegroundAndSelf()
        }
    }

    private fun cleanupFailedStart(file: File) {
        try {
            activeProjection?.unregisterCallback(projectionCallback)
        } catch (_: Exception) {}
        activeProjection = null
        engine?.stopAndRelease(stopProjection = true)
        engine = null
        try { if (file.exists()) file.delete() } catch (_: Exception) {}
        repository.clearActiveSession()
        CallRecorderAccessibilityService.setRecordingOverlayActive(false)
        releaseWakeLock()
    }

    /**
     * Asynchronously stops the [CallMediaRecorderEngine], publishes the finalized file
     * to `MediaStore` + SQLite, emits the final [RecorderEvent], and stops the service.
     */
    @Synchronized
    private fun finalizeSessionAsync(
        stopProjection: Boolean,
        isPartial: Boolean,
        errorCode: String?,
        errorMessage: String?
    ) {
        if (isStopping) return
        isStopping = true
        mainHandler.removeCallbacks(tickRunnable)

        val modeSnapshot = activeMode ?: RecordingMode.VOICE
        val sourceSnapshot = activeAudioSource ?: AudioSourceOption.MIC
        val fileSnapshot = stagingFile
        val startedMsSnapshot = startedWallClockMs
        val elapsedSnapshot = currentElapsedMs()

        CallRecorderEventBus.emit(
            RecorderEvent(
                state = RecorderState.STOPPING,
                mode = modeSnapshot,
                audioSource = sourceSnapshot,
                elapsedMs = elapsedSnapshot,
                fileName = fileSnapshot?.name
            )
        )

        ioExecutor.execute {
            try {
                try {
                    activeProjection?.unregisterCallback(projectionCallback)
                } catch (_: Exception) {}
                activeProjection = null

                engine?.stopAndRelease(stopProjection = stopProjection)
                engine = null

                val savedEntity = if (fileSnapshot != null && fileSnapshot.exists() && fileSnapshot.length() > 0L) {
                    repository.publishStagingFileToMediaStore(
                        stagingFile = fileSnapshot,
                        mode = modeSnapshot,
                        audioSource = sourceSnapshot,
                        startedAtMs = startedMsSnapshot,
                        fallbackDurationMs = elapsedSnapshot,
                        isPartial = isPartial
                    )
                } else {
                    repository.clearActiveSession()
                    null
                }

                resetStateFlags()
                releaseWakeLock()

                if (errorCode != null) {
                    CallRecorderEventBus.emit(
                        RecorderEvent(
                            state = RecorderState.ERROR,
                            mode = modeSnapshot,
                            audioSource = sourceSnapshot,
                            elapsedMs = elapsedSnapshot,
                            recording = savedEntity,
                            errorCode = errorCode,
                            errorMessage = errorMessage
                        )
                    )
                } else if (savedEntity != null) {
                    CallRecorderEventBus.emit(
                        RecorderEvent(
                            state = RecorderState.COMPLETED,
                            mode = modeSnapshot,
                            audioSource = sourceSnapshot,
                            elapsedMs = savedEntity.durationMs,
                            fileName = savedEntity.displayName,
                            recording = savedEntity
                        )
                    )
                } else {
                    CallRecorderEventBus.emit(
                        RecorderEvent(
                            state = RecorderState.ERROR,
                            mode = modeSnapshot,
                            audioSource = sourceSnapshot,
                            errorCode = RecorderErrorCodes.RECORDER_ERROR,
                            errorMessage = "Recording was too short or produced an empty file."
                        )
                    )
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error finalizing recording: ${e.message}", e)
                resetStateFlags()
                releaseWakeLock()
                CallRecorderEventBus.emit(
                    RecorderEvent(
                        state = RecorderState.ERROR,
                        mode = modeSnapshot,
                        audioSource = sourceSnapshot,
                        errorCode = RecorderErrorCodes.RECORDER_ERROR,
                        errorMessage = "Error saving recording: ${e.message}"
                    )
                )
            } finally {
                mainHandler.post { stopForegroundAndSelf() }
            }
        }
    }

    /**
     * Last-resort synchronous safeguard if the OS or OEM battery manager destroys the service
     * while a call recording is still active. Flushes the MP4/M4A `moov` header and saves the
     * partial file to `MediaStore` + SQLite before process tear-down completes.
     */
    override fun onDestroy() {
        mainHandler.removeCallbacks(tickRunnable)
        if (isActivelyRecording && !isStopping) {
            Log.w(TAG, "onDestroy called while recording! Finalizing partial file synchronously...")
            isStopping = true
            try {
                try { activeProjection?.unregisterCallback(projectionCallback) } catch (_: Exception) {}
                activeProjection = null

                val modeSnapshot = activeMode ?: RecordingMode.VOICE
                val sourceSnapshot = activeAudioSource ?: AudioSourceOption.MIC
                val fileSnapshot = stagingFile
                val elapsedSnapshot = currentElapsedMs()

                engine?.stopAndRelease(stopProjection = true)
                engine = null

                val saved = if (fileSnapshot != null && fileSnapshot.exists() && fileSnapshot.length() > 0L) {
                    repository.publishStagingFileToMediaStore(
                        stagingFile = fileSnapshot,
                        mode = modeSnapshot,
                        audioSource = sourceSnapshot,
                        startedAtMs = startedWallClockMs,
                        fallbackDurationMs = elapsedSnapshot,
                        isPartial = true
                    )
                } else null

                CallRecorderEventBus.emit(
                    RecorderEvent(
                        state = RecorderState.ERROR,
                        mode = modeSnapshot,
                        audioSource = sourceSnapshot,
                        recording = saved,
                        errorCode = RecorderErrorCodes.SERVICE_KILLED,
                        errorMessage = "Recording service was stopped by the system. Partial recording saved."
                    )
                )
            } catch (e: Exception) {
                Log.e(TAG, "Emergency onDestroy finalize failed: ${e.message}")
            } finally {
                resetStateFlags()
            }
        }
        releaseWakeLock()
        ioExecutor.shutdown()
        super.onDestroy()
    }

    private fun resetStateFlags() {
        CallRecorderAccessibilityService.setRecordingOverlayActive(false)
        isActivelyRecording = false
        isStopping = false
        activeMode = null
        activeAudioSource = null
        activeFileName = null
        stagingFile = null
        startElapsedRealtimeMs = 0L
    }

    private fun promoteToForeground(
        mode: RecordingMode,
        fileName: String,
        startedWallMs: Long
    ): Boolean {
        val notification = buildRecordingNotification(mode, fileName, startedWallMs)
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                // API 30–34+: both MEDIA_PROJECTION and MICROPHONE FGS types exist
                val serviceType = if (mode == RecordingMode.VIDEO) {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION or
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                } else {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                }
                startForeground(NOTIFICATION_ID, notification, serviceType)
            } else {
                // API 29 (Android 10): MEDIA_PROJECTION exists; MICROPHONE FGS type was added in API 30
                if (mode == RecordingMode.VIDEO) {
                    startForeground(
                        NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                    )
                } else {
                    startForeground(NOTIFICATION_ID, notification)
                }
            }
            true
        } catch (e: Exception) {
            Log.e(TAG, "promoteToForeground failed (mode=${mode.wireValue}): ${e.message}", e)
            false
        }
    }

    private fun stopForegroundAndSelf() {
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (_: Exception) {}
        stopSelf()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // IMPORTANCE_LOW guarantees persistent visibility + Stop button without emitting
            // an alert chime that would bleed into the call recording's microphone stream.
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Call Recorder",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Active WhatsApp voice/video call recording status and Stop control"
                setShowBadge(false)
                setSound(null, null)
                enableVibration(false)
            }
            getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
        }
    }

    private fun buildRecordingNotification(
        mode: RecordingMode,
        fileName: String,
        startedWallMs: Long
    ): Notification {
        val openAppIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val openAppPi = PendingIntent.getActivity(
            this,
            200,
            openAppIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val stopIntent = Intent(this, CallRecorderService::class.java).apply {
            action = ACTION_STOP_RECORDING
        }
        val stopPi = PendingIntent.getService(
            this,
            201,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val title = if (mode == RecordingMode.VIDEO) {
            "Recording Video Call (Screen + Mic)"
        } else {
            "Recording Voice Call (Mic)"
        }

        val builder = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(fileName)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentIntent(openAppPi)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setWhen(startedWallMs)
            .setShowWhen(true)
            .setUsesChronometer(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .addAction(
                Notification.Action.Builder(
                    null,
                    "⏹ Stop Recording",
                    stopPi
                ).build()
            )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }

        return builder.build()
    }

    private fun acquireBoundedWakeLock() {
        try {
            if (wakeLock == null) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "SilentSave::CallRecorderWakeLock"
                ).apply {
                    setReferenceCounted(false)
                }
            }
            wakeLock?.acquire(5 * 60 * 1000L) // Renewed every 3 min while recording
        } catch (e: Exception) {
            Log.w(TAG, "WakeLock acquire warning: ${e.message}")
        }
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {}
        wakeLock = null
    }
}


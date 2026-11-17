package com.silentsave.silentsave.callrecorder

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Platform-channel bridge between Flutter and the native Call Recorder module.
 *
 * Channels:
 *  - `MethodChannel("com.silentsave/call_recorder")`: commands (start, stop, list, rename, delete, state, readable path)
 *  - `EventChannel("com.silentsave/call_recorder_events")`: live stream of recording state, elapsed time, warnings & errors
 */
class CallRecorderChannelHandler(private val activity: Activity) :
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    companion object {
        private const val TAG = "CallRecChannel"
        const val METHOD_CHANNEL_NAME = "com.silentsave/call_recorder"
        const val EVENT_CHANNEL_NAME = "com.silentsave/call_recorder_events"
        const val MEDIA_PROJECTION_REQUEST_CODE = 2002
    }

    private val appContext: Context = activity.applicationContext
    private val repository: CallRecordingRepository = CallRecordingRepository.getInstance(appContext)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val bgExecutor = Executors.newSingleThreadExecutor()

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null

    // Pending single-session MediaProjection consent request (re-requested every session per Android 14 rules)
    private var pendingProjectionResult: MethodChannel.Result? = null
    private var pendingProjectionAudioSource: AudioSourceOption = AudioSourceOption.MIC

    private val busListener: (RecorderEvent) -> Unit = { event ->
        eventSink?.success(event.toMap())
    }

    fun register(flutterEngine: FlutterEngine) {
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        methodChannel = MethodChannel(messenger, METHOD_CHANNEL_NAME).also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(messenger, EVENT_CHANNEL_NAME).also {
            it.setStreamHandler(this)
        }

        // Proactively recover any partial staging file left by an earlier process kill
        bgExecutor.execute {
            try {
                repository.recoverInterruptedRecordings()
            } catch (e: Exception) {
                Log.w(TAG, "Startup recovery check warning: ${e.message}")
            }
        }
    }

    fun dispose() {
        CallRecorderEventBus.removeListener(busListener)
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        methodChannel = null
        eventChannel = null
        eventSink = null
        bgExecutor.shutdown()
    }

    // ──────────────────────────────────────────────────────────────────────
    // EventChannel.StreamHandler
    // ──────────────────────────────────────────────────────────────────────

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        CallRecorderEventBus.addListener(busListener)
        // Immediately push current snapshot so UI syncs if service is already recording
        if (CallRecorderService.isActivelyRecording) {
            events?.success(
                RecorderEvent(
                    state = RecorderState.RECORDING,
                    mode = CallRecorderService.activeMode,
                    audioSource = CallRecorderService.activeAudioSource,
                    elapsedMs = CallRecorderService.currentElapsedMs(),
                    fileName = CallRecorderService.activeFileName
                ).toMap()
            )
        } else {
            events?.success(RecorderEvent(state = RecorderState.IDLE).toMap())
        }
    }

    override fun onCancel(arguments: Any?) {
        CallRecorderEventBus.removeListener(busListener)
        eventSink = null
    }

    // ──────────────────────────────────────────────────────────────────────
    // MethodChannel.MethodCallHandler
    // ──────────────────────────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startRecording" -> handleStartRecording(call, result)

            "stopRecording" -> {
                CallRecorderService.requestStop(appContext)
                result.success(true)
            }

            "getRecordingState" -> {
                val active = CallRecorderService.isActivelyRecording
                result.success(
                    mapOf(
                        "isRecording" to active,
                        "state" to if (active) RecorderState.RECORDING.wireValue else RecorderState.IDLE.wireValue,
                        "mode" to CallRecorderService.activeMode?.wireValue,
                        "audioSource" to CallRecorderService.activeAudioSource?.wireValue,
                        "elapsedMs" to CallRecorderService.currentElapsedMs(),
                        "fileName" to CallRecorderService.activeFileName
                    )
                )
            }

            "listRecordings" -> {
                val sync = call.argument<Boolean>("syncWithMediaStore") ?: true
                bgExecutor.execute {
                    try {
                        val list = if (sync) {
                            repository.syncAndListRecordings()
                        } else {
                            com.silentsave.silentsave.NativeDatabaseHelper
                                .getInstance(appContext)
                                .getAllCallRecordings()
                        }
                        val payload = list.map { it.toMap() }
                        mainHandler.post { result.success(payload) }
                    } catch (e: Exception) {
                        Log.e(TAG, "listRecordings error: ${e.message}", e)
                        mainHandler.post {
                            result.error(RecorderErrorCodes.RECORDER_ERROR, e.message, null)
                        }
                    }
                }
            }

            "renameRecording" -> {
                val idNum = call.argument<Number>("id")
                val newName = call.argument<String>("newDisplayName")
                if (idNum == null || newName.isNullOrBlank()) {
                    result.error("INVALID_ARGS", "Both 'id' and 'newDisplayName' are required", null)
                    return
                }
                bgExecutor.execute {
                    try {
                        val updated = repository.renameRecording(idNum.toLong(), newName)
                        mainHandler.post { result.success(updated.toMap()) }
                    } catch (e: Exception) {
                        Log.e(TAG, "renameRecording error: ${e.message}", e)
                        mainHandler.post {
                            result.error(RecorderErrorCodes.RENAME_FAILED, e.message, null)
                        }
                    }
                }
            }

            "deleteRecording" -> {
                val idNum = call.argument<Number>("id")
                if (idNum == null) {
                    result.error("INVALID_ARGS", "'id' is required", null)
                    return
                }
                bgExecutor.execute {
                    try {
                        val deleted = repository.deleteRecording(idNum.toLong())
                        mainHandler.post { result.success(deleted) }
                    } catch (e: Exception) {
                        Log.e(TAG, "deleteRecording error: ${e.message}", e)
                        mainHandler.post {
                            result.error(RecorderErrorCodes.DELETE_FAILED, e.message, null)
                        }
                    }
                }
            }

            "getReadablePath" -> {
                val idNum = call.argument<Number>("id")
                if (idNum == null) {
                    result.error("INVALID_ARGS", "'id' is required", null)
                    return
                }
                bgExecutor.execute {
                    try {
                        val path = repository.resolveReadableFilePath(idNum.toLong())
                        mainHandler.post { result.success(path) }
                    } catch (e: Exception) {
                        Log.e(TAG, "getReadablePath error: ${e.message}", e)
                        mainHandler.post {
                            result.error(RecorderErrorCodes.NOT_FOUND, e.message, null)
                        }
                    }
                }
            }

            "getStorageInfo" -> {
                result.success(
                    mapOf(
                        "availableBytes" to repository.getAvailableStorageBytes(),
                        "minStartBytes" to CallRecordingRepository.MIN_START_STORAGE_BYTES
                    )
                )
            }

            "isAccessibilityServiceEnabled" -> {
                result.success(CallRecorderAccessibilityService.isEnabled(appContext))
            }

            "openAccessibilitySettings" -> {
                CallRecorderAccessibilityService.openAccessibilitySettings(activity)
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    private fun handleStartRecording(call: MethodCall, result: MethodChannel.Result) {
        if (CallRecorderService.isActivelyRecording) {
            result.success(true)
            return
        }

        val mode = RecordingMode.fromWire(call.argument<String>("mode"))
        val audioSource = AudioSourceOption.fromWire(call.argument<String>("audioSource"))

        // Verify RECORD_AUDIO permission
        val hasMic = ContextCompat.checkSelfPermission(
            activity,
            Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
        if (!hasMic) {
            result.error(
                RecorderErrorCodes.PERMISSION_DENIED,
                "Microphone permission is required to record calls.",
                null
            )
            return
        }

        // Verify free storage before prompting or starting service
        if (!repository.hasEnoughStorageToStart()) {
            result.error(
                RecorderErrorCodes.LOW_STORAGE,
                "Low storage (<50 MB available). Free up space before recording.",
                null
            )
            return
        }

        if (mode == RecordingMode.VOICE) {
            CallRecorderService.startVoiceSession(appContext, audioSource)
            result.success(true)
            return
        }

        // Video mode: Android 14 requires requesting a fresh MediaProjection consent token EVERY session
        if (pendingProjectionResult != null) {
            result.error("BUSY", "Screen capture prompt is already open.", null)
            return
        }

        try {
            val projManager = activity.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            val captureIntent = projManager.createScreenCaptureIntent()
            pendingProjectionResult = result
            pendingProjectionAudioSource = audioSource
            activity.startActivityForResult(captureIntent, MEDIA_PROJECTION_REQUEST_CODE)
        } catch (e: Exception) {
            pendingProjectionResult = null
            Log.e(TAG, "Failed to launch screen capture prompt: ${e.message}", e)
            result.error(
                RecorderErrorCodes.RECORDER_ERROR,
                "Unable to open Android screen capture prompt: ${e.message}",
                null
            )
        }
    }

    /**
     * Invoked from [MainActivity.onActivityResult]. Returns `true` if handled.
     */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != MEDIA_PROJECTION_REQUEST_CODE) return false

        val callbackResult = pendingProjectionResult
        val audioSource = pendingProjectionAudioSource
        pendingProjectionResult = null

        if (resultCode == Activity.RESULT_OK && data != null) {
            Log.i(TAG, "MediaProjection consent granted — starting CallRecorderService")
            CallRecorderService.startVideoSession(
                context = appContext,
                audioSource = audioSource,
                projectionResultCode = resultCode,
                projectionData = data
            )
            callbackResult?.success(true)
        } else {
            Log.w(TAG, "MediaProjection consent denied/cancelled (resultCode=$resultCode)")
            CallRecorderEventBus.emit(
                RecorderEvent(
                    state = RecorderState.ERROR,
                    mode = RecordingMode.VIDEO,
                    audioSource = audioSource,
                    errorCode = RecorderErrorCodes.PROJECTION_DENIED,
                    errorMessage = "Screen capture permission was not granted."
                )
            )
            callbackResult?.error(
                RecorderErrorCodes.PROJECTION_DENIED,
                "Screen capture permission was not granted.",
                null
            )
        }
        return true
    }
}


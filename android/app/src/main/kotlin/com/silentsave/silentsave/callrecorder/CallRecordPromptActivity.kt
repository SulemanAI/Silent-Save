package com.silentsave.silentsave.callrecorder

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat

/**
 * Invisible zero-chrome trampoline [Activity] launched over WhatsApp when:
 *  1. A WhatsApp **Video Call** connects — immediately opens Android's mandatory per-session
 *     `MediaProjection` confirmation dialog (*"Start recording or casting?"*) with 1 tap, then
 *     vanishes (`finish()`) so the user never leaves their WhatsApp video call.
 *  2. A WhatsApp **Voice Call** fallback notification is tapped (e.g. if Accessibility wasn't
 *     enabled yet or `RECORD_AUDIO` runtime permission still needed approval).
 */
class CallRecordPromptActivity : Activity() {

    companion object {
        private const val TAG = "CallPromptAct"
        private const val REQ_MIC_PERMISSION = 3101
        private const val REQ_MEDIA_PROJECTION = 3102

        const val EXTRA_MODE = "extra_prompt_mode"
        const val EXTRA_AUDIO_SOURCE = "extra_prompt_audio_source"

        fun createIntent(
            context: Context,
            mode: RecordingMode,
            audioSource: AudioSourceOption
        ): Intent {
            return Intent(context, CallRecordPromptActivity::class.java).apply {
                putExtra(EXTRA_MODE, mode.wireValue)
                putExtra(EXTRA_AUDIO_SOURCE, audioSource.wireValue)
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_NO_ANIMATION or
                        Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS
                )
            }
        }
    }

    private var requestedMode: RecordingMode = RecordingMode.VIDEO
    private var requestedAudioSource: AudioSourceOption = AudioSourceOption.MIC
    private var flowStarted = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            overrideActivityTransition(OVERRIDE_TRANSITION_OPEN, 0, 0)
            overrideActivityTransition(OVERRIDE_TRANSITION_CLOSE, 0, 0)
        } else {
            @Suppress("DEPRECATION")
            overridePendingTransition(0, 0)
        }

        requestedMode = RecordingMode.fromWire(intent?.getStringExtra(EXTRA_MODE))
        requestedAudioSource = AudioSourceOption.fromWire(intent?.getStringExtra(EXTRA_AUDIO_SOURCE))

        CallAutoRecordCoordinator.cancelPromptNotification(applicationContext)

        if (CallRecorderService.isActivelyRecording) {
            finishSilently()
            return
        }

        if (savedInstanceState != null) {
            flowStarted = savedInstanceState.getBoolean("flowStarted", false)
        }
        if (!flowStarted) {
            flowStarted = true
            ensureMicThenProceed()
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean("flowStarted", flowStarted)
    }

    private fun ensureMicThenProceed() {
        val hasMic = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED

        if (!hasMic) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.RECORD_AUDIO),
                REQ_MIC_PERMISSION
            )
            return
        }

        proceedAfterMicGranted()
    }

    private fun proceedAfterMicGranted() {
        if (requestedMode == RecordingMode.VOICE) {
            Log.i(TAG, "Starting voice session from transparent trampoline activity")
            CallRecorderService.startVoiceSession(
                context = applicationContext,
                audioSource = requestedAudioSource,
                autoStarted = true
            )
            finishSilently()
            return
        }

        // Video Call mode: launch system MediaProjection consent dialog (required every session on Android 14)
        try {
            val projManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            val captureIntent = projManager.createScreenCaptureIntent()
            @Suppress("DEPRECATION")
            startActivityForResult(captureIntent, REQ_MEDIA_PROJECTION)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to open MediaProjection prompt: ${e.message}", e)
            CallAutoRecordCoordinator.onPromptDismissedForCurrentCall()
            finishSilently()
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_MIC_PERMISSION) return

        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        if (granted) {
            proceedAfterMicGranted()
        } else {
            Log.w(TAG, "RECORD_AUDIO denied in CallRecordPromptActivity")
            CallAutoRecordCoordinator.onPromptDismissedForCurrentCall()
            finishSilently()
        }
    }

    @Deprecated("Deprecated in Android Activity, required on plain Activity without AndroidX Fragment")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_MEDIA_PROJECTION) return

        if (resultCode == RESULT_OK && data != null) {
            Log.i(TAG, "✓ MediaProjection approved over WhatsApp — starting video call recording")
            CallRecorderService.startVideoSession(
                context = applicationContext,
                audioSource = requestedAudioSource,
                projectionResultCode = resultCode,
                projectionData = data,
                autoStarted = true
            )
        } else {
            Log.i(TAG, "MediaProjection prompt cancelled by user — suppressing re-prompt for this call")
            CallAutoRecordCoordinator.onPromptDismissedForCurrentCall()
        }
        finishSilently()
    }

    private fun finishSilently() {
        finish()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            @Suppress("DEPRECATION")
            overridePendingTransition(0, 0)
        }
    }
}


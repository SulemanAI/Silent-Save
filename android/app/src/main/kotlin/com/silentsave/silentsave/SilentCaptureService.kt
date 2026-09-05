package com.silentsave.silentsave

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
import android.hardware.camera2.*
import android.media.ImageReader
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import android.util.Size
import android.view.Surface
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit

/**
 * Headless foreground service that captures photos, video, and audio
 * using Camera2 API and MediaRecorder — without any preview surface.
 *
 * Triggered by:
 *  - PendingIntent actions from the KeepAliveService notification buttons
 *  - MethodChannel calls from the Flutter UI
 *
 * Design notes:
 *  - Uses a 1x1 SurfaceTexture as a dummy preview (Camera2 needs at least
 *    one output surface, but we don't actually display anything)
 *  - Acquires a PARTIAL_WAKE_LOCK during capture to keep CPU awake
 *  - Saves files to getExternalFilesDir("SilentCapture") — private to the app
 *  - Stops itself automatically after capture completes
 *  - Posts a transient notification while capturing, then dismisses it
 */
class SilentCaptureService : Service() {

    companion object {
        private const val TAG = "SilentCapture"
        private const val CHANNEL_ID = "silentsave_capture"
        private const val NOTIFICATION_ID = 9010

        // Intent action constants
        const val ACTION_CAPTURE_PHOTO = "com.silentsave.CAPTURE_PHOTO"
        const val ACTION_START_VIDEO = "com.silentsave.START_VIDEO"
        const val ACTION_STOP_VIDEO = "com.silentsave.STOP_VIDEO"
        const val ACTION_START_AUDIO = "com.silentsave.START_AUDIO"
        const val ACTION_STOP_AUDIO = "com.silentsave.STOP_AUDIO"

        // Extras
        const val EXTRA_USE_FRONT_CAMERA = "use_front_camera"
        const val EXTRA_VIDEO_DURATION_SEC = "video_duration_sec"
        const val EXTRA_AUDIO_DURATION_SEC = "audio_duration_sec"
        const val EXTRA_VIDEO_QUALITY = "video_quality" // "720p" or "1080p"

        // Defaults (0 = Unlimited)
        private const val DEFAULT_VIDEO_DURATION_SEC = 0
        private const val DEFAULT_AUDIO_DURATION_SEC = 0

        // State tracking
        @Volatile var isRecordingVideo = false
            private set
        @Volatile var isRecordingAudio = false
            private set

        /** Convenience: start a photo capture */
        fun capturePhoto(context: Context, useFrontCamera: Boolean = false) {
            val intent = Intent(context, SilentCaptureService::class.java).apply {
                action = ACTION_CAPTURE_PHOTO
                putExtra(EXTRA_USE_FRONT_CAMERA, useFrontCamera)
            }
            startServiceSafe(context, intent)
        }

        /** Convenience: start video recording */
        fun startVideo(context: Context, useFrontCamera: Boolean = false,
                       durationSec: Int = DEFAULT_VIDEO_DURATION_SEC,
                       quality: String = "720p") {
            val intent = Intent(context, SilentCaptureService::class.java).apply {
                action = ACTION_START_VIDEO
                putExtra(EXTRA_USE_FRONT_CAMERA, useFrontCamera)
                putExtra(EXTRA_VIDEO_DURATION_SEC, durationSec)
                putExtra(EXTRA_VIDEO_QUALITY, quality)
            }
            startServiceSafe(context, intent)
        }

        /** Convenience: stop video recording */
        fun stopVideo(context: Context) {
            val intent = Intent(context, SilentCaptureService::class.java).apply {
                action = ACTION_STOP_VIDEO
            }
            startServiceSafe(context, intent)
        }

        /** Convenience: start audio recording */
        fun startAudio(context: Context, durationSec: Int = DEFAULT_AUDIO_DURATION_SEC) {
            val intent = Intent(context, SilentCaptureService::class.java).apply {
                action = ACTION_START_AUDIO
                putExtra(EXTRA_AUDIO_DURATION_SEC, durationSec)
            }
            startServiceSafe(context, intent)
        }

        /** Convenience: stop audio recording */
        fun stopAudio(context: Context) {
            val intent = Intent(context, SilentCaptureService::class.java).apply {
                action = ACTION_STOP_AUDIO
            }
            startServiceSafe(context, intent)
        }

        private fun startServiceSafe(context: Context, intent: Intent) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start SilentCaptureService: ${e.message}")
            }
        }

        /** Get the directory where captured media is saved */
        fun getCaptureDir(context: Context): File {
            val dir = File(context.getExternalFilesDir(null), "SilentCapture")
            if (!dir.exists()) dir.mkdirs()
            return dir
        }
        
        /** Get the directory where trashed media is stored */
        fun getTrashDir(context: Context): File {
            val dir = File(context.getExternalFilesDir(null), "SilentCaptureTrash")
            if (!dir.exists()) dir.mkdirs()
            return dir
        }

        /** List all captured media files sorted by date (newest first) */
        fun listCapturedMedia(context: Context): List<Map<String, Any>> {
            val dir = getCaptureDir(context)
            if (!dir.exists()) return emptyList()

            return _listMediaInDir(dir)
        }
        
        /** List all trashed media files sorted by date (newest first) */
        fun listTrashedMedia(context: Context): List<Map<String, Any>> {
            val dir = getTrashDir(context)
            if (!dir.exists()) return emptyList()

            return _listMediaInDir(dir)
        }
        
        private fun _listMediaInDir(dir: File): List<Map<String, Any>> {
            return dir.listFiles()
                ?.filter { it.isFile && (it.extension in listOf("jpg", "mp4", "m4a", "3gp")) }
                ?.sortedByDescending { it.lastModified() }
                ?.map { file ->
                    mapOf(
                        "path" to file.absolutePath,
                        "name" to file.name,
                        "type" to when (file.extension) {
                            "jpg" -> "photo"
                            "mp4" -> "video"
                            "m4a", "3gp" -> "audio"
                            else -> "unknown"
                        },
                        "sizeBytes" to file.length(),
                        "timestampMs" to file.lastModified()
                    )
                } ?: emptyList()
        }
        
        /** Delete trashed media older than 24 hours */
        fun cleanupTrash(context: Context) {
            val dir = getTrashDir(context)
            if (!dir.exists()) return
            
            val twentyFourHoursAgo = System.currentTimeMillis() - (24 * 60 * 60 * 1000L)
            
            dir.listFiles()?.forEach { file ->
                if (file.isFile && file.lastModified() < twentyFourHoursAgo) {
                    try {
                        file.delete()
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to auto-delete trashed file: ${file.name}")
                    }
                }
            }
        }
    }

    // Camera2 state
    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var imageReader: ImageReader? = null
    private val cameraOpenCloseLock = Semaphore(1)

    // Background thread for camera operations
    private var backgroundThread: HandlerThread? = null
    private var backgroundHandler: Handler? = null

    // MediaRecorder for video/audio
    private var mediaRecorder: MediaRecorder? = null
    private var currentOutputFile: File? = null

    // WakeLock
    private var wakeLock: PowerManager.WakeLock? = null

    // Auto-stop handler
    private val mainHandler = Handler(android.os.Looper.getMainLooper())
    private var autoStopRunnable: Runnable? = null

    // Track current camera facing (for video recording surface setup)
    private var useFrontCamera = false

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "SilentCaptureService created")
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: run {
            stopSelf()
            return START_NOT_STICKY
        }

        Log.i(TAG, "onStartCommand action=$action")
        
        // Read Flutter SharedPreferences for fallback defaults
        val prefs = applicationContext.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val flutterUseFront = prefs.getBoolean("flutter.capture_use_front_camera", false)
        val flutterVideoDuration = prefs.getLong("flutter.capture_video_duration", DEFAULT_VIDEO_DURATION_SEC.toLong()).toInt()
        val flutterAudioDuration = prefs.getLong("flutter.capture_audio_duration", DEFAULT_AUDIO_DURATION_SEC.toLong()).toInt()
        val flutterVideoQuality = prefs.getString("flutter.capture_video_quality", "720p") ?: "720p"

        when (action) {
            ACTION_CAPTURE_PHOTO -> {
                startForegroundWithNotification("Capturing photo...")
                acquireWakeLock()
                useFrontCamera = intent.getBooleanExtra(EXTRA_USE_FRONT_CAMERA, flutterUseFront)
                startBackgroundThread()
                capturePhotoInternal()
            }
            ACTION_START_VIDEO -> {
                if (isRecordingVideo) {
                    Log.w(TAG, "Already recording video, ignoring")
                    return START_NOT_STICKY
                }
                startForegroundWithNotification("Recording video...")
                acquireWakeLock()
                
                useFrontCamera = intent.getBooleanExtra(EXTRA_USE_FRONT_CAMERA, flutterUseFront)
                val duration = intent.getIntExtra(EXTRA_VIDEO_DURATION_SEC, flutterVideoDuration)
                val quality = intent.getStringExtra(EXTRA_VIDEO_QUALITY) ?: flutterVideoQuality
                
                startBackgroundThread()
                startVideoInternal(duration, quality)
            }
            ACTION_STOP_VIDEO -> {
                stopVideoInternal()
            }
            ACTION_START_AUDIO -> {
                if (isRecordingAudio) {
                    Log.w(TAG, "Already recording audio, ignoring")
                    return START_NOT_STICKY
                }
                startForegroundWithNotification("Recording audio...")
                acquireWakeLock()
                val duration = intent.getIntExtra(EXTRA_AUDIO_DURATION_SEC, flutterAudioDuration)
                startAudioInternal(duration)
            }
            ACTION_STOP_AUDIO -> {
                stopAudioInternal()
            }
        }

        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        Log.i(TAG, "SilentCaptureService destroyed")
        cleanup()
        super.onDestroy()
    }

    // ──────────────────────────────────────────────────────────────────────
    // PHOTO CAPTURE
    // ──────────────────────────────────────────────────────────────────────

    private fun capturePhotoInternal() {
        try {
            val manager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
            val cameraId = findCameraId(manager, useFrontCamera)
            if (cameraId == null) {
                Log.e(TAG, "No suitable camera found")
                finishCapture()
                return
            }

            val characteristics = manager.getCameraCharacteristics(cameraId)
            val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            val outputSizes = map?.getOutputSizes(ImageFormat.JPEG)
            val size = outputSizes?.maxByOrNull { it.width * it.height }
                ?: Size(1920, 1080)

            Log.d(TAG, "Photo resolution: ${size.width}x${size.height}")

            imageReader = ImageReader.newInstance(size.width, size.height, ImageFormat.JPEG, 2)
            imageReader!!.setOnImageAvailableListener({ reader ->
                val image = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
                try {
                    val buffer = image.planes[0].buffer
                    val bytes = ByteArray(buffer.remaining())
                    buffer.get(bytes)

                    val file = createOutputFile("IMG", "jpg")
                    FileOutputStream(file).use { it.write(bytes) }
                    Log.i(TAG, "✓ Photo saved: ${file.absolutePath} (${bytes.size} bytes)")
                    currentOutputFile = file
                } catch (e: Exception) {
                    Log.e(TAG, "Error saving photo: ${e.message}")
                } finally {
                    image.close()
                    finishCapture()
                }
            }, backgroundHandler)

            // Open camera
            if (!cameraOpenCloseLock.tryAcquire(2500, TimeUnit.MILLISECONDS)) {
                Log.e(TAG, "Camera lock timeout")
                finishCapture()
                return
            }

            manager.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    cameraOpenCloseLock.release()
                    cameraDevice = camera
                    Log.d(TAG, "Camera opened")

                    try {
                        // Create capture session with ImageReader surface
                        val surfaces = listOf(imageReader!!.surface)
                        camera.createCaptureSession(
                            surfaces,
                            object : CameraCaptureSession.StateCallback() {
                                override fun onConfigured(session: CameraCaptureSession) {
                                    captureSession = session
                                    try {
                                        val captureBuilder = camera.createCaptureRequest(
                                            CameraDevice.TEMPLATE_STILL_CAPTURE
                                        ).apply {
                                            addTarget(imageReader!!.surface)
                                            set(CaptureRequest.CONTROL_MODE,
                                                CameraMetadata.CONTROL_MODE_AUTO)
                                            set(CaptureRequest.CONTROL_AF_MODE,
                                                CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                                            set(CaptureRequest.CONTROL_AE_MODE,
                                                CaptureRequest.CONTROL_AE_MODE_ON)
                                            
                                            val orientation = getOrientationDegrees(manager, cameraId)
                                            set(CaptureRequest.JPEG_ORIENTATION, orientation)
                                        }

                                        // Give auto-exposure a moment to settle, then capture
                                        backgroundHandler?.postDelayed({
                                            try {
                                                session.capture(
                                                    captureBuilder.build(),
                                                    object : CameraCaptureSession.CaptureCallback() {
                                                        override fun onCaptureCompleted(
                                                            session: CameraCaptureSession,
                                                            request: CaptureRequest,
                                                            result: TotalCaptureResult
                                                        ) {
                                                            Log.d(TAG, "Photo capture completed")
                                                        }

                                                        override fun onCaptureFailed(
                                                            session: CameraCaptureSession,
                                                            request: CaptureRequest,
                                                            failure: CaptureFailure
                                                        ) {
                                                            Log.e(TAG, "Photo capture failed: ${failure.reason}")
                                                            finishCapture()
                                                        }
                                                    },
                                                    backgroundHandler
                                                )
                                            } catch (e: Exception) {
                                                Log.e(TAG, "Capture error: ${e.message}")
                                                finishCapture()
                                            }
                                        }, 500) // 500ms delay for AE to settle
                                    } catch (e: Exception) {
                                        Log.e(TAG, "Session configure error: ${e.message}")
                                        finishCapture()
                                    }
                                }

                                override fun onConfigureFailed(session: CameraCaptureSession) {
                                    Log.e(TAG, "Camera session configuration failed")
                                    finishCapture()
                                }
                            },
                            backgroundHandler
                        )
                    } catch (e: Exception) {
                        Log.e(TAG, "Error creating capture session: ${e.message}")
                        finishCapture()
                    }
                }

                override fun onDisconnected(camera: CameraDevice) {
                    cameraOpenCloseLock.release()
                    camera.close()
                    cameraDevice = null
                    Log.w(TAG, "Camera disconnected")
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    cameraOpenCloseLock.release()
                    camera.close()
                    cameraDevice = null
                    Log.e(TAG, "Camera error: $error")
                    finishCapture()
                }
            }, backgroundHandler)

        } catch (e: SecurityException) {
            Log.e(TAG, "Camera permission denied: ${e.message}")
            finishCapture()
        } catch (e: Exception) {
            Log.e(TAG, "Photo capture error: ${e.message}")
            finishCapture()
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // VIDEO RECORDING
    // ──────────────────────────────────────────────────────────────────────

    private fun startVideoInternal(durationSec: Int, quality: String) {
        try {
            val manager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
            val cameraId = findCameraId(manager, useFrontCamera)
            if (cameraId == null) {
                Log.e(TAG, "No suitable camera found for video")
                finishCapture()
                return
            }

            val (width, height) = when (quality) {
                "1080p" -> Pair(1920, 1080)
                else -> Pair(1280, 720)
            }

            val outputFile = createOutputFile("VID", "mp4")
            currentOutputFile = outputFile
            
            val orientation = getOrientationDegrees(manager, cameraId)

            // Setup MediaRecorder
            mediaRecorder = (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(this)
            } else {
                @Suppress("DEPRECATION")
                MediaRecorder()
            }).apply {
                setAudioSource(MediaRecorder.AudioSource.MIC)
                setVideoSource(MediaRecorder.VideoSource.SURFACE)
                setOrientationHint(orientation)
                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                setOutputFile(outputFile.absolutePath)
                setVideoEncodingBitRate(if (quality == "1080p") 6_000_000 else 3_000_000)
                setVideoFrameRate(30)
                setVideoSize(width, height)
                setVideoEncoder(MediaRecorder.VideoEncoder.H264)
                setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                setAudioEncodingBitRate(128_000)
                setAudioSamplingRate(44100)
                prepare()
            }

            // Open camera
            if (!cameraOpenCloseLock.tryAcquire(2500, TimeUnit.MILLISECONDS)) {
                Log.e(TAG, "Camera lock timeout for video")
                finishCapture()
                return
            }

            manager.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    cameraOpenCloseLock.release()
                    cameraDevice = camera
                    Log.d(TAG, "Camera opened for video")

                    try {
                        val recorderSurface = mediaRecorder!!.surface

                        // Create a dummy SurfaceTexture for the preview (needed by some devices)
                        val dummyTexture = SurfaceTexture(0)
                        dummyTexture.setDefaultBufferSize(1, 1)
                        val dummySurface = Surface(dummyTexture)

                        val surfaces = listOf(recorderSurface, dummySurface)

                        camera.createCaptureSession(
                            surfaces,
                            object : CameraCaptureSession.StateCallback() {
                                override fun onConfigured(session: CameraCaptureSession) {
                                    captureSession = session
                                    try {
                                        val builder = camera.createCaptureRequest(
                                            CameraDevice.TEMPLATE_RECORD
                                        ).apply {
                                            addTarget(recorderSurface)
                                            set(CaptureRequest.CONTROL_MODE,
                                                CameraMetadata.CONTROL_MODE_AUTO)
                                            set(CaptureRequest.CONTROL_AF_MODE,
                                                CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                                        }

                                        session.setRepeatingRequest(
                                            builder.build(), null, backgroundHandler
                                        )

                                        mediaRecorder!!.start()
                                        isRecordingVideo = true
                                        Log.i(TAG, "✓ Video recording started (${durationSec}s, $quality)")
                                        updateNotification("Recording video... Tap to stop")

                                        // Auto-stop after duration if not unlimited
                                        if (durationSec > 0) {
                                            scheduleAutoStop(durationSec * 1000L) {
                                                stopVideoInternal()
                                            }
                                        }
                                    } catch (e: Exception) {
                                        Log.e(TAG, "Video recording start error: ${e.message}")
                                        finishCapture()
                                    }
                                }

                                override fun onConfigureFailed(session: CameraCaptureSession) {
                                    Log.e(TAG, "Video session configuration failed")
                                    finishCapture()
                                }
                            },
                            backgroundHandler
                        )
                    } catch (e: Exception) {
                        Log.e(TAG, "Error creating video session: ${e.message}")
                        finishCapture()
                    }
                }

                override fun onDisconnected(camera: CameraDevice) {
                    cameraOpenCloseLock.release()
                    camera.close()
                    cameraDevice = null
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    cameraOpenCloseLock.release()
                    camera.close()
                    cameraDevice = null
                    Log.e(TAG, "Camera error during video: $error")
                    finishCapture()
                }
            }, backgroundHandler)

        } catch (e: SecurityException) {
            Log.e(TAG, "Camera/Mic permission denied: ${e.message}")
            finishCapture()
        } catch (e: Exception) {
            Log.e(TAG, "Video recording error: ${e.message}")
            finishCapture()
        }
    }

    private fun stopVideoInternal() {
        if (!isRecordingVideo) return
        Log.i(TAG, "Stopping video recording...")
        isRecordingVideo = false
        cancelAutoStop()

        try {
            mediaRecorder?.apply {
                stop()
                reset()
                release()
            }
            mediaRecorder = null
            Log.i(TAG, "✓ Video saved: ${currentOutputFile?.absolutePath}")
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping video: ${e.message}")
            // Delete potentially corrupt file
            currentOutputFile?.delete()
        }

        finishCapture()
    }

    // ──────────────────────────────────────────────────────────────────────
    // AUDIO RECORDING
    // ──────────────────────────────────────────────────────────────────────

    private fun startAudioInternal(durationSec: Int) {
        try {
            val outputFile = createOutputFile("AUD", "m4a")
            currentOutputFile = outputFile

            mediaRecorder = (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(this)
            } else {
                @Suppress("DEPRECATION")
                MediaRecorder()
            }).apply {
                setAudioSource(MediaRecorder.AudioSource.MIC)
                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                setOutputFile(outputFile.absolutePath)
                setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                setAudioEncodingBitRate(128_000)
                setAudioSamplingRate(44100)
                prepare()
                start()
            }

            isRecordingAudio = true
            Log.i(TAG, "✓ Audio recording started (${durationSec}s)")
            updateNotification("Recording audio... Tap to stop")

            // Auto-stop after duration if not unlimited
            if (durationSec > 0) {
                scheduleAutoStop(durationSec * 1000L) {
                    stopAudioInternal()
                }
            }
        } catch (e: SecurityException) {
            Log.e(TAG, "Microphone permission denied: ${e.message}")
            finishCapture()
        } catch (e: Exception) {
            Log.e(TAG, "Audio recording error: ${e.message}")
            finishCapture()
        }
    }

    private fun stopAudioInternal() {
        if (!isRecordingAudio) return
        Log.i(TAG, "Stopping audio recording...")
        isRecordingAudio = false
        cancelAutoStop()

        try {
            mediaRecorder?.apply {
                stop()
                reset()
                release()
            }
            mediaRecorder = null
            Log.i(TAG, "✓ Audio saved: ${currentOutputFile?.absolutePath}")
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping audio: ${e.message}")
            currentOutputFile?.delete()
        }

        finishCapture()
    }

    // ──────────────────────────────────────────────────────────────────────
    // HELPERS
    // ──────────────────────────────────────────────────────────────────────

    private fun findCameraId(manager: CameraManager, front: Boolean): String? {
        val facing = if (front) CameraCharacteristics.LENS_FACING_FRONT
                     else CameraCharacteristics.LENS_FACING_BACK
        return manager.cameraIdList.firstOrNull { id ->
            val chars = manager.getCameraCharacteristics(id)
            chars.get(CameraCharacteristics.LENS_FACING) == facing
        } ?: manager.cameraIdList.firstOrNull() // Fallback to any camera
    }

    private fun createOutputFile(prefix: String, extension: String): File {
        val dir = getCaptureDir(this)
        val timestamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
        return File(dir, "${prefix}_${timestamp}.$extension")
    }
    
    private fun getOrientationDegrees(manager: CameraManager, cameraId: String): Int {
        return try {
            val chars = manager.getCameraCharacteristics(cameraId)
            val sensorOrientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
            val lensFacing = chars.get(CameraCharacteristics.LENS_FACING) ?: CameraCharacteristics.LENS_FACING_BACK
            // Since this runs in the background (pocket/screen off), assume Portrait (0)
            val deviceRotation = 0 
            if (lensFacing == CameraCharacteristics.LENS_FACING_FRONT) {
                (sensorOrientation + deviceRotation) % 360
            } else {
                (sensorOrientation - deviceRotation + 360) % 360
            }
        } catch (e: Exception) {
            0
        }
    }

    private fun startBackgroundThread() {
        if (backgroundThread == null) {
            backgroundThread = HandlerThread("SilentCaptureThread").also {
                it.start()
                backgroundHandler = Handler(it.looper)
            }
        }
    }

    private fun stopBackgroundThread() {
        backgroundThread?.quitSafely()
        try {
            backgroundThread?.join(3000)
        } catch (_: Exception) {}
        backgroundThread = null
        backgroundHandler = null
    }

    private fun acquireWakeLock() {
        if (wakeLock == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "SilentSave::CaptureWakeLock"
            ).apply { setReferenceCounted(false) }
        }
        wakeLock?.acquire(5 * 60 * 1000L) // Max 5 minutes
        Log.d(TAG, "WakeLock acquired for capture")
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {}
        wakeLock = null
    }

    private fun scheduleAutoStop(delayMs: Long, action: () -> Unit) {
        cancelAutoStop()
        autoStopRunnable = Runnable {
            Log.i(TAG, "Auto-stop triggered after ${delayMs / 1000}s")
            action()
        }
        mainHandler.postDelayed(autoStopRunnable!!, delayMs)
    }

    private fun cancelAutoStop() {
        autoStopRunnable?.let { mainHandler.removeCallbacks(it) }
        autoStopRunnable = null
    }

    private fun closeCamera() {
        try {
            cameraOpenCloseLock.tryAcquire(2500, TimeUnit.MILLISECONDS)
            captureSession?.close()
            captureSession = null
            cameraDevice?.close()
            cameraDevice = null
            imageReader?.close()
            imageReader = null
            cameraOpenCloseLock.release()
        } catch (e: Exception) {
            Log.e(TAG, "Error closing camera: ${e.message}")
        }
    }

    private fun cleanup() {
        cancelAutoStop()
        if (isRecordingVideo) {
            try {
                mediaRecorder?.stop()
            } catch (_: Exception) {}
            isRecordingVideo = false
        }
        if (isRecordingAudio) {
            try {
                mediaRecorder?.stop()
            } catch (_: Exception) {}
            isRecordingAudio = false
        }
        try {
            mediaRecorder?.release()
        } catch (_: Exception) {}
        mediaRecorder = null
        closeCamera()
        stopBackgroundThread()
        releaseWakeLock()
    }

    private fun finishCapture() {
        mainHandler.post {
            cleanup()
            stopForeground(true)
            stopSelf()
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // NOTIFICATION
    // ──────────────────────────────────────────────────────────────────────

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Silent Capture",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows while capturing photo/video/audio"
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_SECRET
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }
    }

    private fun startForegroundWithNotification(text: String) {
        val notification = buildNotification(text)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val serviceType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or
                    android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                } else {
                    android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                }
                startForeground(NOTIFICATION_ID, notification, serviceType)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            Log.e(TAG, "startForeground failed: ${e.message}")
            try {
                startForeground(NOTIFICATION_ID, notification)
            } catch (e2: Exception) {
                Log.e(TAG, "startForeground fallback failed: ${e2.message}")
            }
        }
    }

    private fun updateNotification(text: String) {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        manager.notify(NOTIFICATION_ID, buildNotification(text))
    }

    private fun buildNotification(text: String): Notification {
        val openAppIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, openAppIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // Add a Stop button if recording
        val stopIntent = when {
            isRecordingVideo -> Intent(this, SilentCaptureService::class.java).apply {
                action = ACTION_STOP_VIDEO
            }
            isRecordingAudio -> Intent(this, SilentCaptureService::class.java).apply {
                action = ACTION_STOP_AUDIO
            }
            else -> null
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }.apply {
            setContentTitle("Silent Save")
            setContentText(text)
            setSmallIcon(android.R.drawable.ic_menu_camera)
            setContentIntent(pendingIntent)
            setOngoing(true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
            }
        }

        if (stopIntent != null) {
            val stopPi = PendingIntent.getService(
                this, 1, stopIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            builder.addAction(
                Notification.Action.Builder(
                    null, "⏹ Stop", stopPi
                ).build()
            )
        }

        return builder.build()
    }
}

package com.silentsave.silentsave

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.DocumentsContract
import android.provider.Settings
import android.util.Log

import androidx.work.*
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.TimeUnit

class MainActivity : FlutterFragmentActivity() {
    companion object {
        private const val TAG = "SilentSaveMain"
        private const val CHANNEL = "com.silentsave/notifications"
        private const val PREFS_NAME = "notification_data"
        private const val SAF_REQUEST_CODE = 2001
    }

    // Holds the pending Flutter result for the SAF permission request.
    // Set before launching ACTION_OPEN_DOCUMENT_TREE, resolved in onActivityResult.
    private var pendingSafResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        Log.d(TAG, "Configuring Flutter engine")

        // Start the foreground KeepAliveService to prevent OEM battery kill
        try {
            KeepAliveService.start(applicationContext)
            Log.i(TAG, "KeepAliveService started from MainActivity")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start KeepAliveService: ${e.message}")
        }

        // Schedule NLS health check worker to keep NLS alive on aggressive OEM phones
        NlsHealthWorker.schedule(applicationContext)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            Log.d(TAG, "Method call: ${call.method}")
            when (call.method) {
                "isNotificationPermissionGranted" -> {
                    val granted = isNotificationServiceEnabled()
                    Log.d(TAG, "Permission: $granted")
                    result.success(granted)
                }
                "openNotificationSettings" -> {
                    openNotificationSettings()
                    result.success(null)
                }
                "scheduleCleanupJob" -> {
                    scheduleCleanupJob()
                    result.success(null)
                }
                "getPendingNotifications" -> {
                    val data = getPendingNotifications()
                    Log.d(TAG, "Returning ${data.size} notifications")
                    result.success(data)
                }
                "checkCleanupRequested" -> {
                    result.success(checkAndClearCleanupFlag())
                }
                "isBatteryOptimizationExempt" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                        result.success(pm.isIgnoringBatteryOptimizations(packageName))
                    } else {
                        result.success(true)
                    }
                }
                "requestBatteryOptimizationExemption" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                        if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                            startActivity(Intent(
                                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                Uri.parse("package:$packageName")
                            ))
                        }
                    }
                    result.success(null)
                }
                "getManufacturer" -> {
                    result.success(android.os.Build.MANUFACTURER)
                }
                "openOemBatterySettings" -> {
                    val pkg = call.argument<String>("package")
                    if (pkg != null) {
                        try {
                            val intent = Intent(Intent.ACTION_MAIN)
                            intent.setPackage(pkg)
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                        } catch (e: Exception) {
                            Log.w(TAG, "OEM battery settings not found for package: $pkg")
                        }
                    }
                    result.success(null)
                }
                "requestNlsRebind" -> {
                    try {
                        val componentName = ComponentName(this, NotificationListener::class.java)
                        android.service.notification.NotificationListenerService.requestRebind(componentName)
                        Log.i(TAG, "Manual NLS rebind requested")
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to request rebind: ${e.message}")
                        result.success(false)
                    }
                }

                // ── SAF permission for WhatsApp media folder ────────────────────────
                "requestWhatsAppSafPermission" -> {
                    pendingSafResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                        addFlags(
                            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                        )
                        // Hint the picker to the WhatsApp media folder.
                        // ⚠️ ANDROID 11+ NOTE: ACTION_OPEN_DOCUMENT_TREE cannot start
                        // AT Android/data/ or Android/media/ root on some ROMs —
                        // the user must navigate there manually. The hint is best-effort.
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            val hint = buildSafInitialUri()
                            if (hint != null) putExtra(DocumentsContract.EXTRA_INITIAL_URI, hint)
                        }
                    }
                    try {
                        startActivityForResult(intent, SAF_REQUEST_CODE)
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to launch SAF picker: ${e.message}")
                        pendingSafResult = null
                        result.success(false)
                    }
                }

                "getSafPermissionStatus" -> {
                    result.success(MediaWatcherService.hasSafPermission(applicationContext))
                }

                // ── Media queue: read and clear media_queue.json ────────────────────
                "getMediaQueue" -> {
                    val data = getMediaQueue()
                    Log.d(TAG, "Returning ${data.size} media queue entries")
                    result.success(data)
                }

                // ── Silent Capture methods ──────────────────────────────────────────
                "capturePhoto" -> {
                    val useFront = call.argument<Boolean>("useFrontCamera") ?: false
                    SilentCaptureService.capturePhoto(applicationContext, useFront)
                    result.success(true)
                }
                "startVideoRecording" -> {
                    val useFront = call.argument<Boolean>("useFrontCamera") ?: false
                    val duration = call.argument<Int>("durationSec") ?: 0
                    val quality = call.argument<String>("quality") ?: "720p"
                    SilentCaptureService.startVideo(applicationContext, useFront, duration, quality)
                    result.success(true)
                }
                "stopVideoRecording" -> {
                    SilentCaptureService.stopVideo(applicationContext)
                    result.success(true)
                }
                "startAudioRecording" -> {
                    val duration = call.argument<Int>("durationSec") ?: 0
                    SilentCaptureService.startAudio(applicationContext, duration)
                    result.success(true)
                }
                "stopAudioRecording" -> {
                    SilentCaptureService.stopAudio(applicationContext)
                    result.success(true)
                }
                "getCapturedMedia" -> {
                    val media = SilentCaptureService.listCapturedMedia(applicationContext)
                    result.success(media)
                }
                "deleteCapturedMedia" -> {
                    val path = call.argument<String>("path")
                    if (path != null) {
                        val file = java.io.File(path)
                        val trashDir = SilentCaptureService.getTrashDir(applicationContext)
                        val trashFile = java.io.File(trashDir, file.name)
                        
                        val moved = file.exists() && file.renameTo(trashFile)
                        if (moved) {
                            // Reset the last modified timestamp to NOW so the 24h countdown starts
                            trashFile.setLastModified(System.currentTimeMillis())
                        }
                        result.success(moved)
                    } else {
                        result.success(false)
                    }
                }
                "getTrashedMedia" -> {
                    val media = SilentCaptureService.listTrashedMedia(applicationContext)
                    result.success(media)
                }
                "restoreTrashedMedia" -> {
                    val path = call.argument<String>("path")
                    if (path != null) {
                        val file = java.io.File(path)
                        val captureDir = SilentCaptureService.getCaptureDir(applicationContext)
                        val captureFile = java.io.File(captureDir, file.name)
                        
                        val restored = file.exists() && file.renameTo(captureFile)
                        result.success(restored)
                    } else {
                        result.success(false)
                    }
                }
                "permanentDeleteMedia" -> {
                    val path = call.argument<String>("path")
                    if (path != null) {
                        val file = java.io.File(path)
                        val deleted = file.exists() && file.delete()
                        result.success(deleted)
                    } else {
                        result.success(false)
                    }
                }
                "emptyTrash" -> {
                    val trashDir = SilentCaptureService.getTrashDir(applicationContext)
                    var allDeleted = true
                    trashDir.listFiles()?.forEach {
                        if (!it.delete()) allDeleted = false
                    }
                    result.success(allDeleted)
                }
                "getCaptureStatus" -> {
                    result.success(mapOf(
                        "isRecordingVideo" to SilentCaptureService.isRecordingVideo,
                        "isRecordingAudio" to SilentCaptureService.isRecordingAudio
                    ))
                }
                "hasCameraPermission" -> {
                    val granted = androidx.core.content.ContextCompat.checkSelfPermission(
                        this, android.Manifest.permission.CAMERA
                    ) == android.content.pm.PackageManager.PERMISSION_GRANTED
                    result.success(granted)
                }
                "hasAudioPermission" -> {
                    val granted = androidx.core.content.ContextCompat.checkSelfPermission(
                        this, android.Manifest.permission.RECORD_AUDIO
                    ) == android.content.pm.PackageManager.PERMISSION_GRANTED
                    result.success(granted)
                }

                else -> { result.notImplemented() }
            }
        }
    }

    private fun isNotificationServiceEnabled(): Boolean {
        val flat = Settings.Secure.getString(
            contentResolver,
            "enabled_notification_listeners"
        ) ?: return false

        val serviceComponent = ComponentName(this, NotificationListener::class.java)
        return flat.contains(serviceComponent.flattenToString())
    }



    private fun openNotificationSettings() {
        startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
    }

    private fun scheduleCleanupJob() {
        val constraints = Constraints.Builder()
            .setRequiresBatteryNotLow(true)
            .build()

        val cleanupRequest = PeriodicWorkRequestBuilder<CleanupWorker>(
            1, TimeUnit.DAYS
        )
            .setConstraints(constraints)
            .setInitialDelay(1, TimeUnit.HOURS)
            .build()

        WorkManager.getInstance(applicationContext).enqueueUniquePeriodicWork(
            "cleanup_old_messages",
            ExistingPeriodicWorkPolicy.KEEP,
            cleanupRequest
        )
    }

    private fun getNotificationsFile(): File {
        return NotificationListener.getNotificationsFilePath(applicationContext)
    }

    /**
     * Read and atomically clear pending notifications.
     * 
     * Safety guarantees:
     * 1. File locking prevents concurrent writes from NotificationListener
     * 2. We only clear the file AFTER successfully parsing all entries
     * 3. If clearing fails, data stays on disk and will be re-read next poll
     * 4. Individual corrupt entries are skipped, not fatal
     */
    private fun getPendingNotifications(): List<Map<String, Any?>> {
        val file = getNotificationsFile()
        val list = mutableListOf<Map<String, Any?>>()
        
        if (!file.exists()) return list
        
        // Quick check: skip if file is empty or just "[]"
        try {
            val size = file.length()
            if (size <= 2) return list  // Empty file or "[]"
        } catch (e: Exception) {
            // Proceed with normal read
        }
        
        try {
            val lockFile = File(file.absolutePath + ".lock")
            lockFile.createNewFile()
            
            RandomAccessFile(lockFile, "rw").use { raf ->
                raf.channel.lock().use { _ ->
                    val jsonString = if (file.exists()) file.readText().trim() else "[]"
                    if (jsonString.isEmpty() || jsonString == "[]") return list
                    
                    val jsonArray = JSONArray(jsonString)
                    if (jsonArray.length() == 0) return list
                    
                    Log.d(TAG, "Reading ${jsonArray.length()} pending notifications")
                    
                    for (i in 0 until jsonArray.length()) {
                        try {
                            val obj = jsonArray.getJSONObject(i)
                            list.add(mapOf(
                                "method" to obj.optString("method", ""),
                                "title" to obj.optString("title", ""),
                                "text" to obj.optString("text", ""),
                                "packageName" to obj.optString("packageName", ""),
                                "timestamp" to obj.optLong("timestamp", 0L),
                                "senderName" to obj.optString("senderName", obj.optString("title", "")),
                                "isGroupChat" to obj.optBoolean("isGroupChat", false),
                                "avatarPath" to obj.optString("avatarPath", ""),
                                "mediaPath" to obj.optString("mediaPath", "")
                            ))
                        } catch (e: Exception) {
                            Log.e(TAG, "Skipping corrupt entry $i: ${e.message}")
                        }
                    }
                    
                    // Only clear AFTER successful parse — prevents data loss
                    // Use atomic write: write tmp then rename
                    try {
                        val tmpFile = File(file.absolutePath + ".tmp")
                        tmpFile.writeText("[]")
                        if (!tmpFile.renameTo(file)) {
                            file.delete()
                            if (!tmpFile.renameTo(file)) {
                                file.writeText("[]")
                                tmpFile.delete()
                            }
                        }
                    } catch (clearErr: Exception) {
                        Log.e(TAG, "Error clearing file (data safe, may re-read): ${clearErr.message}")
                        // Don't rethrow — we already got the data
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error reading notifications: ${e.message}")
            
            // Fallback without locking
            try {
                val jsonString = file.readText().trim()
                if (jsonString.isNotEmpty() && jsonString != "[]") {
                    val jsonArray = JSONArray(jsonString)
                    for (i in 0 until jsonArray.length()) {
                        try {
                            val obj = jsonArray.getJSONObject(i)
                            list.add(mapOf(
                                "method" to obj.optString("method", ""),
                                "title" to obj.optString("title", ""),
                                "text" to obj.optString("text", ""),
                                "packageName" to obj.optString("packageName", ""),
                                "timestamp" to obj.optLong("timestamp", 0L),
                                "senderName" to obj.optString("senderName", obj.optString("title", "")),
                                "isGroupChat" to obj.optBoolean("isGroupChat", false),
                                "avatarPath" to obj.optString("avatarPath", ""),
                                "mediaPath" to obj.optString("mediaPath", "")
                            ))
                        } catch (_: Exception) {}
                    }
                    file.writeText("[]")
                }
            } catch (fallbackE: Exception) {
                Log.e(TAG, "Fallback failed: ${fallbackE.message}")
                try { file.writeText("[]") } catch (_: Exception) {}
            }
        }
        
        return list
    }

    private fun checkAndClearCleanupFlag(): Boolean {
        val prefs = applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val requested = prefs.getBoolean("cleanup_requested", false)
        if (requested) {
            prefs.edit().putBoolean("cleanup_requested", false).apply()
        }
        return requested
    }

    // ──────────────────────────────────────────────────────────────────────
    // SAF PERMISSION RESULT
    // ──────────────────────────────────────────────────────────────────────

    @Deprecated("Required by FlutterActivity — ActivityResultContracts requires pre-registration")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == SAF_REQUEST_CODE) {
            val uri = data?.data
            if (resultCode == Activity.RESULT_OK && uri != null) {
                Log.i(TAG, "SAF grant received: $uri")
                MediaWatcherService.onSafUriGranted(applicationContext, uri)
                pendingSafResult?.success(true)
            } else {
                Log.w(TAG, "SAF picker cancelled or no URI (resultCode=$resultCode)")
                pendingSafResult?.success(false)
            }
            pendingSafResult = null
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    /**
     * Build a URI hint for ACTION_OPEN_DOCUMENT_TREE pointing to WhatsApp's
     * media folder. Android 11+ moved it to Android/media/com.whatsapp/.
     * This is a best-effort hint; the user can navigate elsewhere in the picker.
     */
    private fun buildSafInitialUri(): Uri? {
        return try {
            // Try Android 11+ scoped path first
            val path11 = "primary:Android/media/com.whatsapp/WhatsApp/Media"
            DocumentsContract.buildDocumentUri(
                "com.android.externalstorage.documents",
                path11
            )
        } catch (_: Exception) {
            try {
                // Fallback: legacy WhatsApp path (Android < 11)
                val pathLegacy = "primary:WhatsApp/Media"
                DocumentsContract.buildDocumentUri(
                    "com.android.externalstorage.documents",
                    pathLegacy
                )
            } catch (_: Exception) { null }
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // MEDIA QUEUE READER
    // ──────────────────────────────────────────────────────────────────────

    /**
     * Read and atomically clear media_queue.json.
     * Same safety guarantees as getPendingNotifications():
     *  1. File locking prevents concurrent writes from MediaWatcherService
     *  2. File cleared only AFTER successful parse
     *  3. Individual corrupt entries are skipped
     */
    private fun getMediaQueue(): List<Map<String, Any?>> {
        val file = MediaWatcherService.getMediaQueueFile(applicationContext)
        val list = mutableListOf<Map<String, Any?>>()
        if (!file.exists() || file.length() <= 2) return list

        try {
            val lockFile = File(file.absolutePath + ".lock")
            lockFile.createNewFile()
            RandomAccessFile(lockFile, "rw").use { raf ->
                raf.channel.lock().use { _ ->
                    val json = if (file.exists()) file.readText().trim() else "[]"
                    if (json.isEmpty() || json == "[]") return list
                    val arr = JSONArray(json)
                    for (i in 0 until arr.length()) {
                        try {
                            val obj = arr.getJSONObject(i)
                            val entry = mutableMapOf<String, Any?>(
                                "originalUri"     to obj.optString("originalUri", ""),
                                "mediaType"       to obj.optString("mediaType", "unknown"),
                                "fileTimestampMs" to obj.optLong("fileTimestampMs", 0L),
                                "sizeBytes"       to obj.optLong("sizeBytes", 0L),
                                "displayName"     to obj.optString("displayName", "")
                            )
                            if (obj.has("filePath")) entry["filePath"] = obj.optString("filePath")
                            list.add(entry)
                        } catch (e: Exception) {
                            Log.e(TAG, "Corrupt media queue entry $i: ${e.message}")
                        }
                    }
                    // Clear after successful parse
                    try {
                        val tmp = File(file.absolutePath + ".tmp")
                        tmp.writeText("[]")
                        if (!tmp.renameTo(file)) { file.delete(); if (!tmp.renameTo(file)) { file.writeText("[]"); tmp.delete() } }
                    } catch (e: Exception) {
                        Log.e(TAG, "Error clearing media queue (data safe): ${e.message}")
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "getMediaQueue error: ${e.message}")
            // Fallback without locking
            try {
                val json = file.readText().trim()
                if (json.isNotEmpty() && json != "[]") {
                    val arr = JSONArray(json)
                    for (i in 0 until arr.length()) {
                        try {
                            val obj = arr.getJSONObject(i)
                            val entry = mutableMapOf<String, Any?>(
                                "originalUri"     to obj.optString("originalUri", ""),
                                "mediaType"       to obj.optString("mediaType", "unknown"),
                                "fileTimestampMs" to obj.optLong("fileTimestampMs", 0L),
                                "sizeBytes"       to obj.optLong("sizeBytes", 0L),
                                "displayName"     to obj.optString("displayName", "")
                            )
                            if (obj.has("filePath")) entry["filePath"] = obj.optString("filePath")
                            list.add(entry)
                        } catch (_: Exception) {}
                    }
                    file.writeText("[]")
                }
            } catch (fb: Exception) {
                Log.e(TAG, "getMediaQueue fallback failed: ${fb.message}")
            }
        }
        return list
    }
}

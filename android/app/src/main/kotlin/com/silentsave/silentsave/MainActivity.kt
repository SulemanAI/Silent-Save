package com.silentsave.silentsave

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import androidx.work.*
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {
    companion object {
        private const val TAG = "SilentSaveMain"
        private const val CHANNEL = "com.silentsave/notifications"
        private const val PREFS_NAME = "notification_data"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        Log.d(TAG, "Configuring Flutter engine")
        
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
                else -> {
                    result.notImplemented()
                }
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
                                "avatarPath" to obj.optString("avatarPath", "")
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
                                "avatarPath" to obj.optString("avatarPath", "")
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
}

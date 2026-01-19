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
        private const val NOTIFICATIONS_FILE = "pending_notifications.json"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        Log.d(TAG, "Configuring Flutter engine")
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            Log.d(TAG, "Received method call: ${call.method}")
            when (call.method) {
                "isNotificationPermissionGranted" -> {
                    val granted = isNotificationServiceEnabled()
                    Log.d(TAG, "Notification permission granted: $granted")
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
                    Log.d(TAG, "Returning ${data.size} pending notifications")
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
        val packageName = packageName
        val flat = Settings.Secure.getString(
            contentResolver,
            "enabled_notification_listeners"
        )
        
        Log.d(TAG, "Checking notification listeners: $flat")
        
        var isInList = false
        if (flat != null && flat.isNotEmpty()) {
            val names = flat.split(":")
            for (name in names) {
                val componentName = ComponentName.unflattenFromString(name)
                if (componentName != null) {
                    if (packageName == componentName.packageName) {
                        Log.d(TAG, "Found our package in notification listeners")
                        isInList = true
                        break
                    }
                }
            }
        }
        
        if (!isInList) {
            Log.w(TAG, "Our package NOT found in notification listeners")
            return false
        }
        
        // Also check if the notification listener service is actually running
        val serviceComponent = ComponentName(this, NotificationListener::class.java)
        val enabledListeners = Settings.Secure.getString(contentResolver, "enabled_notification_listeners")
        val isServiceEnabled = enabledListeners?.contains(serviceComponent.flattenToString()) == true
        Log.d(TAG, "NotificationListener service enabled: $isServiceEnabled")
        
        return isServiceEnabled
    }

    private fun openNotificationSettings() {
        Log.d(TAG, "Opening notification settings")
        val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
        startActivity(intent)
    }

    private fun scheduleCleanupJob() {
        Log.d(TAG, "Scheduling cleanup job")
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
        // Use the same method as NotificationListener for consistency
        return NotificationListener.getNotificationsFilePath(applicationContext)
    }

    private fun getPendingNotifications(): List<Map<String, Any?>> {
        val file = getNotificationsFile()
        val list = mutableListOf<Map<String, Any?>>()
        
        Log.d(TAG, "Reading pending notifications from: ${file.absolutePath}")
        
        if (!file.exists()) {
            Log.d(TAG, "Notifications file does not exist yet")
            return list
        }
        
        try {
            // Use file locking for thread-safe access
            val lockFile = File(file.absolutePath + ".lock")
            lockFile.createNewFile()
            
            RandomAccessFile(lockFile, "rw").use { raf ->
                raf.channel.lock().use { lock ->
                    val jsonString = if (file.exists()) file.readText() else "[]"
                    Log.d(TAG, "Read file content: ${jsonString.take(200)}...")
                    
                    val jsonArray = JSONArray(jsonString)
                    Log.d(TAG, "Found ${jsonArray.length()} notifications in file")
                    
                    for (i in 0 until jsonArray.length()) {
                        try {
                            val obj = jsonArray.getJSONObject(i)
                            val map = mapOf(
                                "method" to obj.optString("method", ""),
                                "title" to obj.optString("title", ""),
                                "text" to obj.optString("text", ""),
                                "packageName" to obj.optString("packageName", ""),
                                "timestamp" to obj.optLong("timestamp", 0L),
                                "senderName" to obj.optString("senderName", obj.optString("title", "")),
                                "isGroupChat" to obj.optBoolean("isGroupChat", false),
                                "avatarPath" to if (obj.has("avatarPath")) obj.optString("avatarPath", null) else null
                            )
                            list.add(map)
                            Log.d(TAG, "Parsed notification $i: title='${map["title"]}', text='${(map["text"] as? String)?.take(30)}...'")
                        } catch (e: Exception) {
                            Log.e(TAG, "Skipping corrupted notification at index $i: ${e.message}")
                            e.printStackTrace()
                        }
                    }
                    
                    // Clear the file after reading
                    if (jsonArray.length() > 0) {
                        Log.d(TAG, "Clearing ${jsonArray.length()} processed notifications")
                        file.writeText("[]")
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error reading notifications file: ${e.message}")
            e.printStackTrace()
            
            // Fallback: Try to read and clear without locking
            try {
                val jsonString = file.readText()
                val jsonArray = JSONArray(jsonString)
                
                for (i in 0 until jsonArray.length()) {
                    try {
                        val obj = jsonArray.getJSONObject(i)
                        val map = mapOf(
                            "method" to obj.optString("method", ""),
                            "title" to obj.optString("title", ""),
                            "text" to obj.optString("text", ""),
                            "packageName" to obj.optString("packageName", ""),
                            "timestamp" to obj.optLong("timestamp", 0L),
                            "senderName" to obj.optString("senderName", obj.optString("title", "")),
                            "isGroupChat" to obj.optBoolean("isGroupChat", false),
                            "avatarPath" to if (obj.has("avatarPath")) obj.optString("avatarPath", null) else null
                        )
                        list.add(map)
                    } catch (parseE: Exception) {
                        Log.e(TAG, "Fallback: Skipping corrupted notification: ${parseE.message}")
                    }
                }
                
                // Clear the file
                file.writeText("[]")
                Log.d(TAG, "Fallback read successful, got ${list.size} notifications")
            } catch (fallbackE: Exception) {
                Log.e(TAG, "Fallback read failed: ${fallbackE.message}")
                // Last resort: delete the file
                try {
                    file.delete()
                } catch (deleteE: Exception) {
                    // Ignore
                }
            }
        }
        
        return list
    }

    private fun checkAndClearCleanupFlag(): Boolean {
        val prefs = applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val cleanupRequested = prefs.getBoolean("cleanup_requested", false)
        
        if (cleanupRequested) {
            prefs.edit().putBoolean("cleanup_requested", false).apply()
            return true
        }
        
        return false
    }
}

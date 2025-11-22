package com.silentsave.silentsave

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import androidx.work.*
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.silentsave/notifications"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isNotificationPermissionGranted" -> {
                    result.success(isNotificationServiceEnabled())
                }
                "openNotificationSettings" -> {
                    openNotificationSettings()
                    result.success(null)
                }
                "scheduleCleanupJob" -> {
                    scheduleCleanupJob()
                    result.success(null)
                }
                "getLatestNotification" -> {
                    val data = getLatestNotificationData()
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
        
        if (flat != null && flat.isNotEmpty()) {
            val names = flat.split(":")
            for (name in names) {
                val componentName = ComponentName.unflattenFromString(name)
                if (componentName != null) {
                    if (packageName == componentName.packageName) {
                        return true
                    }
                }
            }
        }
        return false
    }

    private fun openNotificationSettings() {
        val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
        startActivity(intent)
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

    private fun getLatestNotificationData(): Map<String, Any?>? {
        val prefs = getSharedPreferences("notification_data", Context.MODE_PRIVATE)
        val method = prefs.getString("method", null)
        
        if (method != null) {
            val data = mapOf(
                "method" to method,
                "title" to prefs.getString("title", ""),
                "text" to prefs.getString("text", ""),
                "packageName" to prefs.getString("packageName", ""),
                "timestamp" to prefs.getLong("timestamp", 0)
            )
            
            // Clear the data after reading
            prefs.edit().clear().apply()
            
            return data
        }
        
        return null
    }

    private fun checkAndClearCleanupFlag(): Boolean {
        val prefs = getSharedPreferences("notification_data", Context.MODE_PRIVATE)
        val cleanupRequested = prefs.getBoolean("cleanup_requested", false)
        
        if (cleanupRequested) {
            prefs.edit().putBoolean("cleanup_requested", false).apply()
            return true
        }
        
        return false
    }
}



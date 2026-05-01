package com.silentsave.silentsave

import android.content.ComponentName
import android.content.Context
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.util.Log
import androidx.work.*
import java.util.concurrent.TimeUnit

/**
 * WorkManager-based health check for NotificationListenerService.
 * 
 * OEM phones (Xiaomi, Samsung, Oppo, Vivo, Huawei) aggressively kill background
 * services even when they have system permissions. This worker runs every 15 minutes
 * to check if the NLS is still connected and request a rebind if needed.
 * 
 * WorkManager is more resilient to OEM battery optimizations than AlarmManager
 * or persistent services because it's part of Google Play Services.
 * 
 * This worker also ensures the KeepAliveService is running with an active WakeLock,
 * acting as a second line of defense against process death.
 */
class NlsHealthWorker(
    context: Context,
    workerParams: WorkerParameters
) : Worker(context, workerParams) {

    companion object {
        private const val TAG = "NlsHealthWorker"
        private const val WORK_NAME = "nls_health_check"

        /**
         * Schedule the periodic health check. Safe to call multiple times.
         * Uses REPLACE policy to ensure the worker is always freshly scheduled
         * with the latest configuration, preventing stale workers from accumulating.
         */
        fun schedule(context: Context) {
            val constraints = Constraints.Builder()
                .setRequiresBatteryNotLow(false) // Run even on low battery
                .build()

            val request = PeriodicWorkRequestBuilder<NlsHealthWorker>(
                15, TimeUnit.MINUTES // Minimum interval for periodic work
            )
                .setConstraints(constraints)
                .setInitialDelay(1, TimeUnit.MINUTES) // Start after 1 minute
                .setBackoffCriteria(
                    BackoffPolicy.LINEAR, // LINEAR is more predictable for health checks
                    1, TimeUnit.MINUTES
                )
                .build()

            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                WORK_NAME,
                ExistingPeriodicWorkPolicy.KEEP, // Don't replace existing
                request
            )

            Log.i(TAG, "NLS health check scheduled")
        }

        /**
         * Run an immediate one-time health check.
         * Uses expedited work to run as fast as possible.
         */
        fun runNow(context: Context) {
            val request = OneTimeWorkRequestBuilder<NlsHealthWorker>()
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .build()

            WorkManager.getInstance(context).enqueue(request)
            Log.i(TAG, "Immediate NLS health check queued (expedited)")
        }
    }

    override fun doWork(): Result {
        Log.d(TAG, "Running NLS health check...")

        try {
            // Check if NLS permission is still granted
            if (!isNlsEnabled()) {
                Log.w(TAG, "NLS permission not granted - cannot rebind")
                return Result.success()
            }

            // Ensure KeepAliveService is running — re-start if killed by system.
            // startForegroundService() will trigger onStartCommand() which re-acquires
            // the WakeLock, even if the service was already running.
            try {
                KeepAliveService.start(applicationContext)
                Log.d(TAG, "KeepAliveService ensured running")
            } catch (e: Exception) {
                Log.w(TAG, "Failed to start KeepAliveService: ${e.message}")
            }

            // Request rebind - this is safe even if already connected
            // Android will ignore the request if already bound
            requestNlsRebind()

            Log.d(TAG, "NLS health check complete")
            return Result.success()
        } catch (e: Exception) {
            Log.e(TAG, "NLS health check failed: ${e.message}")
            return Result.retry()
        }
    }

    private fun isNlsEnabled(): Boolean {
        val flat = Settings.Secure.getString(
            applicationContext.contentResolver,
            "enabled_notification_listeners"
        ) ?: return false

        val serviceComponent = ComponentName(applicationContext, NotificationListener::class.java)
        return flat.contains(serviceComponent.flattenToString())
    }

    private fun requestNlsRebind() {
        try {
            val componentName = ComponentName(applicationContext, NotificationListener::class.java)
            NotificationListenerService.requestRebind(componentName)
            Log.i(TAG, "Requested NLS rebind")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to request rebind: ${e.message}")
        }
    }
}

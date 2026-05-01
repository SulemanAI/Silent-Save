package com.silentsave.silentsave

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log

/**
 * Persistent foreground service whose only job is to keep the app process alive
 * so the NotificationListenerService (NLS) is never killed by OEM battery managers.
 *
 * Why this is necessary:
 * - Android's NLS is bound by the OS but runs in the *app's* process.
 * - OEM battery managers (Xiaomi MIUI, Samsung OneUI, Oppo ColorOS, etc.)
 *   kill app processes regardless of NLS binding.
 * - A foreground service with FOREGROUND_SERVICE_DATA_SYNC type keeps the
 *   process at a high OOM-adj level that OEMs rarely kill.
 *
 * This service shows a minimal persistent notification and holds a partial
 * WakeLock that is continuously renewed to prevent CPU sleep.
 *
 * Additionally, a self-ping AlarmManager alarm fires every 10 minutes to
 * restart this service if the system managed to kill it.
 */
class KeepAliveService : Service() {

    companion object {
        private const val TAG = "SilentSaveKeepAlive"
        private const val CHANNEL_ID = "silentsave_keepalive"
        private const val NOTIFICATION_ID = 9001
        private const val ALARM_REQUEST_CODE = 9002
        // Re-acquire WakeLock every 20 minutes (well before the 30-min safety-net timeout)
        private const val WAKELOCK_RENEW_INTERVAL_MS = 20L * 60 * 1000
        // Self-ping alarm every 10 minutes
        private const val SELF_PING_INTERVAL_MS = 10L * 60 * 1000

        fun start(context: Context) {
            val intent = Intent(context, KeepAliveService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                Log.i(TAG, "KeepAliveService start requested")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start KeepAliveService: ${e.message}")
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, KeepAliveService::class.java))
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private val handler = Handler(Looper.getMainLooper())

    // Runnable that continuously renews the WakeLock so the CPU never sleeps
    private val wakeLockRenewalRunnable = object : Runnable {
        override fun run() {
            acquireWakeLock()
            handler.postDelayed(this, WAKELOCK_RENEW_INTERVAL_MS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "KeepAliveService created")
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.i(TAG, "KeepAliveService onStartCommand")

        val notification = buildNotification()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID, notification,
                    android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            Log.e(TAG, "startForeground failed: ${e.message}")
            // Fallback: try without type
            try {
                startForeground(NOTIFICATION_ID, notification)
            } catch (e2: Exception) {
                Log.e(TAG, "startForeground fallback also failed: ${e2.message}")
            }
        }

        // Acquire WakeLock immediately and schedule continuous renewal
        acquireWakeLock()
        handler.removeCallbacks(wakeLockRenewalRunnable)
        handler.postDelayed(wakeLockRenewalRunnable, WAKELOCK_RENEW_INTERVAL_MS)

        // Schedule self-ping alarm to restart this service if killed
        scheduleSelfPingAlarm()

        // START_STICKY: If the system kills this service, restart it automatically
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * Called when the user swipes the app away from recents.
     * Re-schedule restart to survive task removal.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.w(TAG, "Task removed (app swiped away) — scheduling restart")
        scheduleSelfPingAlarm()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        Log.w(TAG, "KeepAliveService destroyed — requesting restart")
        handler.removeCallbacks(wakeLockRenewalRunnable)
        releaseWakeLock()
        cancelSelfPingAlarm()
        super.onDestroy()
        
        // Self-heal: re-schedule via WorkManager if destroyed
        try {
            NlsHealthWorker.runNow(applicationContext)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to trigger health check on destroy: ${e.message}")
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Message Capture",
                NotificationManager.IMPORTANCE_MIN // Minimal visual interruption
            ).apply {
                description = "Keeps message capture running in the background"
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_SECRET
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val openAppIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, openAppIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }.apply {
            setContentTitle("Silent Save")
            setContentText("Capturing messages in background")
            setSmallIcon(android.R.drawable.ic_lock_silent_mode) // Use built-in icon
            setContentIntent(pendingIntent)
            setOngoing(true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
            }
        }.build()
    }

    private fun acquireWakeLock() {
        try {
            if (wakeLock == null) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "SilentSave::KeepAliveWakeLock"
                ).apply {
                    setReferenceCounted(false)
                }
            }
            // 25-minute timeout — the renewal handler fires at 20 min,
            // giving a 5-minute overlap so the lock is never released.
            wakeLock?.acquire(25 * 60 * 1000L)
            Log.d(TAG, "WakeLock acquired/renewed")
        } catch (e: Exception) {
            Log.w(TAG, "WakeLock acquire failed: ${e.message}")
        }
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.let {
                if (it.isHeld) {
                    it.release()
                    Log.d(TAG, "WakeLock released")
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "WakeLock release failed: ${e.message}")
        }
    }

    /**
     * Schedule an inexact repeating alarm that re-starts this service every 10 minutes.
     * This survives process death — if the OEM kills the app, the AlarmManager still fires
     * and re-creates the service + foreground notification + WakeLock.
     */
    private fun scheduleSelfPingAlarm() {
        try {
            val am = getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val intent = Intent(this, KeepAliveService::class.java)
            val pi = PendingIntent.getService(
                this, ALARM_REQUEST_CODE, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            am.setInexactRepeating(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                SystemClock.elapsedRealtime() + SELF_PING_INTERVAL_MS,
                SELF_PING_INTERVAL_MS,
                pi
            )
            Log.d(TAG, "Self-ping alarm scheduled (every ${SELF_PING_INTERVAL_MS / 60000} min)")
        } catch (e: Exception) {
            Log.w(TAG, "Failed to schedule self-ping alarm: ${e.message}")
        }
    }

    private fun cancelSelfPingAlarm() {
        try {
            val am = getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val intent = Intent(this, KeepAliveService::class.java)
            val pi = PendingIntent.getService(
                this, ALARM_REQUEST_CODE, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            am.cancel(pi)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to cancel self-ping alarm: ${e.message}")
        }
    }
}

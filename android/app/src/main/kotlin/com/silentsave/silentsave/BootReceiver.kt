package com.silentsave.silentsave

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.util.Log

/**
 * Boot & Update Receiver: Ensures services are ready after device reboot or app update.
 *
 * Listens for:
 *  - BOOT_COMPLETED / LOCKED_BOOT_COMPLETED: device reboot
 *  - MY_PACKAGE_REPLACED: app update (restores services after APK install)
 *  - QUICKBOOT_POWERON: HTC/Xiaomi fast-boot
 *
 * Starts the KeepAliveService (foreground) to prevent OEM battery kill,
 * requests NLS rebind, and schedules periodic health checks.
 */
class BootReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "SilentSaveBoot"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        
        val isBootAction = action == Intent.ACTION_BOOT_COMPLETED ||
            action == Intent.ACTION_LOCKED_BOOT_COMPLETED ||
            action == Intent.ACTION_MY_PACKAGE_REPLACED ||
            action == "android.intent.action.QUICKBOOT_POWERON" ||
            action == "com.htc.intent.action.QUICKBOOT_POWERON"
        
        if (!isBootAction) return
        
        Log.i(TAG, "Receiver triggered — initializing SilentSave (action=$action)")

        // Check if notification listener permission is still granted
        val isNlsEnabled = isNotificationListenerEnabled(context)
        Log.i(TAG, "NLS enabled: $isNlsEnabled")

        if (isNlsEnabled) {
            val userManager = context.getSystemService(Context.USER_SERVICE) as? android.os.UserManager
            val isUnlocked = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                userManager?.isUserUnlocked ?: true
            } else true

            if (isUnlocked) {
                // Start KeepAlive foreground service FIRST — this keeps the process alive
                try {
                    KeepAliveService.start(context)
                    Log.i(TAG, "KeepAliveService started on boot/update")
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to start KeepAliveService: ${e.message}")
                }

                // Start MediaWatcherService — begins watching WhatsApp media folder
                try {
                    MediaWatcherService.start(context)
                    Log.i(TAG, "MediaWatcherService started on boot/update")
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to start MediaWatcherService: ${e.message}")
                }

                // Schedule the health worker to keep NLS alive
                NlsHealthWorker.schedule(context)
            } else {
                Log.i(TAG, "Device locked on boot (Direct Boot). Rebinding NLS; CE services deferred until unlock.")
            }
            
            // Request NLS rebind after boot (directBootAware service rebinds immediately)
            try {
                val componentName = ComponentName(context, NotificationListener::class.java)
                NotificationListenerService.requestRebind(componentName)
                Log.i(TAG, "Requested NLS rebind after boot/update")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to request rebind: ${e.message}")
            }
        }
    }

    private fun isNotificationListenerEnabled(context: Context): Boolean {
        val flat = Settings.Secure.getString(
            context.contentResolver,
            "enabled_notification_listeners"
        ) ?: return false

        val serviceComponent = ComponentName(context, NotificationListener::class.java)
        return flat.contains(serviceComponent.flattenToString())
    }
}

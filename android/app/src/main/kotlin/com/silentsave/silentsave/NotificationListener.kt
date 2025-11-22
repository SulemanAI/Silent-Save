package com.silentsave.silentsave

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.content.Context

class NotificationListener : NotificationListenerService() {
    
    private val WHATSAPP_PACKAGE = "com.whatsapp"
    private val INSTAGRAM_PACKAGE = "com.instagram.android"

    override fun onCreate() {
        super.onCreate()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null) return

        val packageName = sbn.packageName
        
        // Only process WhatsApp and Instagram notifications
        if (packageName != WHATSAPP_PACKAGE && packageName != INSTAGRAM_PACKAGE) {
            return
        }

        val notification = sbn.notification ?: return
        val extras = notification.extras ?: return

        // Skip summary notifications (like "3 new messages")
        val isGroupSummary = notification.flags and android.app.Notification.FLAG_GROUP_SUMMARY != 0
        if (isGroupSummary) {
            return
        }

        val title = extras.getCharSequence("android.title")?.toString() ?: ""
        val text = extras.getCharSequence("android.text")?.toString() ?: ""
        
        // Skip if title or text is empty
        if (title.isEmpty() || text.isEmpty()) {
            return
        }

        // Skip system/summary messages for WhatsApp
        if (packageName == WHATSAPP_PACKAGE) {
            // Filter out messages like "3 new messages", "WhatsApp", etc.
            if (text.matches(Regex("^\\d+\\s+(new\\s+)?(message|messages).*", RegexOption.IGNORE_CASE)) ||
                title.equals("WhatsApp", ignoreCase = true) ||
                text.contains("new messages", ignoreCase = true)) {
                return
            }
        }

        // Skip Instagram system notifications
        if (packageName == INSTAGRAM_PACKAGE) {
            if (title.contains("Instagram", ignoreCase = true) && 
                !text.contains(":")) {  // Message usually has ":" in it
                return
            }
        }

        val data = hashMapOf<String, Any>(
            "title" to title,
            "text" to text,
            "packageName" to packageName,
            "timestamp" to sbn.postTime
        )

        // Send to Flutter
        sendToFlutter("onNotificationReceived", data)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        if (sbn == null) return

        val packageName = sbn.packageName
        
        // Only process WhatsApp and Instagram notifications
        if (packageName != WHATSAPP_PACKAGE && packageName != INSTAGRAM_PACKAGE) {
            return
        }

        val notification = sbn.notification ?: return
        val extras = notification.extras ?: return

        val title = extras.getCharSequence("android.title")?.toString() ?: ""
        val text = extras.getCharSequence("android.text")?.toString() ?: ""

        val data = hashMapOf<String, Any>(
            "title" to title,
            "text" to text,
            "packageName" to packageName
        )

        // Send to Flutter
        sendToFlutter("onNotificationRemoved", data)
    }

    private fun sendToFlutter(method: String, data: HashMap<String, Any>) {
        try {
            // Try to get MainActivity's method channel
            // This is a simplified version - in production you might want to use a background
            // isolate or event channel for more reliable communication
            val intent = android.content.Intent(this, MainActivity::class.java)
            intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            intent.putExtra("method", method)
            intent.putExtra("data", data)
            
            // Store data in shared preferences for Flutter to retrieve
            val prefs = getSharedPreferences("notification_data", Context.MODE_PRIVATE)
            val editor = prefs.edit()
            editor.putString("method", method)
            editor.putString("title", data["title"] as? String ?: "")
            editor.putString("text", data["text"] as? String ?: "")
            editor.putString("packageName", data["packageName"] as? String ?: "")
            editor.putLong("timestamp", data["timestamp"] as? Long ?: System.currentTimeMillis())
            editor.apply()
            
            // Broadcast to Flutter
            val broadcastIntent = android.content.Intent("com.silentsave.NOTIFICATION_EVENT")
            broadcastIntent.putExtra("method", method)
            broadcastIntent.putExtra("title", data["title"] as? String ?: "")
            broadcastIntent.putExtra("text", data["text"] as? String ?: "")
            broadcastIntent.putExtra("packageName", data["packageName"] as? String ?: "")
            broadcastIntent.putExtra("timestamp", data["timestamp"] as? Long ?: System.currentTimeMillis())
            sendBroadcast(broadcastIntent)
            
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
}

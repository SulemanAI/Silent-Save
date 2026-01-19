package com.silentsave.silentsave

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.content.Context
import android.graphics.Bitmap
import android.graphics.drawable.Icon
import android.os.Build
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.channels.FileLock
import java.security.MessageDigest

class NotificationListener : NotificationListenerService() {
    
    companion object {
        private const val TAG = "SilentSaveNotif"
        private const val WHATSAPP_PACKAGE = "com.whatsapp"
        private const val WHATSAPP_BUSINESS_PACKAGE = "com.whatsapp.w4b"
        private const val INSTAGRAM_PACKAGE = "com.instagram.android"
        private const val NOTIFICATIONS_FILE = "pending_notifications.json"
        private const val AVATARS_DIR = "avatars"
        private const val MAX_QUEUE_SIZE = 500
        
        // Static method to get file path that can be used by both NotificationListener and MainActivity
        fun getNotificationsFilePath(context: Context): File {
            // Always use the app's private files directory
            return File(context.filesDir, NOTIFICATIONS_FILE)
        }
        
        // Get avatars directory path
        fun getAvatarsDir(context: Context): File {
            val dir = File(context.filesDir, AVATARS_DIR)
            if (!dir.exists()) {
                dir.mkdirs()
            }
            return dir
        }
    }

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "NotificationListener service created")
        // Log the file path for debugging
        try {
            val file = getNotificationsFile()
            Log.d(TAG, "Notifications will be saved to: ${file.absolutePath}")
        } catch (e: Exception) {
            Log.e(TAG, "Error getting notifications file path: ${e.message}")
        }
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        Log.d(TAG, "NotificationListener connected - ready to receive notifications")
        // Verify file access on connection
        try {
            val file = getNotificationsFile()
            if (!file.exists()) {
                file.writeText("[]")
                Log.d(TAG, "Created empty notifications file at: ${file.absolutePath}")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error initializing notifications file: ${e.message}")
        }
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        Log.w(TAG, "NotificationListener disconnected")
        // Request rebind to restore notification access
        // This helps on some Android versions that might disconnect the service
        try {
            requestRebind(android.content.ComponentName(this, NotificationListener::class.java))
            Log.d(TAG, "Requested rebind for NotificationListener")
        } catch (e: Exception) {
            Log.e(TAG, "Error requesting rebind: ${e.message}")
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        // Log EVERY notification to see what's coming in
        Log.d(TAG, ">>> onNotificationPosted called! Package: ${sbn?.packageName ?: "null"}")
        
        if (sbn == null) {
            Log.d(TAG, "Received null StatusBarNotification")
            return
        }

        val packageName = sbn.packageName
        
        // Log all packages for debugging
        Log.d(TAG, "Notification from package: $packageName")
        
        // Only process WhatsApp, WhatsApp Business, and Instagram notifications
        if (packageName != WHATSAPP_PACKAGE && 
            packageName != WHATSAPP_BUSINESS_PACKAGE && 
            packageName != INSTAGRAM_PACKAGE) {
            Log.d(TAG, "Skipping non-target package: $packageName")
            return
        }

        Log.d(TAG, "Processing notification from: $packageName")

        val notification = sbn.notification
        if (notification == null) {
            Log.d(TAG, "Notification object is null")
            return
        }
        
        val extras = notification.extras
        if (extras == null) {
            Log.d(TAG, "Notification extras is null")
            return
        }

        // Log all extras for debugging
        Log.d(TAG, "Notification extras keys: ${extras.keySet()}")
        
        // Log detailed extras for troubleshooting
        try {
            for (key in extras.keySet()) {
                val value = extras.get(key)
                val valueStr = when (value) {
                    is CharSequence -> value.toString().take(100)
                    is Array<*> -> "Array[${value.size}]"
                    else -> value?.toString()?.take(50) ?: "null"
                }
                Log.d(TAG, "  Extra[$key] = $valueStr")
            }
        } catch (e: Exception) {
            Log.d(TAG, "Error logging extras: ${e.message}")
        }

        // Use EXTRA_CONVERSATION_TITLE for group chats, fallback to android.title for individual chats
        val conversationTitle = extras.getCharSequence("android.conversationTitle")?.toString()
        val title = conversationTitle ?: extras.getCharSequence("android.title")?.toString() ?: ""
        
        Log.d(TAG, "Title: '$title', ConversationTitle: '$conversationTitle'")

        // Extract and save avatar (profile picture) from notification
        var avatarPath: String? = null
        try {
            Log.d(TAG, "Attempting to extract avatar for '$title'...")
            
            // Try to get the large icon (profile picture)
            val largeIcon = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val icon = notification.getLargeIcon()
                Log.d(TAG, "API 23+: getLargeIcon() returned: ${if (icon != null) "Icon object" else "null"}")
                icon
            } else {
                Log.d(TAG, "API < 23: Trying getParcelable for largeIcon")
                @Suppress("DEPRECATION")
                extras.getParcelable<Bitmap>("android.largeIcon")?.let { bitmap ->
                    Log.d(TAG, "Got bitmap from extras: ${bitmap.width}x${bitmap.height}")
                    // For older API, directly use the bitmap
                    avatarPath = saveAvatarBitmap(bitmap, title)
                    null
                }
            }
            
            // Also try to get bitmap directly from extras (works on some devices)
            if (avatarPath == null && largeIcon == null) {
                val bitmapFromExtras = extras.get("android.largeIcon")
                Log.d(TAG, "Fallback: android.largeIcon in extras is: ${bitmapFromExtras?.javaClass?.simpleName ?: "null"}")
                if (bitmapFromExtras is Bitmap) {
                    Log.d(TAG, "Got Bitmap directly from extras: ${bitmapFromExtras.width}x${bitmapFromExtras.height}")
                    avatarPath = saveAvatarBitmap(bitmapFromExtras, title)
                }
            }
            
            // Convert Icon to Bitmap and save (for API 23+)
            if (largeIcon != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                Log.d(TAG, "Converting Icon to Bitmap...")
                val drawable = largeIcon.loadDrawable(this)
                if (drawable != null) {
                    Log.d(TAG, "Drawable loaded: ${drawable.intrinsicWidth}x${drawable.intrinsicHeight}")
                    val bitmap = Bitmap.createBitmap(
                        drawable.intrinsicWidth.coerceAtLeast(1),
                        drawable.intrinsicHeight.coerceAtLeast(1),
                        Bitmap.Config.ARGB_8888
                    )
                    val canvas = android.graphics.Canvas(bitmap)
                    drawable.setBounds(0, 0, canvas.width, canvas.height)
                    drawable.draw(canvas)
                    avatarPath = saveAvatarBitmap(bitmap, title)
                    Log.d(TAG, "Avatar saved, path: $avatarPath")
                } else {
                    Log.d(TAG, "loadDrawable returned null!")
                }
            }
            
            if (avatarPath != null) {
                Log.d(TAG, "Successfully saved avatar for '$title' at: $avatarPath")
            } else {
                // Check if we already have an avatar for this sender
                Log.d(TAG, "No new avatar for '$title', checking for existing avatar...")
                val existingAvatarPath = getExistingAvatarPath(title)
                if (existingAvatarPath != null) {
                    avatarPath = existingAvatarPath
                    Log.d(TAG, "Using existing avatar for '$title' at: $avatarPath")
                } else {
                    Log.d(TAG, "No existing avatar found for '$title'")
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error extracting avatar: ${e.message}")
            e.printStackTrace()
        }

        // Try to get individual messages from EXTRA_TEXT_LINES (for bundled notifications)
        val textLines = extras.getCharSequenceArray("android.textLines")
        
        // Also try EXTRA_MESSAGES for messaging style notifications
        val messages = extras.getParcelableArray("android.messages")
        
        if (textLines != null && textLines.isNotEmpty()) {
            Log.d(TAG, "Found ${textLines.size} text lines")
            // Process each individual message from bundled notification
            for ((lineIndex, line) in textLines.withIndex()) {
                if (line.isNullOrEmpty()) continue
                
                val messageText = line.toString()
                Log.d(TAG, "Processing text line $lineIndex: '$messageText'")
                
                // Skip empty messages
                if (messageText.isBlank()) continue
                
                // For WhatsApp, skip only actual summary messages (not real messages)
                if (packageName == WHATSAPP_PACKAGE || packageName == WHATSAPP_BUSINESS_PACKAGE) {
                    if (isSummaryMessage(messageText)) {
                        Log.d(TAG, "Skipping summary message: '$messageText'")
                        continue
                    }
                }
                
                // For Instagram, also skip summary messages in text lines
                if (packageName == INSTAGRAM_PACKAGE) {
                    if (isSummaryMessage(messageText)) {
                        Log.d(TAG, "Skipping Instagram summary in text lines: '$messageText'")
                        continue
                    }
                }
                
                // For group chats, extract the sender name from the message line
                var actualSender = title
                var actualMessage = messageText
                
                if (conversationTitle != null && messageText.contains(":")) {
                    val colonIndex = messageText.indexOf(":")
                    if (colonIndex > 0 && colonIndex < messageText.length - 1) {
                        actualSender = messageText.substring(0, colonIndex).trim()
                        actualMessage = messageText.substring(colonIndex + 1).trim()
                    }
                }
                
                // Add a small offset to timestamp for each line to make them unique
                // This helps with duplicate detection
                val uniqueTimestamp = sbn.postTime + lineIndex
                
                saveNotification(
                    method = "onNotificationReceived",
                    title = title,
                    text = actualMessage,
                    packageName = packageName,
                    timestamp = uniqueTimestamp,
                    senderName = actualSender,
                    isGroupChat = conversationTitle != null,
                    avatarPath = avatarPath
                )
            }
        } else if (messages != null && messages.isNotEmpty()) {
            Log.d(TAG, "Found ${messages.size} messaging style messages")
            // Handle messaging style notifications (used by some apps including WhatsApp and Instagram)
            for ((msgIndex, msg) in messages.withIndex()) {
                try {
                    if (msg is android.os.Bundle) {
                        val msgText = msg.getCharSequence("text")?.toString() ?: ""
                        val msgSender = msg.getCharSequence("sender")?.toString() ?: title
                        // Try to get timestamp from message bundle, fallback to notification time + offset
                        val msgTime = msg.getLong("time", sbn.postTime + msgIndex)
                        
                        if (msgText.isNotBlank()) {
                            // Skip summary messages
                            if (isSummaryMessage(msgText)) {
                                Log.d(TAG, "Skipping summary in messaging style: '$msgText'")
                                continue
                            }
                            
                            Log.d(TAG, "Processing messaging style message from '$msgSender': '$msgText' at time $msgTime")
                            saveNotification(
                                method = "onNotificationReceived",
                                title = title,
                                text = msgText,
                                packageName = packageName,
                                timestamp = msgTime,
                                senderName = msgSender,
                                isGroupChat = conversationTitle != null,
                                avatarPath = avatarPath
                            )
                        }
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Error parsing messaging style: ${e.message}")
                }
            }
        } else {
            // Fallback to single message if EXTRA_TEXT_LINES is not available
            val text = extras.getCharSequence("android.text")?.toString() ?: ""
            val bigText = extras.getCharSequence("android.bigText")?.toString() ?: ""
            val subText = extras.getCharSequence("android.subText")?.toString() ?: ""
            val infoText = extras.getCharSequence("android.infoText")?.toString() ?: ""
            val summaryText = extras.getCharSequence("android.summaryText")?.toString() ?: ""
            
            // Use the longest non-empty text as the actual message
            var actualText = text
            if (bigText.isNotBlank() && bigText.length > actualText.length) actualText = bigText
            
            Log.d(TAG, "Single message mode - Text: '$text', BigText: '$bigText', SubText: '$subText', InfoText: '$infoText'")
            
            // Skip if title is empty
            if (title.isBlank()) {
                Log.d(TAG, "Skipping - empty title")
                return
            }
            
            // For media messages, WhatsApp might show text like "📷 Photo" or "🎤 Voice message"
            // We should capture these too
            if (actualText.isBlank()) {
                // Try to use subText or other text fields as fallback for media notifications
                if (subText.isNotBlank()) {
                    actualText = subText
                    Log.d(TAG, "Using subText as message: '$actualText'")
                } else if (infoText.isNotBlank()) {
                    actualText = infoText
                    Log.d(TAG, "Using infoText as message: '$actualText'")
                } else {
                    Log.d(TAG, "Skipping - empty text")
                    return
                }
            }

            // Skip system/summary messages for WhatsApp
            if (packageName == WHATSAPP_PACKAGE || packageName == WHATSAPP_BUSINESS_PACKAGE) {
                if (title.equals("WhatsApp", ignoreCase = true) || 
                    title.equals("WhatsApp Business", ignoreCase = true)) {
                    Log.d(TAG, "Skipping WhatsApp system notification")
                    return
                }
                if (isSummaryMessage(actualText)) {
                    Log.d(TAG, "Skipping WhatsApp summary message")
                    return
                }
            }

            // Handle Instagram notifications - capture DMs more aggressively
            if (packageName == INSTAGRAM_PACKAGE) {
                // Only skip pure system/summary notifications
                val isSystemNotification = title.equals("Instagram", ignoreCase = true) && 
                    (actualText.matches(Regex("^\\d+\\s+(new\\s+)?messages?.*", RegexOption.IGNORE_CASE)) ||
                     actualText.matches(Regex("^\\d+.*notifications?.*", RegexOption.IGNORE_CASE)) ||
                     actualText.matches(Regex("^You have \\d+ (new )?messages?", RegexOption.IGNORE_CASE)))
                
                if (isSystemNotification) {
                    Log.d(TAG, "Skipping Instagram system/summary notification: '$actualText'")
                    return
                }
                
                // Instagram DMs: title is usually sender name, text is message
                // Don't skip - capture this message!
                Log.d(TAG, "Instagram DM detected: sender='$title', message='$actualText'")
            }

            // For group chats, extract the sender name from the message text
            var actualSender = title
            var messageContent = actualText
            
            if (conversationTitle != null && actualText.contains(":")) {
                val colonIndex = actualText.indexOf(":")
                if (colonIndex > 0 && colonIndex < actualText.length - 1) {
                    actualSender = actualText.substring(0, colonIndex).trim()
                    messageContent = actualText.substring(colonIndex + 1).trim()
                }
            }

            saveNotification(
                method = "onNotificationReceived",
                title = title,
                text = messageContent,
                packageName = packageName,
                timestamp = sbn.postTime,
                senderName = actualSender,
                isGroupChat = conversationTitle != null,
                avatarPath = avatarPath
            )
        }
    }

    private fun isSummaryMessage(text: String): Boolean {
        // Be very strict - only match exact summary patterns, not messages that happen to contain numbers
        // Match patterns like "3 new messages", "5 messages from 2 chats", etc.
        // But NOT "3 pizzas please" or "I'll be there in 5 minutes"
        val trimmedText = text.trim()
        
        // Only exact matches for summary patterns
        val isSummary = trimmedText.matches(Regex("^\\d+\\s+(new\\s+)?messages?$", RegexOption.IGNORE_CASE)) ||
               trimmedText.matches(Regex("^\\d+\\s+messages?\\s+from\\s+\\d+\\s+chats?$", RegexOption.IGNORE_CASE)) ||
               trimmedText.matches(Regex("^\\d+\\s+unread\\s+messages?$", RegexOption.IGNORE_CASE)) ||
               trimmedText.matches(Regex("^You have \\d+ (new )?messages?$", RegexOption.IGNORE_CASE))
        
        if (isSummary) {
            Log.d(TAG, "Detected summary message: '$trimmedText'")
        }
        return isSummary
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        if (sbn == null) return

        val packageName = sbn.packageName
        
        // Only process WhatsApp and Instagram notifications
        if (packageName != WHATSAPP_PACKAGE && 
            packageName != WHATSAPP_BUSINESS_PACKAGE && 
            packageName != INSTAGRAM_PACKAGE) {
            return
        }

        val notification = sbn.notification ?: return
        val extras = notification.extras ?: return

        val conversationTitle = extras.getCharSequence("android.conversationTitle")?.toString()
        val title = conversationTitle ?: extras.getCharSequence("android.title")?.toString() ?: ""
        val text = extras.getCharSequence("android.text")?.toString() ?: ""

        Log.d(TAG, "Notification removed - Title: '$title'")

        saveNotification(
            method = "onNotificationRemoved",
            title = title,
            text = text,
            packageName = packageName,
            timestamp = sbn.postTime,
            senderName = title,
            isGroupChat = conversationTitle != null
        )
    }

    private fun getNotificationsFile(): File {
        // Use the companion object's static method for consistency
        return NotificationListener.getNotificationsFilePath(this)
    }
    
    // Save avatar bitmap to file and return the file path
    private fun saveAvatarBitmap(bitmap: Bitmap, senderName: String): String? {
        return try {
            val avatarsDir = getAvatarsDir(this)
            // Use MD5 hash of sender name for consistent filename
            val hash = MessageDigest.getInstance("MD5")
                .digest(senderName.toByteArray())
                .joinToString("") { "%02x".format(it) }
            val avatarFile = File(avatarsDir, "$hash.png")
            
            // Save the bitmap
            FileOutputStream(avatarFile).use { out ->
                bitmap.compress(Bitmap.CompressFormat.PNG, 90, out)
            }
            
            avatarFile.absolutePath
        } catch (e: Exception) {
            Log.e(TAG, "Error saving avatar: ${e.message}")
            null
        }
    }
    
    // Check if an avatar already exists for a sender and return the path
    private fun getExistingAvatarPath(senderName: String): String? {
        return try {
            val avatarsDir = getAvatarsDir(this)
            val hash = MessageDigest.getInstance("MD5")
                .digest(senderName.toByteArray())
                .joinToString("") { "%02x".format(it) }
            val avatarFile = File(avatarsDir, "$hash.png")
            
            if (avatarFile.exists()) {
                avatarFile.absolutePath
            } else {
                null
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error checking existing avatar: ${e.message}")
            null
        }
    }

    private fun saveNotification(
        method: String,
        title: String,
        text: String,
        packageName: String,
        timestamp: Long,
        senderName: String,
        isGroupChat: Boolean,
        avatarPath: String? = null
    ) {
        try {
            val file = getNotificationsFile()
            Log.d(TAG, "Saving notification to file: ${file.absolutePath}")
            
            // Use file locking for thread-safe access
            val lockFile = File(file.absolutePath + ".lock")
            lockFile.createNewFile()
            
            RandomAccessFile(lockFile, "rw").use { raf ->
                raf.channel.lock().use { lock ->
                    // Read existing notifications
                    var jsonArray: JSONArray
                    try {
                        val existingJson = if (file.exists()) file.readText() else "[]"
                        jsonArray = JSONArray(existingJson)
                        
                        // Limit queue size to prevent memory issues
                        while (jsonArray.length() >= MAX_QUEUE_SIZE) {
                            jsonArray.remove(0)
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Error parsing existing notifications, starting fresh: ${e.message}")
                        jsonArray = JSONArray()
                    }
                    
                    val jsonObject = JSONObject().apply {
                        put("method", method)
                        put("title", title)
                        put("text", text)
                        put("packageName", packageName)
                        put("timestamp", timestamp)
                        put("senderName", senderName)
                        put("isGroupChat", isGroupChat)
                        if (avatarPath != null) put("avatarPath", avatarPath)
                    }
                    
                    jsonArray.put(jsonObject)
                    
                    // Write back to file
                    file.writeText(jsonArray.toString())
                    
                    Log.d(TAG, "Saved notification: method=$method, title='$title', text='${text.take(50)}...' Total in queue: ${jsonArray.length()}")
                }
            }
            
        } catch (e: Exception) {
            Log.e(TAG, "Error in saveNotification: ${e.message}")
            e.printStackTrace()
            
            // Fallback: Try direct write without locking
            try {
                val file = getNotificationsFile()
                var jsonArray = JSONArray()
                
                try {
                    if (file.exists()) {
                        jsonArray = JSONArray(file.readText())
                    }
                } catch (parseError: Exception) {
                    Log.e(TAG, "Parse error in fallback, starting fresh")
                }
                
                val jsonObject = JSONObject().apply {
                    put("method", method)
                    put("title", title)
                    put("text", text)
                    put("packageName", packageName)
                    put("timestamp", timestamp)
                    put("senderName", senderName)
                    put("isGroupChat", isGroupChat)
                    if (avatarPath != null) put("avatarPath", avatarPath)
                }
                
                jsonArray.put(jsonObject)
                file.writeText(jsonArray.toString())
                
                Log.d(TAG, "Fallback save successful")
            } catch (fallbackError: Exception) {
                Log.e(TAG, "Fallback save failed: ${fallbackError.message}")
            }
        }
    }
}

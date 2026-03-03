package com.silentsave.silentsave

import android.app.Notification
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.security.MessageDigest

class NotificationListener : NotificationListenerService() {
    
    companion object {
        private const val TAG = "SilentSaveNotif"
        private const val WHATSAPP_PACKAGE = "com.whatsapp"
        private const val WHATSAPP_BUSINESS_PACKAGE = "com.whatsapp.w4b"
        private const val INSTAGRAM_PACKAGE = "com.instagram.android"
        private const val NOTIFICATIONS_FILE = "pending_notifications.json"
        private const val MAX_QUEUE_SIZE = 500
        
        // Dedup: Use LinkedHashSet for proper FIFO eviction order
        // Store SHA-256 hashes instead of full strings to save memory
        private val processedHashes = LinkedHashSet<String>()
        private const val MAX_PROCESSED_IDS = 3000
        
        // SharedPreferences for persistent dedup across service restarts
        private const val PREFS_NAME = "notification_dedup"
        private const val PREF_PROCESSED_IDS = "processed_ids"
        private const val MAX_PERSISTED_IDS = 1500
        
        // Pre-compiled regex patterns (created once, reused for every notification)
        private val COUNT_PATTERNS = listOf(
            Regex("^\\d+\\s+new\\s+messages?$", RegexOption.IGNORE_CASE),
            Regex("^\\d+\\s+messages?\\s+from\\s+\\d+\\s+chats?$", RegexOption.IGNORE_CASE),
            Regex("^\\d+\\s+unread\\s+messages?$", RegexOption.IGNORE_CASE),
            Regex("^\\d+\\s+messages?$", RegexOption.IGNORE_CASE),
            Regex("^\\d+\\s+new\\s+notification.*$", RegexOption.IGNORE_CASE)
        )
        
        private val SUMMARY_PATTERNS = listOf(
            Regex("^Check your messages$", RegexOption.IGNORE_CASE),
            Regex("^You have new messages?$", RegexOption.IGNORE_CASE),
            Regex("^typing\\.\\.\\.$", RegexOption.IGNORE_CASE),
            Regex("^Incoming (voice|video) call$", RegexOption.IGNORE_CASE),
            Regex("^Missed (voice|video) call$", RegexOption.IGNORE_CASE),
            Regex("^Ongoing (voice|video) call$", RegexOption.IGNORE_CASE),
            Regex("^Ringing\\.\\.\\.?$", RegexOption.IGNORE_CASE),
            Regex("^Status from .+$", RegexOption.IGNORE_CASE),
            Regex("^New status updates?$", RegexOption.IGNORE_CASE),
            Regex("^Backup in progress.*$", RegexOption.IGNORE_CASE),
            Regex("^Checking for new messages.*$", RegexOption.IGNORE_CASE),
            Regex("^Waiting for network.*$", RegexOption.IGNORE_CASE),
            Regex("^Connecting.*$", RegexOption.IGNORE_CASE),
            Regex("^WhatsApp Web is currently active$", RegexOption.IGNORE_CASE),
            Regex("^WhatsApp Web.*$", RegexOption.IGNORE_CASE),
            Regex("^End-to-end encrypted$", RegexOption.IGNORE_CASE)
        )
        
        // Regex to strip WhatsApp's dynamic unread count suffix from group titles
        // Matches patterns like: " (5 messages)", " (2 new messages)", " (12 messages)"
        private val GROUP_NAME_COUNT_SUFFIX = Regex("""\s*\(\d+\s+(?:new\s+)?messages?\)\s*$""", RegexOption.IGNORE_CASE)

        /**
         * Clean the group/conversation name by:
         * 1. Trying EXTRA_CONVERSATION_TITLE from extras (native, clean title)
         * 2. Stripping WhatsApp's dynamic " (X messages)" suffix via regex fallback
         *
         * This prevents the app from treating "Group (2 messages)" and
         * "Group (5 messages)" as different conversations.
         */
        fun cleanGroupName(rawTitle: String, extras: Bundle? = null): String {
            // Native approach: try android.conversationTitle first —
            // on some WhatsApp versions this is the clean, static name
            // However, WhatsApp often puts the count IN the conversationTitle too,
            // so we still need the regex fallback.
            val cleaned = GROUP_NAME_COUNT_SUFFIX.replace(rawTitle, "").trim()
            return if (cleaned.isNotEmpty()) cleaned else rawTitle.trim()
        }

        // Target packages set for O(1) lookup
        private val TARGET_PACKAGES = setOf(
            WHATSAPP_PACKAGE,
            WHATSAPP_BUSINESS_PACKAGE,
            INSTAGRAM_PACKAGE
        )
        
        fun getNotificationsFilePath(context: Context): File {
            return File(context.filesDir, NOTIFICATIONS_FILE)
        }

        fun getAvatarsDir(context: Context): File {
            val dir = File(context.filesDir, "avatars")
            if (!dir.exists()) dir.mkdirs()
            return dir
        }
        
        /**
         * Compute a short SHA-256 hash of the dedup key to save memory.
         * Full text strings in a set of 3000 can consume significant memory;
         * 12-char hex hashes are fixed-size and collision-resistant enough.
         */
        private fun computeHash(input: String): String {
            return try {
                val digest = MessageDigest.getInstance("SHA-256")
                val bytes = digest.digest(input.toByteArray(Charsets.UTF_8))
                // Use first 12 hex chars (48 bits) — collision probability is negligible
                bytes.take(6).joinToString("") { "%02x".format(it) }
            } catch (e: Exception) {
                // Fallback: use hashCode if SHA is somehow unavailable
                input.hashCode().toUInt().toString(16)
            }
        }
    }

    private lateinit var dedupPrefs: SharedPreferences
    // Track how many messages saved since last persist, to batch disk writes
    private var savesSinceLastPersist = 0

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "=== NotificationListener service CREATED ===")
        
        dedupPrefs = applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        restoreProcessedIds()
        
        try {
            val file = getNotificationsFile()
            Log.i(TAG, "Notifications file: ${file.absolutePath}")
            // Ensure file exists and is valid JSON
            ensureValidNotificationsFile(file)
        } catch (e: Exception) {
            Log.e(TAG, "Error initializing notifications file: ${e.message}")
        }
    }
    
    /**
     * Ensure the notifications file exists and contains valid JSON.
     * Recover from corruption by resetting to empty array.
     */
    private fun ensureValidNotificationsFile(file: File) {
        try {
            if (!file.exists()) {
                file.writeText("[]")
                return
            }
            // Verify it's valid JSON
            val content = file.readText().trim()
            if (content.isEmpty()) {
                file.writeText("[]")
                return
            }
            JSONArray(content) // Will throw if invalid
        } catch (e: Exception) {
            Log.w(TAG, "Notifications file was corrupted, resetting: ${e.message}")
            try {
                file.writeText("[]")
            } catch (writeErr: Exception) {
                Log.e(TAG, "Cannot write notifications file: ${writeErr.message}")
            }
        }
    }
    
    /**
     * Restore dedup hashes from SharedPreferences so we survive service restarts.
     */
    private fun restoreProcessedIds() {
        try {
            val savedIds = dedupPrefs.getStringSet(PREF_PROCESSED_IDS, null)
            if (savedIds != null && savedIds.isNotEmpty()) {
                synchronized(processedHashes) {
                    processedHashes.addAll(savedIds)
                }
                Log.i(TAG, "Restored ${savedIds.size} dedup hashes from disk")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error restoring dedup hashes: ${e.message}")
        }
    }
    
    /**
     * Persist dedup hashes to SharedPreferences.
     * Called periodically and on lifecycle events.
     */
    private fun persistProcessedIds() {
        try {
            val snapshot: Set<String>
            synchronized(processedHashes) {
                // Keep only the most recent entries
                snapshot = if (processedHashes.size > MAX_PERSISTED_IDS) {
                    processedHashes.toList()
                        .takeLast(MAX_PERSISTED_IDS)
                        .toHashSet()
                } else {
                    HashSet(processedHashes)
                }
            }
            // Must create a new HashSet copy — SharedPreferences ignores writes
            // if the reference is the same Set it already stored
            dedupPrefs.edit().putStringSet(PREF_PROCESSED_IDS, HashSet(snapshot)).apply()
            savesSinceLastPersist = 0
        } catch (e: Exception) {
            Log.e(TAG, "Error persisting dedup hashes: ${e.message}")
        }
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        Log.i(TAG, "=== NotificationListener CONNECTED ===")
        
        try {
            val file = getNotificationsFile()
            ensureValidNotificationsFile(file)
        } catch (e: Exception) {
            Log.e(TAG, "Error on connect: ${e.message}")
        }
        
        try {
            val count = activeNotifications?.size ?: 0
            Log.i(TAG, "Active notifications on connect: $count")
        } catch (e: Exception) {
            Log.e(TAG, "Error reading active notifications: ${e.message}")
        }
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        Log.w(TAG, "=== NotificationListener DISCONNECTED ===")
        
        persistProcessedIds()
        
        try {
            requestRebind(android.content.ComponentName(this, NotificationListener::class.java))
            Log.i(TAG, "Requested rebind")
        } catch (e: Exception) {
            Log.e(TAG, "Error requesting rebind: ${e.message}")
        }
    }
    
    override fun onDestroy() {
        persistProcessedIds()
        super.onDestroy()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null) return
        
        val packageName = sbn.packageName ?: return
        
        // O(1) package check
        if (packageName !in TARGET_PACKAGES) return

        val notification = sbn.notification ?: return
        
        // Skip group summaries
        if ((notification.flags and Notification.FLAG_GROUP_SUMMARY) != 0) return
        
        val extras = notification.extras ?: return

        // Extract core fields — clean the group name to remove dynamic count suffixes
        val rawConversationTitle = extras.getCharSequence("android.conversationTitle")?.toString()
        val rawAndroidTitle = extras.getCharSequence("android.title")?.toString() ?: ""
        val rawTitle = rawConversationTitle ?: rawAndroidTitle
        val title = cleanGroupName(rawTitle, extras)
        
        // Skip system/empty notifications
        if (!shouldProcessNotification(packageName, title, extras)) return
        
        val isGroupChat = rawConversationTitle != null
        
        // Extract and save the profile picture from the notification
        // For groups: saves group DP (from large icon). For personal: saves sender DP.
        val avatarPath = extractAndSaveAvatar(notification, extras, title, packageName, isGroupChat)
        
        // Process in priority order
        // If MessagingStyle exists, use it exclusively (even if all messages were deduped)
        // to prevent fallthrough to less reliable methods that could cause duplicates
        val msgStyleResult = processMessagingStyleAll(extras, title, packageName, sbn.postTime, isGroupChat, avatarPath)
        val processed = if (msgStyleResult != 0) {
            // MessagingStyle had content — don't fallthrough
            maxOf(msgStyleResult, 0)
        } else {
            // No MessagingStyle — try other extraction methods
            val textResult = processTextLinesAll(extras, title, packageName, sbn.postTime, isGroupChat, avatarPath)
            if (textResult != 0) {
                maxOf(textResult, 0)
            } else {
                processRemoteInputLatest(extras, title, packageName, sbn.postTime, isGroupChat, avatarPath)
                    .takeIf { it > 0 }
                    ?: processSingleMessage(extras, title, packageName, sbn.postTime, isGroupChat, avatarPath)
            }
        }
        
        if (processed > 0) {
            Log.i(TAG, "✓ Processed $processed message(s) from $packageName")
        }
    }

    /**
     * Determine if a notification should be processed based on package and title.
     */
    private fun shouldProcessNotification(packageName: String, title: String, extras: Bundle): Boolean {
        if (packageName != INSTAGRAM_PACKAGE) {
            // WhatsApp: skip blank, "WhatsApp", "WhatsApp Business" titles
            if (title.isBlank() || 
                title.equals("WhatsApp", ignoreCase = true) || 
                title.equals("WhatsApp Business", ignoreCase = true)) {
                return false
            }
        } else {
            // Instagram: skip blank titles
            if (title.isBlank()) return false
            // Skip pure summary Instagram notifications
            if (title.equals("Instagram", ignoreCase = true)) {
                val text = extras.getCharSequence("android.text")?.toString() ?: ""
                if (text.isBlank() || isCountSummaryMessage(text)) return false
            }
        }
        return true
    }

    // ══════════════════════════════════════════════════════════════════════
    // MESSAGE EXTRACTION — Only process the LATEST message from each source
    // ══════════════════════════════════════════════════════════════════════
    
    /**
     * MessagingStyle: Process ONLY the LAST message.
     * 
     * WhatsApp/Instagram include ALL recent messages in android.messages
     * every time the notification updates. Processing all of them was the
     * root cause of the duplicate flood that killed message capture.
     */
    /**
     * Extract and save avatar for the conversation.
     * For GROUP chats: saves the group DP (from notification large icon).
     * For PERSONAL chats: saves the sender DP (from messaging style person, then large icon).
     * Returns the file path or null if no avatar could be extracted.
     */
    private fun extractAndSaveAvatar(
        notification: Notification, extras: Bundle, 
        title: String, packageName: String,
        isGroupChat: Boolean
    ): String? {
        try {
            val safeTitle = title.replace(Regex("[^a-zA-Z0-9_-]"), "_").take(50)
            val appPrefix = when {
                packageName.contains("whatsapp") -> "wa"
                packageName.contains("instagram") -> "ig"
                else -> "other"
            }
            val fileName = "${appPrefix}_${safeTitle}.png"
            val avatarsDir = getAvatarsDir(applicationContext)
            val avatarFile = File(avatarsDir, fileName)
            
            // If avatar already saved and recent (< 24h), reuse it
            if (avatarFile.exists() && 
                System.currentTimeMillis() - avatarFile.lastModified() < 24 * 60 * 60 * 1000) {
                return avatarFile.absolutePath
            }

            var bitmap: Bitmap? = null

            if (isGroupChat) {
                // For GROUP chats: use notification large icon (this is the GROUP DP)
                // Do NOT use sender_person here — that gives the individual sender's DP
                
                // Method 1: Notification large icon (group DP)
                try {
                    val largeIcon = notification.getLargeIcon()
                    if (largeIcon != null) {
                        val drawable = largeIcon.loadDrawable(applicationContext)
                        if (drawable is BitmapDrawable) {
                            bitmap = drawable.bitmap
                        }
                    }
                } catch (e: Exception) {
                    Log.d(TAG, "Large icon extraction failed: ${e.message}")
                }

                // Method 2: Legacy large icon bitmap
                if (bitmap == null) {
                    try {
                        @Suppress("DEPRECATION")
                        bitmap = extras.getParcelable<Bitmap>("android.largeIcon")
                    } catch (e: Exception) {
                        Log.d(TAG, "Legacy largeIcon extraction failed: ${e.message}")
                    }
                }
            } else {
                // For PERSONAL chats: prefer sender_person (most accurate individual DP)
                
                // Method 1: MessagingStyle Person icon
                try {
                    val messages = extras.getParcelableArray("android.messages")
                    if (messages != null && messages.isNotEmpty()) {
                        val lastMsg = messages.last() as? Bundle
                        val senderPerson = lastMsg?.getParcelable<android.app.Person>("sender_person")
                        val icon = senderPerson?.icon
                        if (icon != null) {
                            val drawable = icon.loadDrawable(applicationContext)
                            if (drawable is BitmapDrawable) {
                                bitmap = drawable.bitmap
                            }
                        }
                    }
                } catch (e: Exception) {
                    Log.d(TAG, "MessagingStyle avatar extraction failed: ${e.message}")
                }

                // Method 2: Notification large icon
                if (bitmap == null) {
                    try {
                        val largeIcon = notification.getLargeIcon()
                        if (largeIcon != null) {
                            val drawable = largeIcon.loadDrawable(applicationContext)
                            if (drawable is BitmapDrawable) {
                                bitmap = drawable.bitmap
                            }
                        }
                    } catch (e: Exception) {
                        Log.d(TAG, "Large icon extraction failed: ${e.message}")
                    }
                }

                // Method 3: Legacy large icon bitmap
                if (bitmap == null) {
                    try {
                        @Suppress("DEPRECATION")
                        bitmap = extras.getParcelable<Bitmap>("android.largeIcon")
                    } catch (e: Exception) {
                        Log.d(TAG, "Legacy largeIcon extraction failed: ${e.message}")
                    }
                }
            }

            // Save bitmap to file
            if (bitmap != null && bitmap.width > 1 && bitmap.height > 1) {
                FileOutputStream(avatarFile).use { fos ->
                    bitmap.compress(Bitmap.CompressFormat.PNG, 90, fos)
                    fos.flush()
                }
                Log.d(TAG, "Avatar saved: $fileName (group=$isGroupChat)")
                return avatarFile.absolutePath
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error extracting avatar: ${e.message}")
        }
        return null
    }

    /**
     * Extract and save a sender-specific avatar from a messaging style message bundle.
     * Used for group chats to show individual sender DPs in message bubbles.
     * Saved with "_sender_" prefix to distinguish from group/conversation avatars.
     */
    private fun extractAndSaveSenderAvatar(
        messageBundle: Bundle, senderName: String, packageName: String
    ): String? {
        try {
            val senderPerson = messageBundle.getParcelable<android.app.Person>("sender_person")
            val icon = senderPerson?.icon ?: return null
            val drawable = icon.loadDrawable(applicationContext) ?: return null
            val bitmap = (drawable as? BitmapDrawable)?.bitmap ?: return null
            
            if (bitmap.width <= 1 || bitmap.height <= 1) return null
            
            val safeName = senderName.replace(Regex("[^a-zA-Z0-9_-]"), "_").take(50)
            val appPrefix = when {
                packageName.contains("whatsapp") -> "wa"
                packageName.contains("instagram") -> "ig"
                else -> "other"
            }
            val fileName = "${appPrefix}_sender_${safeName}.png"
            val avatarsDir = getAvatarsDir(applicationContext)
            val avatarFile = File(avatarsDir, fileName)
            
            // Cache: skip if saved recently (< 24h)
            if (avatarFile.exists() && 
                System.currentTimeMillis() - avatarFile.lastModified() < 24 * 60 * 60 * 1000) {
                return avatarFile.absolutePath
            }
            
            FileOutputStream(avatarFile).use { fos ->
                bitmap.compress(Bitmap.CompressFormat.PNG, 90, fos)
                fos.flush()
            }
            Log.d(TAG, "Sender avatar saved: $fileName")
            return avatarFile.absolutePath
        } catch (e: Exception) {
            Log.d(TAG, "Error saving sender avatar: ${e.message}")
        }
        return null
    }

    /**
     * MessagingStyle: Process ALL unseen messages from the bundle in a single
     * batch file write.
     * 
     * WhatsApp/Instagram include ALL recent messages in android.messages
     * every time the notification updates. We iterate through all of them,
     * dedup in-memory, then write all new messages to the queue file in ONE
     * lock/write operation instead of N separate ones. This is critical for
     * bulk notifications — individual writes caused main-thread stalls and
     * potential message loss when Android killed the service for being slow.
     * 
     * Returns: >0 = messages saved, -1 = had valid messages but all deduped, 0 = no messaging style data
     */
    private fun processMessagingStyleAll(
        extras: Bundle, title: String, packageName: String,
        postTime: Long, isGroupChat: Boolean, avatarPath: String? = null
    ): Int {
        try {
            val messages = extras.getParcelableArray("android.messages")
            if (messages.isNullOrEmpty()) return 0
            
            val toSave = mutableListOf<JSONObject>()
            var hadValidMessages = false
            
            for (msg in messages) {
                val bundle = msg as? Bundle ?: continue
                
                val msgText = bundle.getCharSequence("text")?.toString()
                if (msgText.isNullOrBlank() || isSummaryMessage(msgText)) continue
                
                hadValidMessages = true
                
                val msgSender = bundle.getCharSequence("sender")?.toString()
                val senderPerson = try {
                    bundle.getParcelable<android.app.Person>("sender_person")
                } catch (e: Exception) { null }
                val senderName = msgSender ?: senderPerson?.name?.toString() ?: title
                val msgTime = bundle.getLong("time", postTime)
                
                // Dedup check
                val dedupKey = "$title|$msgText|$msgTime"
                val hash = computeHash(dedupKey)
                
                val isDuplicate = synchronized(processedHashes) {
                    if (processedHashes.contains(hash)) {
                        true
                    } else {
                        processedHashes.add(hash)
                        while (processedHashes.size > MAX_PROCESSED_IDS) {
                            val iterator = processedHashes.iterator()
                            if (iterator.hasNext()) { iterator.next(); iterator.remove() }
                        }
                        false
                    }
                }
                
                if (isDuplicate) continue
                
                // For group chats, extract and save sender-specific avatar
                if (isGroupChat) {
                    extractAndSaveSenderAvatar(bundle, senderName, packageName)
                }
                
                toSave.add(JSONObject().apply {
                    put("method", "onNotificationReceived")
                    put("title", title)
                    put("text", msgText)
                    put("packageName", packageName)
                    put("timestamp", msgTime)
                    put("senderName", senderName)
                    put("isGroupChat", isGroupChat)
                    if (avatarPath != null) put("avatarPath", avatarPath)
                })
            }
            
            if (toSave.isNotEmpty()) {
                val saved = saveNotificationsBatch(toSave)
                savesSinceLastPersist += saved
                if (savesSinceLastPersist >= 15) persistProcessedIds()
                return saved
            }
            
            // Return -1 if had valid messages but all were deduped,
            // to prevent fallthrough to less reliable extraction methods
            return if (hadValidMessages) -1 else 0
        } catch (e: Exception) {
            Log.e(TAG, "Error in processMessagingStyleAll: ${e.message}")
            return 0
        }
    }

    /**
     * TextLines: Process ALL lines in a batch.
     * 
     * TextLines don't have per-message timestamps, so we use content-based
     * dedup keys to avoid re-saving messages across notification re-posts.
     * Returns: >0 = saved, -1 = all deduped, 0 = no data
     */
    private fun processTextLinesAll(
        extras: Bundle, title: String, packageName: String,
        postTime: Long, isGroupChat: Boolean, avatarPath: String? = null
    ): Int {
        try {
            val textLines = extras.getCharSequenceArray("android.textLines")
            if (textLines.isNullOrEmpty()) return 0
            
            val toSave = mutableListOf<JSONObject>()
            var hadValidLines = false
            
            for ((index, line) in textLines.withIndex()) {
                val lineText = line?.toString()
                if (lineText.isNullOrBlank() || isSummaryMessage(lineText)) continue
                
                hadValidLines = true
                
                val (senderName, actualMessage) = extractSenderFromText(lineText, title, isGroupChat)
                
                // Use title+text+index as dedup key (no per-message timestamp available)
                val dedupKey = "textline|$title|$actualMessage|$index"
                val hash = computeHash(dedupKey)
                
                val isDuplicate = synchronized(processedHashes) {
                    if (processedHashes.contains(hash)) {
                        true
                    } else {
                        processedHashes.add(hash)
                        while (processedHashes.size > MAX_PROCESSED_IDS) {
                            val iterator = processedHashes.iterator()
                            if (iterator.hasNext()) { iterator.next(); iterator.remove() }
                        }
                        false
                    }
                }
                
                if (isDuplicate) continue
                
                toSave.add(JSONObject().apply {
                    put("method", "onNotificationReceived")
                    put("title", title)
                    put("text", actualMessage)
                    put("packageName", packageName)
                    put("timestamp", postTime + index) // offset by index to differentiate in DB dedup
                    put("senderName", senderName)
                    put("isGroupChat", isGroupChat)
                    if (avatarPath != null) put("avatarPath", avatarPath)
                })
            }
            
            if (toSave.isNotEmpty()) {
                val saved = saveNotificationsBatch(toSave)
                savesSinceLastPersist += saved
                if (savesSinceLastPersist >= 15) persistProcessedIds()
                return saved
            }
            
            return if (hadValidLines) -1 else 0
        } catch (e: Exception) {
            Log.e(TAG, "Error in processTextLinesAll: ${e.message}")
            return 0
        }
    }

    /**
     * RemoteInputHistory: Process ONLY the FIRST item (newest, reverse-chronological).
     */
    private fun processRemoteInputLatest(
        extras: Bundle, title: String, packageName: String,
        postTime: Long, isGroupChat: Boolean, avatarPath: String? = null
    ): Int {
        try {
            val history = extras.getCharSequenceArray("android.remoteInputHistory")
            if (history.isNullOrEmpty()) return 0
            
            val newest = history.first()?.toString()
            if (newest.isNullOrBlank()) return 0
            
            return saveNotification(
                method = "onNotificationReceived",
                title = title, text = newest,
                packageName = packageName, timestamp = postTime,
                senderName = title, isGroupChat = isGroupChat,
                avatarPath = avatarPath
            )
        } catch (e: Exception) {
            Log.e(TAG, "Error in processRemoteInputLatest: ${e.message}")
            return 0
        }
    }

    /**
     * Fallback single message extraction from various notification extras.
     */
    private fun processSingleMessage(
        extras: Bundle, title: String, packageName: String,
        postTime: Long, isGroupChat: Boolean, avatarPath: String? = null
    ): Int {
        var text = extras.getCharSequence("android.text")?.toString() ?: ""
        val bigText = extras.getCharSequence("android.bigText")?.toString() ?: ""
        val tickerText = extras.getCharSequence("android.tickerText")?.toString() ?: ""
        val subText = extras.getCharSequence("android.subText")?.toString() ?: ""
        val infoText = extras.getCharSequence("android.infoText")?.toString() ?: ""
        
        // Prefer bigText if it's richer, then try fallbacks
        if (bigText.isNotBlank() && bigText.length > text.length) text = bigText
        if (text.isBlank()) text = listOf(tickerText, subText, infoText).firstOrNull { it.isNotBlank() } ?: ""
        if (text.isBlank() || isCountSummaryMessage(text)) return 0
        
        // Instagram with title="Instagram": extract sender from text
        if (packageName == INSTAGRAM_PACKAGE && title.equals("Instagram", ignoreCase = true)) {
            val (sender, message) = extractSenderFromText(text, title, false)
            val resolvedTitle = if (sender != "Instagram") sender else title
            return saveNotification(
                method = "onNotificationReceived",
                title = resolvedTitle, text = message,
                packageName = packageName, timestamp = postTime,
                senderName = sender, isGroupChat = false,
                avatarPath = avatarPath
            )
        }
        
        val (senderName, actualMessage) = extractSenderFromText(text, title, isGroupChat)
        
        return saveNotification(
            method = "onNotificationReceived",
            title = title, text = actualMessage,
            packageName = packageName, timestamp = postTime,
            senderName = senderName, isGroupChat = isGroupChat,
            avatarPath = avatarPath
        )
    }

    // ══════════════════════════════════════════════════════════════════════
    // UTILITY METHODS
    // ══════════════════════════════════════════════════════════════════════
    
    /**
     * Extract sender name from "SenderName: message" format commonly used in group chats.
     */
    private fun extractSenderFromText(text: String, defaultSender: String, isGroupChat: Boolean): Pair<String, String> {
        if (!isGroupChat || !text.contains(":")) return Pair(defaultSender, text)
        
        val colonIndex = text.indexOf(":")
        if (colonIndex <= 0 || colonIndex >= text.length - 1) return Pair(defaultSender, text)
        
        val potentialSender = text.substring(0, colonIndex).trim()
        if (potentialSender.length > 50) return Pair(defaultSender, text)
        
        return Pair(potentialSender, text.substring(colonIndex + 1).trim())
    }
    
    private fun isCountSummaryMessage(text: String): Boolean {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return true
        return COUNT_PATTERNS.any { it.matches(trimmed) }
    }
    
    private fun isSummaryMessage(text: String): Boolean {
        val trimmed = text.trim()
        if (trimmed.isEmpty() || trimmed.length < 2) return true
        if (isCountSummaryMessage(trimmed)) return true
        return SUMMARY_PATTERNS.any { it.matches(trimmed) }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        if (sbn == null) return
        val packageName = sbn.packageName ?: return
        if (packageName !in TARGET_PACKAGES) return

        val notification = sbn.notification ?: return
        val extras = notification.extras ?: return

        val rawConversationTitle = extras.getCharSequence("android.conversationTitle")?.toString()
        val rawTitle = rawConversationTitle ?: extras.getCharSequence("android.title")?.toString() ?: ""
        val title = cleanGroupName(rawTitle, extras)
        val text = extras.getCharSequence("android.text")?.toString() ?: ""

        if (title.isNotBlank() && 
            !title.equals("WhatsApp", ignoreCase = true) &&
            !title.equals("WhatsApp Business", ignoreCase = true)) {
            saveNotification(
                method = "onNotificationRemoved",
                title = title, text = text,
                packageName = packageName, timestamp = sbn.postTime,
                senderName = title, isGroupChat = rawConversationTitle != null
            )
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // FILE I/O — Atomic writes with deduplication
    // ══════════════════════════════════════════════════════════════════════

    private fun getNotificationsFile(): File = getNotificationsFilePath(this)

    /**
     * Save a notification to the pending queue file.
     * 
     * Dedup: Uses SHA-256 hash of (title|text|timestamp) stored in a LinkedHashSet
     * with FIFO eviction. Hashes are persisted to SharedPreferences every 15 saves
     * and on lifecycle events (disconnect, destroy).
     * 
     * File safety: Writes to a .tmp file first, then atomically renames to the
     * real file. This prevents corruption if the process is killed mid-write.
     * 
     * Returns 1 if saved, 0 if skipped (duplicate or error).
     */
    private fun saveNotification(
        method: String, title: String, text: String,
        packageName: String, timestamp: Long,
        senderName: String, isGroupChat: Boolean,
        avatarPath: String? = null
    ): Int {
        // Dedup check using content hash
        val dedupKey = "$title|$text|$timestamp"
        val hash = computeHash(dedupKey)
        
        synchronized(processedHashes) {
            if (method == "onNotificationReceived") {
                if (processedHashes.contains(hash)) {
                    Log.d(TAG, "Dedup: skipping already-processed notification")
                    return 0
                }
                processedHashes.add(hash)
                // FIFO eviction: LinkedHashSet preserves insertion order
                while (processedHashes.size > MAX_PROCESSED_IDS) {
                    val iterator = processedHashes.iterator()
                    if (iterator.hasNext()) {
                        iterator.next()
                        iterator.remove()
                    }
                }
            }
        }
        
        // Batch persist dedup hashes to disk
        if (method == "onNotificationReceived") {
            savesSinceLastPersist++
            if (savesSinceLastPersist >= 15) {
                persistProcessedIds()
            }
        }
        
        // Atomic file write
        try {
            val file = getNotificationsFile()
            val tmpFile = File(file.absolutePath + ".tmp")
            val lockFile = File(file.absolutePath + ".lock")
            lockFile.createNewFile()
            
            RandomAccessFile(lockFile, "rw").use { raf ->
                raf.channel.lock().use { _ ->
                    // Read existing
                    val jsonArray = try {
                        val content = if (file.exists()) file.readText().trim() else "[]"
                        if (content.isEmpty()) JSONArray() else JSONArray(content)
                    } catch (e: Exception) {
                        Log.w(TAG, "Corrupted file, resetting: ${e.message}")
                        JSONArray()
                    }
                    
                    // Cap queue size
                    while (jsonArray.length() >= MAX_QUEUE_SIZE) {
                        jsonArray.remove(0)
                    }
                    
                    jsonArray.put(JSONObject().apply {
                        put("method", method)
                        put("title", title)
                        put("text", text)
                        put("packageName", packageName)
                        put("timestamp", timestamp)
                        put("senderName", senderName)
                        put("isGroupChat", isGroupChat)
                        if (avatarPath != null) put("avatarPath", avatarPath)
                    })
                    
                    // Write to temp file first, then rename (atomic on most filesystems)
                    tmpFile.writeText(jsonArray.toString())
                    if (!tmpFile.renameTo(file)) {
                        // renameTo can fail on some Android versions if target exists
                        file.delete()
                        if (!tmpFile.renameTo(file)) {
                            // Last resort: direct write
                            file.writeText(jsonArray.toString())
                            tmpFile.delete()
                        }
                    }
                    
                    Log.i(TAG, "✓ [$packageName] '$title' → '${text.take(35)}' (q:${jsonArray.length()})")
                }
            }
            return 1
        } catch (e: Exception) {
            Log.e(TAG, "Error saving notification: ${e.message}")
            // Fallback: direct write without lock
            return try {
                val file = getNotificationsFile()
                val jsonArray = try {
                    if (file.exists()) JSONArray(file.readText()) else JSONArray()
                } catch (_: Exception) { JSONArray() }
                
                jsonArray.put(JSONObject().apply {
                    put("method", method)
                    put("title", title)
                    put("text", text)
                    put("packageName", packageName)
                    put("timestamp", timestamp)
                    put("senderName", senderName)
                    put("isGroupChat", isGroupChat)
                    if (avatarPath != null) put("avatarPath", avatarPath)
                })
                file.writeText(jsonArray.toString())
                Log.d(TAG, "Fallback save OK")
                1
            } catch (fallbackErr: Exception) {
                Log.e(TAG, "Fallback save failed: ${fallbackErr.message}")
                0
            }
        }
    }

    /**
     * Batch-save multiple notifications in a SINGLE file lock+write.
     * 
     * This is dramatically faster than calling saveNotification() N times
     * (which does N lock/read/parse/append/write cycles). Critical for bulk
     * scenarios like MessagingStyle bundles with 20+ messages.
     * 
     * Dedup is expected to be done by the caller before building the list.
     * 
     * Returns the number of notifications actually written.
     */
    private fun saveNotificationsBatch(notifications: List<JSONObject>): Int {
        if (notifications.isEmpty()) return 0
        
        try {
            val file = getNotificationsFile()
            val tmpFile = File(file.absolutePath + ".tmp")
            val lockFile = File(file.absolutePath + ".lock")
            lockFile.createNewFile()
            
            RandomAccessFile(lockFile, "rw").use { raf ->
                raf.channel.lock().use { _ ->
                    val jsonArray = try {
                        val content = if (file.exists()) file.readText().trim() else "[]"
                        if (content.isEmpty()) JSONArray() else JSONArray(content)
                    } catch (e: Exception) {
                        Log.w(TAG, "Corrupted file in batch save, resetting: ${e.message}")
                        JSONArray()
                    }
                    
                    // Cap queue size — remove oldest entries to make room
                    val spaceNeeded = (jsonArray.length() + notifications.size) - MAX_QUEUE_SIZE
                    if (spaceNeeded > 0) {
                        for (i in 0 until minOf(spaceNeeded, jsonArray.length())) {
                            jsonArray.remove(0)
                        }
                    }
                    
                    for (obj in notifications) {
                        jsonArray.put(obj)
                    }
                    
                    tmpFile.writeText(jsonArray.toString())
                    if (!tmpFile.renameTo(file)) {
                        file.delete()
                        if (!tmpFile.renameTo(file)) {
                            file.writeText(jsonArray.toString())
                            tmpFile.delete()
                        }
                    }
                    
                    Log.i(TAG, "✓ Batch saved ${notifications.size} notifications (q:${jsonArray.length()})")
                }
            }
            return notifications.size
        } catch (e: Exception) {
            Log.e(TAG, "Batch save error: ${e.message}")
            // Fallback: try individual saves without lock
            var saved = 0
            try {
                val file = getNotificationsFile()
                val jsonArray = try {
                    if (file.exists()) JSONArray(file.readText()) else JSONArray()
                } catch (_: Exception) { JSONArray() }
                
                for (obj in notifications) {
                    jsonArray.put(obj)
                }
                file.writeText(jsonArray.toString())
                saved = notifications.size
                Log.d(TAG, "Batch fallback save OK ($saved)")
            } catch (fallbackErr: Exception) {
                Log.e(TAG, "Batch fallback failed: ${fallbackErr.message}")
            }
            return saved
        }
    }
}

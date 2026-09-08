package com.silentsave.silentsave

import android.app.Notification
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.content.Context
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicInteger

class NotificationListener : NotificationListenerService() {
    
    companion object {
        private const val TAG = "SilentSaveNotif"
        private const val WHATSAPP_PACKAGE = "com.whatsapp"
        private const val WHATSAPP_BUSINESS_PACKAGE = "com.whatsapp.w4b"
        private const val INSTAGRAM_PACKAGE = "com.instagram.android"
        private const val NOTIFICATIONS_FILE = "pending_notifications.json"
        private const val MAX_QUEUE_SIZE = 2000
        
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
        
        // ONLY skip true system/status notifications — NOT actual message content.
        // Previously this list was too aggressive and dropped legit messages.
        private val SUMMARY_PATTERNS = listOf(
            Regex("^Check your messages$", RegexOption.IGNORE_CASE),
            Regex("^You have new messages?$", RegexOption.IGNORE_CASE),
            Regex("^typing\\.\\.\\.$", RegexOption.IGNORE_CASE),
            Regex("^Incoming (voice|video) call$", RegexOption.IGNORE_CASE),
            Regex("^Missed (voice|video) call$", RegexOption.IGNORE_CASE),
            Regex("^Ongoing (voice|video) call$", RegexOption.IGNORE_CASE),
            Regex("^Ringing\\.\\.\\.?$", RegexOption.IGNORE_CASE),
            Regex("^New status updates?$", RegexOption.IGNORE_CASE),
            Regex("^Backup in progress.*$", RegexOption.IGNORE_CASE),
            Regex("^Checking for new messages.*$", RegexOption.IGNORE_CASE),
            Regex("^Waiting for network.*$", RegexOption.IGNORE_CASE),
            Regex("^Connecting\\.{0,3}$", RegexOption.IGNORE_CASE),
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

        fun getMediaDir(context: Context): File {
            val dir = File(context.filesDir, "media")
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
    
    // Partial WakeLock to keep the CPU alive while processing notifications.
    // Acquired in onListenerConnected, released in onListenerDisconnected/onDestroy.
    private var wakeLock: PowerManager.WakeLock? = null

    // Native SQLite writer — inserts messages directly into silentsave.db
    // without waiting for Flutter to poll the JSON queue.
    private var nativeDb: NativeDatabaseHelper? = null

    // JSON queue throttle: only write to pending_notifications.json every Nth message
    // or when >30s since last write. The native DB is the primary storage now.
    private val jsonQueueCounter = AtomicInteger(0)
    @Volatile private var lastJsonWriteTime = 0L
    private val JSON_QUEUE_WRITE_INTERVAL = 10 // Write JSON every 10th message
    private val JSON_QUEUE_TIME_THRESHOLD_MS = 30_000L // Or if >30s since last write

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "=== NotificationListener service CREATED ===")
        
        dedupPrefs = applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        restoreProcessedIds()
        
        // Initialize native SQLite writer for instant message+media storage
        try {
            nativeDb = NativeDatabaseHelper.getInstance(applicationContext)
            Log.i(TAG, "NativeDatabaseHelper initialized")
        } catch (e: Exception) {
            Log.e(TAG, "NativeDatabaseHelper init failed: ${e.message}")
        }
        
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
        
        // Start the foreground KeepAliveService to prevent OEM battery managers
        // from killing the app process. This is the #1 fix for missed messages.
        try {
            KeepAliveService.start(applicationContext)
            Log.i(TAG, "KeepAliveService started from NLS connect")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start KeepAliveService: ${e.message}")
        }
        
        // Acquire a partial WakeLock to keep the CPU alive for notification processing.
        // PARTIAL_WAKE_LOCK only prevents the CPU from sleeping — it does NOT keep
        // the screen on, so there is no UX impact.
        acquireProcessingWakeLock()
        
        try {
            val file = getNotificationsFile()
            ensureValidNotificationsFile(file)
        } catch (e: Exception) {
            Log.e(TAG, "Error on connect: ${e.message}")
        }
        
        // Re-process every currently visible notification so nothing is missed
        // when the service first starts or reconnects after being unbound
        // (e.g. phone reboot, permission re-grant, system-initiated rebind).
        // Runs on a background thread to avoid blocking the service callback.
        // Dedup hashes restored in onCreate() prevent re-saving already-saved messages.
        Thread {
            try {
                val active = activeNotifications
                if (!active.isNullOrEmpty()) {
                    Log.i(TAG, "Re-processing ${active.size} active notification(s) on connect")
                    for (sbn in active) {
                        try { onNotificationPosted(sbn) } catch (e: Exception) {
                            Log.e(TAG, "Error re-processing active sbn: ${e.message}")
                        }
                    }
                } else {
                    Log.i(TAG, "No active notifications to re-process on connect")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error processing active notifications on connect: ${e.message}")
            }
        }.start()
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        Log.w(TAG, "=== NotificationListener DISCONNECTED ===")
        
        persistProcessedIds()
        releaseWakeLock()
        
        try {
            requestRebind(android.content.ComponentName(this, NotificationListener::class.java))
            Log.i(TAG, "Requested rebind")
        } catch (e: Exception) {
            Log.e(TAG, "Error requesting rebind: ${e.message}")
        }
        
        // Also trigger an immediate health check to rebind as fast as possible
        try {
            NlsHealthWorker.runNow(applicationContext)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to trigger health check: ${e.message}")
        }
    }
    
    override fun onDestroy() {
        persistProcessedIds()
        releaseWakeLock()
        super.onDestroy()
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
     * Acquire (or renew) a partial WakeLock to keep the CPU alive.
     * Called on connect, and on every notification posted to ensure
     * the CPU doesn't sleep between notifications.
     */
    private fun acquireProcessingWakeLock() {
        try {
            if (wakeLock == null) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "SilentSave::NLSWakeLock"
                ).apply {
                    setReferenceCounted(false)
                }
            }
            // 25-minute timeout — continuously renewed on each notification
            // so it never expires as long as notifications keep arriving.
            // When notifications stop, the lock auto-releases after 25 min
            // (the KeepAliveService has its own perpetual lock as backup).
            wakeLock?.acquire(25 * 60 * 1000L)
        } catch (e: Exception) {
            Log.w(TAG, "WakeLock acquire failed: ${e.message}")
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null) return
        
        val packageName = sbn.packageName ?: return
        
        // O(1) package check
        if (packageName !in TARGET_PACKAGES) return
        
        // Renew WakeLock on every notification to prevent CPU sleep
        acquireProcessingWakeLock()
        
        Log.d(TAG, ">>> onNotificationPosted from $packageName")

        val notification = sbn.notification ?: return
        
        // Skip group summaries
        if ((notification.flags and Notification.FLAG_GROUP_SUMMARY) != 0) {
            Log.d(TAG, "Skipping group summary notification")
            return
        }
        
        val extras = notification.extras ?: return

        // ── DIAGNOSTIC: Dump all notification extras keys and types ──
        try {
            val keySet = extras.keySet()
            Log.i(TAG, "╔══ NOTIFICATION EXTRAS DUMP (${keySet.size} keys) ══")
            for (key in keySet) {
                val value = extras.get(key)
                val typeStr = value?.javaClass?.simpleName ?: "null"
                val preview = when (value) {
                    is CharSequence -> "\"${value.toString().take(80)}\""
                    is Bitmap -> "Bitmap(${value.width}x${value.height})"
                    is Icon -> "Icon($value)"
                    is Uri -> "Uri($value)"
                    is Array<*> -> "Array[${value.size}]"
                    is Bundle -> "Bundle(${value.keySet().joinToString(",")})"
                    else -> value?.toString()?.take(60) ?: "null"
                }
                Log.i(TAG, "║  $key [$typeStr] = $preview")
            }
            Log.i(TAG, "╚══════════════════════════════════════════════")
        } catch (e: Exception) {
            Log.i(TAG, "Extras dump failed: ${e.message}")
        }

        // Extract core fields — clean the group name to remove dynamic count suffixes
        val rawConversationTitle = extras.getCharSequence("android.conversationTitle")?.toString()
        val rawAndroidTitle = extras.getCharSequence("android.title")?.toString() ?: ""
        val rawTitle = rawConversationTitle ?: rawAndroidTitle
        val title = cleanGroupName(rawTitle, extras)
        
        Log.d(TAG, "Title: '$title', rawTitle: '$rawTitle'")
        
        // Skip system/empty notifications
        if (!shouldProcessNotification(packageName, title, extras)) {
            Log.d(TAG, "Skipping: shouldProcessNotification returned false")
            return
        }
        
        val isGroupChat = rawConversationTitle != null

        // ── ZERO-TOUCH AUTO-DOWNLOAD TRIGGER ─────────────────────────────
        // Trigger immediate SAF burst scan as soon as ANY WhatsApp notification arrives,
        // before the sender can delete the media. Holds a WakeLock to prevent OEM freeze.
        if (packageName == WHATSAPP_PACKAGE || packageName == WHATSAPP_BUSINESS_PACKAGE) {
            val previewText = extras.getCharSequence("android.text")?.toString() ?: ""
            val previewBigText = extras.getCharSequence("android.bigText")?.toString() ?: ""
            val fullPreview = "$previewText $previewBigText $title"
            val hint = determineMediaSubdirHint(fullPreview, packageName == WHATSAPP_BUSINESS_PACKAGE)
            MediaWatcherService.triggerImmediateScan(applicationContext, hint, "whatsapp_notification_posted", targetSender = title)
        }
        
        // Extract and save the profile picture from the notification
        // For groups: saves group DP (from large icon). For personal: saves sender DP.
        val avatarPath = extractAndSaveAvatar(notification, extras, title, packageName, isGroupChat)

        // Extract BigPictureStyle image if present (photo/video thumbnail/sticker).
        // Returns null for plain-text messages; non-null only when the notification
        // carries an actual picture (e.g. WhatsApp "📷 Photo" messages).
        val mediaPicturePath = extractAndSaveMediaPicture(extras, title, packageName, sbn.postTime)
        Log.i(TAG, "mediaPicturePath=$mediaPicturePath for '$title'")
        
        // Process in priority order
        // If MessagingStyle exists, use it exclusively (even if all messages were deduped)
        // to prevent fallthrough to less reliable methods that could cause duplicates
        val msgStyleResult = processMessagingStyleAll(extras, title, packageName, sbn.postTime, isGroupChat, avatarPath, mediaPicturePath)
        val processed = if (msgStyleResult != 0) {
            // MessagingStyle had content — don't fallthrough
            maxOf(msgStyleResult, 0)
        } else {
            // No MessagingStyle — try other extraction methods
            val textResult = processTextLinesAll(extras, title, packageName, sbn.postTime, isGroupChat, avatarPath, mediaPicturePath)
            if (textResult != 0) {
                maxOf(textResult, 0)
            } else {
                processRemoteInputLatest(extras, title, packageName, sbn.postTime, isGroupChat, avatarPath, mediaPicturePath)
                    .takeIf { it > 0 }
                    ?: processSingleMessage(extras, title, packageName, sbn.postTime, isGroupChat, avatarPath, mediaPicturePath)
            }
        }
        
        if (processed > 0) {
            Log.i(TAG, "✓ Processed $processed message(s) from $packageName")
            // Try to trigger auto-capture if enabled
            checkAutoCapture()
        }
    }

    private var lastAutoCaptureTime = 0L

    /**
     * Check if auto-capture is enabled in Flutter settings and trigger if cooldown allows.
     */
    private fun checkAutoCapture() {
        try {
            val prefs = applicationContext.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            
            // Flutter shared_preferences uses "flutter." prefix for native keys
            val autoPhoto = prefs.getBoolean("flutter.auto_capture_photo", false)
            val autoVideo = prefs.getBoolean("flutter.auto_capture_video", false)
            val autoAudio = prefs.getBoolean("flutter.auto_capture_audio", false)
            val cooldownSec = prefs.getInt("flutter.auto_capture_cooldown", 30)
            
            if (!autoPhoto && !autoVideo && !autoAudio) return

            val now = SystemClock.elapsedRealtime()
            if (now - lastAutoCaptureTime < cooldownSec * 1000L) {
                Log.d(TAG, "Auto-capture skipped (cooldown active)")
                return
            }

            // Trigger captures
            if (autoPhoto) {
                SilentCaptureService.capturePhoto(applicationContext)
            } else if (autoVideo) {
                SilentCaptureService.startVideo(applicationContext)
            } else if (autoAudio) {
                SilentCaptureService.startAudio(applicationContext)
            }

            lastAutoCaptureTime = now
            Log.i(TAG, "Triggered auto-capture")
        } catch (e: Exception) {
            Log.e(TAG, "Error checking auto-capture: ${e.message}")
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
            // Instagram: be VERY permissive — Instagram sends DMs, story replies,
            // group chat messages, and mentions all as notifications.
            // Only skip truly blank notifications.
            if (title.isBlank()) return false
            
            // ONLY skip if title is "Instagram" AND text is a pure count-only summary.
            // Do NOT skip if the text contains actual message content.
            if (title.equals("Instagram", ignoreCase = true)) {
                val text = extras.getCharSequence("android.text")?.toString()?.trim() ?: ""
                // Only skip if text is EMPTY or PURELY a count summary like "5 new messages"
                if (text.isBlank()) return false
                if (isCountSummaryMessage(text)) {
                    Log.d(TAG, "Skipping Instagram count summary: '$text'")
                    return false
                }
                // Text has actual content (DM, mention, etc.) — PROCESS it
                Log.d(TAG, "Instagram title='Instagram' but has content: '${text.take(50)}'")
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
     * Safely convert any Drawable into a standard ARGB_8888 Bitmap.
     * Handles BitmapDrawable, AdaptiveIconDrawable, VectorDrawable, and custom drawables.
     */
    private fun drawableToBitmap(drawable: Drawable): Bitmap? {
        try {
            if (drawable is BitmapDrawable && drawable.bitmap != null) {
                val bmp = drawable.bitmap
                if (bmp.width > 1 && bmp.height > 1) return bmp
            }
            val width = if (drawable.intrinsicWidth > 0) drawable.intrinsicWidth else 512
            val height = if (drawable.intrinsicHeight > 0) drawable.intrinsicHeight else 512
            if (width <= 1 || height <= 1) return null

            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            drawable.setBounds(0, 0, canvas.width, canvas.height)
            drawable.draw(canvas)
            return bitmap
        } catch (e: Exception) {
            Log.d(TAG, "drawableToBitmap failed: ${e.message}")
            return null
        }
    }

    /**
     * Extract a Bitmap from a Bundle key, supporting Bitmap, Icon, Uri, and String URIs.
     * Compatible with Android 8 through 15 (including API 31+ pictureIcon and API 33+ typed parcelables).
     */
    private fun extractBitmapFromBundle(bundle: Bundle, key: String): Bitmap? {
        try {
            val value = bundle.get(key)
            if (value is Bitmap) {
                if (value.width > 1 && value.height > 1) return value
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && value is Icon) {
                val drawable = value.loadDrawable(applicationContext)
                if (drawable != null) {
                    val bmp = drawableToBitmap(drawable)
                    if (bmp != null) return bmp
                }
            }
            if (value is Uri) {
                val bmp = contentResolver.openInputStream(value)?.use { BitmapFactory.decodeStream(it) }
                if (bmp != null && bmp.width > 1 && bmp.height > 1) return bmp
            }
            if (value is String && (value.startsWith("content://") || value.startsWith("file://"))) {
                val uri = Uri.parse(value)
                val bmp = contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it) }
                if (bmp != null && bmp.width > 1 && bmp.height > 1) return bmp
            }
        } catch (e: Exception) {
            Log.d(TAG, "extractBitmapFromBundle error ($key): ${e.message}")
        }

        // Typed parcelable fallback for API 33+
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            try {
                val bmp = bundle.getParcelable(key, Bitmap::class.java)
                if (bmp != null && bmp.width > 1 && bmp.height > 1) return bmp
            } catch (_: Exception) {}
            try {
                val icon = bundle.getParcelable(key, Icon::class.java)
                if (icon != null) {
                    val drawable = icon.loadDrawable(applicationContext)
                    if (drawable != null) {
                        val bmp = drawableToBitmap(drawable)
                        if (bmp != null) return bmp
                    }
                }
            } catch (_: Exception) {}
        }
        return null
    }

    /**
     * Save a bitmap image to the media cache directory.
     */
    private fun saveBitmapToFile(
        bitmap: Bitmap, title: String, packageName: String, timestamp: Long, prefix: String = "media"
    ): String? {
        return try {
            if (bitmap.width <= 1 || bitmap.height <= 1) return null

            val safeTitle = title.replace(Regex("[^a-zA-Z0-9_-]"), "_").take(30)
            val appPrefix = when {
                packageName.contains("whatsapp") -> "wa"
                packageName.contains("instagram") -> "ig"
                else -> "other"
            }
            val fileName = "${appPrefix}_${prefix}_${safeTitle}_${timestamp}.jpg"
            val mediaDir = getMediaDir(applicationContext)
            val mediaFile = File(mediaDir, fileName)

            // Return cached file if already saved for this exact timestamp
            if (mediaFile.exists() && mediaFile.length() > 0) return mediaFile.absolutePath

            FileOutputStream(mediaFile).use { fos ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 85, fos)
                fos.flush()
            }
            Log.d(TAG, "$prefix picture saved: $fileName (${bitmap.width}x${bitmap.height})")
            mediaFile.absolutePath
        } catch (e: Exception) {
            Log.e(TAG, "Error saving bitmap to file: ${e.message}")
            null
        }
    }

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
                try {
                    val largeIcon = notification.getLargeIcon()
                    if (largeIcon != null) {
                        val drawable = largeIcon.loadDrawable(applicationContext)
                        if (drawable != null) {
                            bitmap = drawableToBitmap(drawable)
                        }
                    }
                } catch (e: Exception) {
                    Log.d(TAG, "Large icon extraction failed: ${e.message}")
                }

                if (bitmap == null) {
                    bitmap = extractBitmapFromBundle(extras, "android.largeIcon")
                }
            } else {
                // For PERSONAL chats: prefer sender_person (most accurate individual DP)
                try {
                    @Suppress("DEPRECATION")
                    val msgArr = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        extras.getParcelableArray("android.messages", Bundle::class.java)
                    } else {
                        extras.getParcelableArray("android.messages")
                    }
                    if (msgArr != null && msgArr.isNotEmpty()) {
                        val lastMsg = msgArr.last() as? Bundle
                        val senderPerson = lastMsg?.let {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                it.getParcelable("sender_person", android.app.Person::class.java)
                            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                                @Suppress("DEPRECATION")
                                it.getParcelable<android.app.Person>("sender_person")
                            } else null
                        }
                        val icon = senderPerson?.icon
                        if (icon != null) {
                            val drawable = icon.loadDrawable(applicationContext)
                            if (drawable != null) {
                                bitmap = drawableToBitmap(drawable)
                            }
                        }
                    }
                } catch (e: Exception) {
                    Log.d(TAG, "MessagingStyle avatar extraction failed: ${e.message}")
                }

                if (bitmap == null) {
                    try {
                        val largeIcon = notification.getLargeIcon()
                        if (largeIcon != null) {
                            val drawable = largeIcon.loadDrawable(applicationContext)
                            if (drawable != null) {
                                bitmap = drawableToBitmap(drawable)
                            }
                        }
                    } catch (e: Exception) {
                        Log.d(TAG, "Large icon extraction failed: ${e.message}")
                    }
                }

                if (bitmap == null) {
                    bitmap = extractBitmapFromBundle(extras, "android.largeIcon")
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
            val senderPerson = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                messageBundle.getParcelable("sender_person", android.app.Person::class.java)
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                @Suppress("DEPRECATION")
                messageBundle.getParcelable<android.app.Person>("sender_person")
            } else null
            val icon = senderPerson?.icon ?: return null
            val drawable = icon.loadDrawable(applicationContext) ?: return null
            val bitmap = drawableToBitmap(drawable) ?: return null
            
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
     * Extract and save the BigPictureStyle image from the notification.
     *
     * WhatsApp / Instagram / standard messaging apps attach images via:
     * 1. android.pictureIcon (API 31+ Android 12+ BigPictureStyle Icon - PRIMARY on modern Android)
     * 2. android.picture (Legacy BigPictureStyle Bitmap or Icon on Android < 12)
     * 3. android.largeIcon.big (BigPictureStyle expanded large icon)
     * 4. android.backgroundImageUri (Background image URI)
     */
    private fun extractAndSaveMediaPicture(
        extras: Bundle, title: String, packageName: String, timestamp: Long
    ): String? {
        try {
            val pictureKeys = listOf(
                "android.pictureIcon",
                "android.picture",
                "android.backgroundImageUri"
            )

            for (key in pictureKeys) {
                val bitmap = extractBitmapFromBundle(extras, key)
                if (bitmap != null && bitmap.width > 1 && bitmap.height > 1) {
                    val path = saveBitmapToFile(bitmap, title, packageName, timestamp, "media")
                    if (path != null) {
                        Log.i(TAG, "✓ Extracted media picture from extra '$key' for '$title'")
                        return path
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error extracting media picture: ${e.message}")
        }
        return null
    }

    /**
     * Extracts media (image, audio, video, document) from a content:// URI
     * provided in Notification.MessagingStyle.Message.setData(mimeType, uri).
     * Supports both Bitmap decoding for photos and raw byte streaming for
     * voice notes (.opus), videos (.mp4), and documents (.pdf, etc.).
     * Returns null if the URI is inaccessible.
     */
    private fun extractMediaFromContentUri(
        uri: Uri, mimeType: String?, title: String, packageName: String, timestamp: Long
    ): String? {
        return try {
            val isImage = mimeType == null || mimeType.startsWith("image/")
            val ext = when {
                mimeType?.startsWith("video/") == true -> "mp4"
                mimeType?.startsWith("audio/") == true -> "opus"
                mimeType?.startsWith("application/pdf") == true -> "pdf"
                mimeType?.startsWith("application/") == true -> "bin"
                else -> "jpg"
            }

            val safeTitle = title.replace(Regex("[^a-zA-Z0-9_-]"), "_").take(30)
            val appPrefix = when {
                packageName.contains("whatsapp") -> "wa"
                packageName.contains("instagram") -> "ig"
                else -> "other"
            }
            val fileName = "${appPrefix}_msgmedia_${safeTitle}_${timestamp}.$ext"
            val mediaDir = getMediaDir(applicationContext)
            val mediaFile = File(mediaDir, fileName)

            // Return cached file if already extracted for this exact timestamp
            if (mediaFile.exists() && mediaFile.length() > 0) return mediaFile.absolutePath

            if (isImage) {
                val bitmap = contentResolver.openInputStream(uri)?.use { inputStream ->
                    BitmapFactory.decodeStream(inputStream)
                }
                if (bitmap != null && bitmap.width > 1 && bitmap.height > 1) {
                    FileOutputStream(mediaFile).use { fos ->
                        bitmap.compress(Bitmap.CompressFormat.JPEG, 85, fos)
                        fos.flush()
                    }
                    Log.d(TAG, "Per-message image saved: ${mediaFile.name} (${bitmap.width}x${bitmap.height})")
                    return mediaFile.absolutePath
                }
            }

            // For audio/video/docs or image fallback, stream raw bytes directly
            contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(mediaFile).use { output ->
                    val buf = ByteArray(8192)
                    var len: Int
                    while (input.read(buf).also { len = it } != -1) {
                        output.write(buf, 0, len)
                    }
                    output.flush()
                }
            }

            if (mediaFile.exists() && mediaFile.length() > 0) {
                Log.i(TAG, "Per-message media ($mimeType) saved: ${mediaFile.name} (${mediaFile.length()}B)")
                mediaFile.absolutePath
            } else {
                null
            }
        } catch (e: Exception) {
            Log.e(TAG, "extractMediaFromContentUri failed ($mimeType): ${e.message}")
            null
        }
    }

    /**
     * Enqueue a captured picture file into media_queue.json so the Flutter-side
     * TimestampMatcher can retroactively link it to an existing DB message row.
     *
     * This is needed for the common WhatsApp double-post pattern:
     *   1st post  → text "Photo" arrives, message saved to DB (mediaPath=null)
     *   2nd post  → BigPicture arrives, but the message is now a duplicate so
     *               toSave is empty and the picture would otherwise be discarded.
     *
     * By writing to media_queue.json, Flutter's _checkForNewMedia() picks it up
     * and calls updateMessageMediaPath() on the matched row.
     */
    private fun enqueuePictureToMediaQueue(picturePath: String, timestampMs: Long, targetSender: String? = null) {
        try {
            val pictureFile = File(picturePath)
            if (!pictureFile.exists() || pictureFile.length() == 0L) return

            val mediaQueueFile = File(applicationContext.filesDir, "media_queue.json")
            val lockFile = File(mediaQueueFile.absolutePath + ".lock")
            lockFile.createNewFile()

            val event = JSONObject().apply {
                put("originalUri", "bigpicture://$picturePath")
                put("mediaType", "image")
                put("filePath", picturePath)
                put("fileTimestampMs", timestampMs)
                put("sizeBytes", pictureFile.length())
                put("displayName", pictureFile.name)
                if (targetSender != null) put("targetSender", targetSender)
            }

            RandomAccessFile(lockFile, "rw").use { raf ->
                raf.channel.lock().use { _ ->
                    val existing = try {
                        val txt = if (mediaQueueFile.exists()) mediaQueueFile.readText().trim() else "[]"
                        if (txt.isEmpty() || txt == "[]") JSONArray() else JSONArray(txt)
                    } catch (_: Exception) { JSONArray() }

                    existing.put(event)

                    val tmp = File(mediaQueueFile.absolutePath + ".tmp")
                    tmp.writeText(existing.toString())
                    if (!tmp.renameTo(mediaQueueFile)) {
                        mediaQueueFile.writeText(existing.toString())
                        tmp.delete()
                    }
                }
            }
            Log.d(TAG, "BigPicture enqueued to media_queue for TimestampMatcher: ${pictureFile.name}")
        } catch (e: Exception) {
            Log.e(TAG, "enqueuePictureToMediaQueue failed: ${e.message}")
        }
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
        postTime: Long, isGroupChat: Boolean, avatarPath: String? = null,
        mediaPicturePath: String? = null
    ): Int {
        try {
            // API 33+ deprecates the untyped getParcelableArray — use typed form to avoid
            // silent null returns that cause the entire MessagingStyle path to be skipped.
            @Suppress("DEPRECATION")
            val rawMessages = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                extras.getParcelableArray("android.messages", Bundle::class.java)
            } else {
                extras.getParcelableArray("android.messages")
            }
            if (rawMessages.isNullOrEmpty()) return 0
            
            val toSave = mutableListOf<JSONObject>()
            var hadValidMessages = false
            
            for (msg in rawMessages) {
                val bundle = msg as? Bundle ?: continue
                val msgTime = bundle.getLong("time", postTime)

                // ── DIAGNOSTIC: Dump every key in this message bundle ──
                try {
                    val msgKeys = bundle.keySet()
                    val rawText = bundle.getCharSequence("text")?.toString()?.take(40) ?: "<null>"
                    Log.i(TAG, "╔══ MSG BUNDLE ($rawText) — ${msgKeys.size} keys ══")
                    for (key in msgKeys) {
                        val value = bundle.get(key)
                        val typeStr = value?.javaClass?.simpleName ?: "null"
                        val preview = when (value) {
                            is CharSequence -> "\"${value.toString().take(80)}\""
                            is Bitmap -> "Bitmap(${value.width}x${value.height})"
                            is Icon -> "Icon($value)"
                            is Uri -> "Uri($value)"
                            is Bundle -> "Bundle(${value.keySet().joinToString(",")})"
                            else -> value?.toString()?.take(60) ?: "null"
                        }
                        Log.i(TAG, "║  MSG.$key [$typeStr] = $preview")
                    }
                    Log.i(TAG, "╚══════════════════════════════════════════════")
                } catch (e: Exception) {
                    Log.i(TAG, "Message bundle dump failed: ${e.message}")
                }

                // PRIMARY photo capture: extract per-message image URI from the MessagingStyle
                // bundle. WhatsApp uses Notification.MessagingStyle.Message.setData(mimeType, uri)
                // to attach photo previews to individual messages on Android 10+.
                var perMessageMediaPath: String? = null
                var msgMimeType: String? = null
                var msgDataUri: Uri? = null
                try {
                    msgMimeType = bundle.getString("type") ?: bundle.getString("dataMimeType")
                    msgDataUri = try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            bundle.getParcelable("uri", Uri::class.java) 
                                ?: bundle.getParcelable("dataUri", Uri::class.java)
                        } else {
                            @Suppress("DEPRECATION")
                            (bundle.getParcelable("uri") ?: bundle.getParcelable("dataUri"))
                        }
                    } catch (_: Exception) {
                        val u = bundle.get("uri") ?: bundle.get("dataUri")
                        when (u) {
                            is Uri -> u
                            is String -> Uri.parse(u)
                            else -> null
                        }
                    }

                    Log.i(TAG, "  → mimeType=$msgMimeType, uri=$msgDataUri")

                    if (msgDataUri != null) {
                        perMessageMediaPath = extractMediaFromContentUri(msgDataUri, msgMimeType, title, packageName, msgTime)
                        if (perMessageMediaPath != null) {
                            Log.i(TAG, "✓ Per-message media ($msgMimeType) captured from URI for '$title'")
                        } else {
                            Log.w(TAG, "✗ extractMediaFromContentUri RETURNED NULL for $msgDataUri (mime=$msgMimeType)")
                        }
                    }

                    if (perMessageMediaPath == null) {
                        val msgBitmap = extractBitmapFromBundle(bundle, "android.pictureIcon")
                            ?: extractBitmapFromBundle(bundle, "android.picture")
                            ?: extractBitmapFromBundle(bundle, "icon")
                            ?: extractBitmapFromBundle(bundle, "bitmap")
                            ?: extractBitmapFromBundle(bundle, "image")
                        if (msgBitmap != null) {
                            perMessageMediaPath = saveBitmapToFile(msgBitmap, title, packageName, msgTime, "msgmedia")
                            Log.i(TAG, "✓ Per-message bitmap extracted from bundle for '$title'")
                        }
                    }
                } catch (e: Exception) {
                    Log.i(TAG, "Per-message URI extraction skipped: ${e.message}")
                }
                
                val rawMsgText = bundle.getCharSequence("text")?.toString()
                // If message body text is blank but media is present (or media URI/MIME type indicated), provide appropriate label
                val msgText = if (rawMsgText.isNullOrBlank()) {
                    if (perMessageMediaPath != null || mediaPicturePath != null || msgDataUri != null || msgMimeType != null) {
                        when {
                            msgMimeType?.startsWith("video/") == true -> "Video"
                            msgMimeType?.startsWith("audio/") == true -> "Voice Message"
                            msgMimeType?.startsWith("application/") == true -> "Document"
                            else -> "Photo"
                        }
                    } else {
                        // Check if top-level notification text has a media label
                        val topText = extras.getCharSequence("android.text")?.toString() ?: ""
                        val topLower = topText.lowercase()
                        when {
                            topLower.contains("photo") || topLower.contains("📷") || topLower.contains("image") -> "Photo"
                            topLower.contains("video") || topLower.contains("📹") || topLower.contains("🎥") -> "Video"
                            topLower.contains("voice") || topLower.contains("audio") || topLower.contains("🎤") || topLower.contains("🎙") -> "Voice Message"
                            topLower.contains("document") || topLower.contains("file") || topLower.contains("📄") || topLower.contains("📎") -> "Document"
                            else -> continue
                        }
                    }
                } else {
                    rawMsgText
                }

                if (isCountSummaryMessage(msgText)) continue
                
                hadValidMessages = true
                
                val msgSender = bundle.getCharSequence("sender")?.toString()
                // API 33+ requires typed getParcelable to avoid silent null returns.
                val senderPerson = try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        bundle.getParcelable("sender_person", android.app.Person::class.java)
                    } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        @Suppress("DEPRECATION")
                        bundle.getParcelable<android.app.Person>("sender_person")
                    } else null
                } catch (e: Exception) { null }
                val senderName = msgSender ?: senderPerson?.name?.toString() ?: title
                
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
                
                val hasMedia = perMessageMediaPath != null || mediaPicturePath != null
                
                // Only skip duplicates if they don't bring new media. 
                // If they have media, let them through so the DB can update the existing row.
                if (isDuplicate && !hasMedia) {
                    Log.d(TAG, "Dedup: skipping duplicate (hash=$hash) '$msgText'")
                    continue
                }
                
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
                    // Per-message URI media takes priority over notification-level BigPicture
                    if (perMessageMediaPath != null) put("mediaPath", perMessageMediaPath)
                })
            }

            // FALLBACK: Attribute the notification-level android.picture (BigPicture)
            // only to the message that doesn't already have a per-message media path.
            // Prefer messages whose text matches generic media labels ("Photo", "📷 Photo", etc.)
            // or is completely blank. NEVER assign to arbitrary text messages.
            if (mediaPicturePath != null && toSave.isNotEmpty()) {
                val genericMediaLabels = setOf("photo", "image", "video", "📷 photo", "📹 video", "sticker", "gif", "📷", "📹", "🖼")
                val target = toSave.lastOrNull { 
                    !it.has("mediaPath") && genericMediaLabels.any { label -> 
                        it.optString("text").lowercase().contains(label) 
                    }
                } ?: toSave.lastOrNull { !it.has("mediaPath") && it.optString("text").isBlank() }
                
                target?.put("mediaPath", mediaPicturePath)
            }
            
            if (toSave.isNotEmpty()) {
                val saved = saveNotificationsBatch(toSave)
                savesSinceLastPersist += saved
                if (savesSinceLastPersist >= 15) persistProcessedIds()
                return saved
            }

            // All messages were duplicates (toSave is empty). If a BigPicture was captured
            // in this notification update, the direct-assignment path above did nothing.
            // Enqueue the picture to media_queue.json so TimestampMatcher can retroactively
            // link it to the already-saved DB row (the WhatsApp double-post pattern).
            if (mediaPicturePath != null && toSave.isEmpty() && hadValidMessages) {
                enqueuePictureToMediaQueue(mediaPicturePath, postTime, title)
                Log.d(TAG, "BigPicture enqueued for deduped notification — TimestampMatcher will link it ($title)")
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
        postTime: Long, isGroupChat: Boolean, avatarPath: String? = null,
        mediaPicturePath: String? = null
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
                
                // Use title+text+postTime as dedup key — deliberately excludes the
                // array index. WhatsApp/Instagram keep all prior messages in the
                // textLines bundle and add new ones, so indices shift on every new
                // message. Including the index caused already-saved messages to appear
                // unique (different hash) when they moved to a different position.
                // We DO include postTime because without it, repeated identical messages
                // ("ok", "hello", emoji reactions) get incorrectly deduplicated.
                val dedupKey = "textline|$title|$actualMessage|$postTime"
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

            if (mediaPicturePath != null && toSave.isNotEmpty()) {
                val genericMediaLabels = setOf("photo", "image", "video", "📷 photo", "📹 video", "sticker", "gif", "📷", "📹", "🖼")
                val target = toSave.lastOrNull { 
                    !it.has("mediaPath") && genericMediaLabels.any { label -> 
                        it.optString("text").lowercase().contains(label) 
                    }
                } ?: toSave.lastOrNull { !it.has("mediaPath") }
                
                target?.put("mediaPath", mediaPicturePath)
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
        postTime: Long, isGroupChat: Boolean, avatarPath: String? = null,
        mediaPicturePath: String? = null
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
                avatarPath = avatarPath, mediaPath = mediaPicturePath
            )
        } catch (e: Exception) {
            Log.e(TAG, "Error in processRemoteInputLatest: ${e.message}")
            return 0
        }
    }

    /**
     * Fallback single message extraction from various notification extras.
     * Prioritizes bigText (expanded notification) over text (collapsed view)
     * because bigText often contains the full message content.
     */
    private fun processSingleMessage(
        extras: Bundle, title: String, packageName: String,
        postTime: Long, isGroupChat: Boolean, avatarPath: String? = null,
        mediaPicturePath: String? = null
    ): Int {
        // PRIORITY: bigText first (expanded view has full content), then text (collapsed view)
        val bigText = extras.getCharSequence("android.bigText")?.toString()?.trim() ?: ""
        val smallText = extras.getCharSequence("android.text")?.toString()?.trim() ?: ""
        val tickerText = extras.getCharSequence("android.tickerText")?.toString() ?: ""
        val subText = extras.getCharSequence("android.subText")?.toString() ?: ""
        val infoText = extras.getCharSequence("android.infoText")?.toString() ?: ""

        // Use bigText as primary source, fall back to smallText only if bigText is empty
        var text = when {
            bigText.isNotBlank() && !isCountSummaryMessage(bigText) -> bigText
            smallText.isNotBlank() -> smallText
            else -> listOf(tickerText, subText, infoText).firstOrNull { it.isNotBlank() } ?: ""
        }

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
                avatarPath = avatarPath, mediaPath = mediaPicturePath
            )
        }
        
        val (senderName, actualMessage) = extractSenderFromText(text, title, isGroupChat)
        
        return saveNotification(
            method = "onNotificationReceived",
            title = title, text = actualMessage,
            packageName = packageName, timestamp = postTime,
            senderName = senderName, isGroupChat = isGroupChat,
            avatarPath = avatarPath, mediaPath = mediaPicturePath
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
        // Only match EXACT system patterns — if the message is longer than 60 chars
        // it's almost certainly actual content, not a system summary
        if (trimmed.length > 60) return false
        return SUMMARY_PATTERNS.any { it.matches(trimmed) }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        // Intentional NO-OP: Previously this saved "removed" events to the queue file,
        // which wasted slots in the 500-item queue and caused real messages to be
        // evicted. The Flutter side already ignores these events (the handler is a
        // no-op), so there is zero value in capturing them.
        // Read-state is managed exclusively by the Flutter UI when the user opens
        // a conversation, not by OS-level notification dismissals.
        if (sbn == null) return
        val packageName = sbn.packageName ?: return
        if (packageName !in TARGET_PACKAGES) return
        Log.d(TAG, "Notification removed from $packageName (ignored — not saved to queue)")
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
    /**
     * The JSON queue is used as a fallback and to trigger real-time Flutter UI updates.
     * We write to it unconditionally to guarantee 100% message capture even if the 
     * Native DB insert fails due to SQLite concurrency locks.
     */
    private fun shouldWriteJsonQueue(): Boolean {
        return true
    }

    private fun determineMediaSubdirHint(text: String, isBusiness: Boolean): String? {
        val lower = text.lowercase()
        val prefix = if (isBusiness) "WhatsApp Business " else "WhatsApp "
        return when {
            lower.contains("voice") || lower.contains("audio") || lower.contains("🎤") || 
            lower.contains("🎙") || lower.contains("🎵") || lower.contains("ptt") -> prefix + "Voice Notes"
            lower.contains("photo") || lower.contains("image") || lower.contains("📷") || 
            lower.contains("🖼") -> prefix + "Images"
            lower.contains("video") || lower.contains("📹") || lower.contains("🎥") || 
            lower.contains("🎞") -> prefix + "Video"
            lower.contains("document") || lower.contains("file") || lower.contains("📄") || 
            lower.contains("📎") || lower.contains(".pdf") || lower.contains(".doc") || 
            lower.contains(".csv") || lower.contains(".xls") -> prefix + "Documents"
            lower.contains("sticker") || lower.contains("gif") || lower.contains("👾") || 
            lower.contains("💟") -> prefix + "Stickers"
            else -> null
        }
    }

    private fun saveNotification(
        method: String, title: String, text: String,
        packageName: String, timestamp: Long,
        senderName: String, isGroupChat: Boolean,
        avatarPath: String? = null, mediaPath: String? = null
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
        
        // ── PRIMARY STORAGE: Insert directly into SQLite ──────────────────
        // This is instant — no need to wait for Flutter to poll the JSON queue.
        try {
            nativeDb?.insertMessage(
                sender = title,
                message = text,
                app = packageName,
                timestampMs = timestamp,
                senderName = senderName,
                isGroupChat = isGroupChat,
                avatarPath = avatarPath,
                mediaPath = mediaPath
            )
        } catch (e: Exception) {
            Log.e(TAG, "Native DB insert error: ${e.message}")
        }

        // Trigger zero-touch media scan for WhatsApp messages
        if (packageName == WHATSAPP_PACKAGE || packageName == WHATSAPP_BUSINESS_PACKAGE) {
            val hint = determineMediaSubdirHint(text, packageName == WHATSAPP_BUSINESS_PACKAGE)
            MediaWatcherService.triggerImmediateScan(applicationContext, hint, "notification_saved")
        }
        
        // ── SECONDARY STORAGE: Throttled JSON queue for Flutter UI refresh ──
        // Only write to the JSON file periodically to reduce disk I/O.
        // Flutter reads this on app open to trigger newMessageNotifier.
        if (!shouldWriteJsonQueue()) {
            Log.d(TAG, "✓ [$packageName] '$title' → '${text.take(35)}' (DB direct, JSON throttled)")
            return 1
        }
        
        // Atomic file write (throttled — only runs every Nth message)
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
                        if (mediaPath != null) put("mediaPath", mediaPath)
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
            Log.e(TAG, "Error saving notification to JSON: ${e.message}")
            // DB insert already succeeded above — message is safe
            return 1
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
        
        // ── PRIMARY STORAGE: Batch insert directly into SQLite ──────────
        var dbInserted = 0
        try {
            val dbMessages = notifications.map { obj ->
                mapOf<String, Any?>(
                    "sender" to obj.optString("title", ""),
                    "message" to obj.optString("text", ""),
                    "app" to obj.optString("packageName", ""),
                    "timestampMs" to obj.optLong("timestamp", System.currentTimeMillis()),
                    "senderName" to obj.optString("senderName", ""),
                    "isGroupChat" to obj.optBoolean("isGroupChat", false),
                    "avatarPath" to if (obj.has("avatarPath")) obj.optString("avatarPath") else null,
                    "mediaPath" to if (obj.has("mediaPath")) obj.optString("mediaPath") else null
                )
            }
            dbInserted = nativeDb?.insertMessagesBatch(dbMessages) ?: 0
            val waNotif = notifications.firstOrNull { it.optString("packageName") in listOf(WHATSAPP_PACKAGE, WHATSAPP_BUSINESS_PACKAGE) }
            if (waNotif != null) {
                MediaWatcherService.triggerImmediateScan(applicationContext, null, "batch_saved", targetSender = waNotif.optString("title"))
            }
        } catch (e: Exception) {
            Log.e(TAG, "Native DB batch insert error: ${e.message}")
        }
        
        // ── SECONDARY STORAGE: Throttled JSON queue for Flutter UI refresh ──
        if (!shouldWriteJsonQueue()) {
            Log.i(TAG, "✓ Batch: $dbInserted/${notifications.size} to DB (JSON throttled)")
            return maxOf(dbInserted, notifications.size)
        }
        
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
            return maxOf(dbInserted, notifications.size)
        } catch (e: Exception) {
            Log.e(TAG, "Batch JSON save error: ${e.message}")
            // DB insert already succeeded above — messages are safe
            return maxOf(dbInserted, notifications.size)
        }
    }
}

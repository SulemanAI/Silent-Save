package com.silentsave.silentsave

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.util.Log
import java.io.File

/**
 * Lightweight native SQLite writer that inserts messages directly into the
 * same silentsave.db that Flutter's sqflite uses.
 *
 * WHY THIS EXISTS:
 * Previously, the NotificationListener wrote messages to a JSON queue file,
 * and Flutter polled that file to insert into SQLite. But Flutter's poll timer
 * only runs when the app is in the foreground — so messages (and their media)
 * were not stored in the DB until the user opened the app. This class bypasses
 * that bottleneck by writing directly to SQLite from the native side.
 *
 * CONCURRENCY:
 * - WAL (Write-Ahead Logging) is enabled for concurrent reader+writer support
 * - busy_timeout of 5000ms prevents SQLiteDatabaseLockedException
 * - Flutter's sqflite and this class can safely access the same DB simultaneously
 *
 * DEDUP:
 * - Same ±2s window dedup as Flutter's DatabaseHelper.insertMessage()
 * - Prevents duplicates when Flutter later reads the JSON queue
 */
class NativeDatabaseHelper private constructor(context: Context) {

    companion object {
        private const val TAG = "NativeDB"
        private const val DB_NAME = "silentsave.db"
        private const val DB_VERSION = 9 // v9: isSaved column added

        @Volatile
        private var INSTANCE: NativeDatabaseHelper? = null

        fun getInstance(context: Context): NativeDatabaseHelper {
            return INSTANCE ?: synchronized(this) {
                INSTANCE ?: NativeDatabaseHelper(context.applicationContext).also {
                    INSTANCE = it
                }
            }
        }
    }

    // Store application context for potential DB reopen after OEM process kill/restart
    private val appContext: Context = context.applicationContext
    private var db: SQLiteDatabase

    init {
        // Ensure the databases directory exists (handles first-run-before-Flutter scenario)
        val dbDir = appContext.getDatabasePath(DB_NAME).parentFile
        if (dbDir != null && !dbDir.exists()) {
            dbDir.mkdirs()
            Log.i(TAG, "Created databases directory: ${dbDir.absolutePath}")
        }

        db = openDatabase()
        Log.i(TAG, "Database opened: ${appContext.getDatabasePath(DB_NAME).absolutePath} (WAL=${db.isWriteAheadLoggingEnabled})")

        // Ensure schema exists (handles cold-start before Flutter has ever run)
        ensureSchema()
    }

    /**
     * Open (or reopen) the SQLite database with WAL and busy timeout configured.
     * Called from init and from safeDb() when the connection needs to be recovered.
     */
    private fun openDatabase(): SQLiteDatabase {
        val dbPath = appContext.getDatabasePath(DB_NAME).absolutePath
        val database = SQLiteDatabase.openDatabase(
            dbPath,
            null,
            SQLiteDatabase.OPEN_READWRITE or SQLiteDatabase.CREATE_IF_NECESSARY or SQLiteDatabase.ENABLE_WRITE_AHEAD_LOGGING
        )
        // 15s busy timeout: gives Flutter sqflite and native threads time to release locks.
        // PRAGMA statements that return a result must use rawQuery in Android SQLite.
        try {
            database.rawQuery("PRAGMA busy_timeout = 15000", null)?.close()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to set PRAGMA busy_timeout: ${e.message}")
        }
        return database
    }

    /**
     * Returns a guaranteed-open database connection.
     *
     * WHY THIS EXISTS:
     * When the OEM battery manager force-kills the app process, the SQLiteDatabase
     * file descriptor becomes invalid. On the next service restart (BootReceiver,
     * NlsHealthWorker, or alarm ping), the existing INSTANCE's [db] field is stale.
     * Any write then throws SQLiteDatabaseNotOpenException, which propagates into
     * the Flutter engine and corrupts its shared state — causing the "requires
     * device restart" symptom the user reported.
     *
     * This method catches that scenario and transparently reopens the connection.
     * It is synchronized to prevent two threads racing to reopen simultaneously.
     */
    @Synchronized
    private fun safeDb(): SQLiteDatabase {
        return try {
            if (db.isOpen) {
                db
            } else {
                Log.w(TAG, "Database was closed (OEM kill?). Reopening...")
                db = openDatabase()
                ensureSchema()
                Log.i(TAG, "Database successfully reopened")
                db
            }
        } catch (e: Exception) {
            Log.e(TAG, "safeDb() reopen failed: ${e.message}. Attempting fresh open...")
            try {
                db = openDatabase()
                ensureSchema()
                db
            } catch (e2: Exception) {
                Log.e(TAG, "safeDb() fatal: ${e2.message}")
                db // last resort: return whatever we have
            }
        }
    }

    /**
     * Create the messages table and indexes if they don't exist.
     * Mirrors Flutter's DatabaseHelper._createDB() schema (version 8).
     */
    private fun ensureSchema() {
        try {
            db.execSQL("""
                CREATE TABLE IF NOT EXISTS messages (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    sender TEXT NOT NULL,
                    message TEXT NOT NULL,
                    app TEXT NOT NULL,
                    timestamp INTEGER NOT NULL,
                    isDeleted INTEGER DEFAULT 0,
                    isRead INTEGER DEFAULT 0,
                    senderName TEXT,
                    isGroupChat INTEGER DEFAULT 0,
                    avatarPath TEXT,
                    mediaPath TEXT,
                    isSaved INTEGER DEFAULT 0
                )
            """.trimIndent())

            // Indexes for dedup and conversation queries
            db.execSQL("""
                CREATE INDEX IF NOT EXISTS idx_dedup
                ON messages(sender, app, message, timestamp)
            """.trimIndent())
            db.execSQL("""
                CREATE INDEX IF NOT EXISTS idx_sender
                ON messages(sender)
            """.trimIndent())
            db.execSQL("""
                CREATE INDEX IF NOT EXISTS idx_conversations_base
                ON messages(sender, app, isDeleted, timestamp)
            """.trimIndent())
            db.execSQL("""
                CREATE INDEX IF NOT EXISTS idx_conversations_unread
                ON messages(sender, app, isDeleted, isRead)
            """.trimIndent())

            // media_attachments table (v7)
            db.execSQL("""
                CREATE TABLE IF NOT EXISTS media_attachments (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    notification_id INTEGER,
                    candidate_notification_ids TEXT,
                    media_type TEXT NOT NULL,
                    file_path TEXT NOT NULL,
                    original_uri TEXT NOT NULL,
                    sender_name TEXT,
                    captured_at INTEGER NOT NULL,
                    matched INTEGER NOT NULL DEFAULT 0
                )
            """.trimIndent())
            db.execSQL("""
                CREATE INDEX IF NOT EXISTS idx_media_notification
                ON media_attachments(notification_id)
            """.trimIndent())
            db.execSQL("""
                CREATE INDEX IF NOT EXISTS idx_media_captured
                ON media_attachments(captured_at)
            """.trimIndent())

            // Ensure all columns exist (handles upgrades from older versions)
            ensureColumns()

            // Run cleanup only once per 5 minutes to avoid heavy JOIN queries
            // running on every service restart during active message bursts.
            // Previously called unconditionally here, it caused DB lock contention
            // when Flutter was simultaneously writing via sqflite.
            maybeRunCleanup()

            Log.i(TAG, "Schema verified/created successfully")
        } catch (e: Exception) {
            Log.e(TAG, "Schema initialization error: ${e.message}")
        }
    }

    /**
     * Run cleanupCorruptedMediaLinks at most once every 5 minutes.
     * Uses SharedPreferences to persist the last-run timestamp across
     * service restarts (which happen frequently on OEM devices).
     */
    private fun maybeRunCleanup() {
        try {
            val prefs = appContext.getSharedPreferences("nativedb_state", Context.MODE_PRIVATE)
            val lastRun = prefs.getLong("last_cleanup_ms", 0L)
            val now = System.currentTimeMillis()
            val minIntervalMs = 5 * 60 * 1000L // 5 minutes
            if (now - lastRun < minIntervalMs) {
                Log.d(TAG, "cleanupCorruptedMediaLinks skipped (ran ${(now - lastRun) / 1000}s ago)")
                return
            }
            prefs.edit().putLong("last_cleanup_ms", now).apply()
            // Delay cleanup by 12 seconds so startup DB queries & Flutter UI initialization complete first
            // and must never block the notification posting thread or startup sequence.
            Thread {
                try {
                    Thread.sleep(12_000L)
                    cleanupCorruptedMediaLinks()
                } catch (e: Exception) {
                    Log.w(TAG, "Background cleanup error: ${e.message}")
                }
            }.start()
        } catch (e: Exception) {
            Log.w(TAG, "maybeRunCleanup error: ${e.message}")
        }
    }

    /**
     * Safety net: add columns that may be missing from older DB versions.
     * Same logic as Flutter's DatabaseHelper._ensureColumns().
     */
    private fun ensureColumns() {
        try {
            val cursor = safeDb().rawQuery("PRAGMA table_info(messages)", null)
            val columnNames = mutableSetOf<String>()
            while (cursor.moveToNext()) {
                val nameIdx = cursor.getColumnIndex("name")
                if (nameIdx >= 0) {
                    columnNames.add(cursor.getString(nameIdx))
                }
            }
            cursor.close()

            val requiredColumns = mapOf(
                "isRead" to "INTEGER DEFAULT 0",
                "senderName" to "TEXT",
                "isGroupChat" to "INTEGER DEFAULT 0",
                "avatarPath" to "TEXT",
                "mediaPath" to "TEXT",
                "isSaved" to "INTEGER DEFAULT 0"
            )

            for ((name, type) in requiredColumns) {
                if (!columnNames.contains(name)) {
                    try {
                        safeDb().execSQL("ALTER TABLE messages ADD COLUMN $name $type")
                        Log.i(TAG, "Added missing column: $name")
                    } catch (e: Exception) {
                        // Column may already exist
                        Log.d(TAG, "Column $name add skipped: ${e.message}")
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "ensureColumns error: ${e.message}")
        }
    }

    /**
     * Insert a message into the SQLite database with ±2s dedup.
     *
     * Returns the row ID if inserted, or -1 if skipped (duplicate or error).
     *
     * NOTE: This does NOT handle encryption. Encryption is disabled by default
     * and is managed exclusively by the Flutter EncryptionService. When encryption
     * is enabled, Flutter re-encrypts on read — the native side stores plain text.
     */
    fun insertMessage(
        sender: String,
        message: String,
        app: String,
        timestampMs: Long,
        senderName: String,
        isGroupChat: Boolean,
        avatarPath: String? = null,
        mediaPath: String? = null
    ): Long {
        try {
            val dedupWindowMs = 2000L // ±2 seconds, matches Flutter's window
            val database = safeDb() // Use resilient connection

            // Dedup check: same sender + app + message within ±2s
            val isDuplicate = database.query(
                "messages",
                arrayOf("id"),
                "sender = ? AND app = ? AND message = ? AND timestamp BETWEEN ? AND ?",
                arrayOf(
                    sender, app, message,
                    (timestampMs - dedupWindowMs).toString(),
                    (timestampMs + dedupWindowMs).toString()
                ),
                null, null, null, "1"
            ).use { it.count > 0 }

            if (isDuplicate) {
                // Not a new message — but if it has media and the existing row doesn't,
                // update the existing row's mediaPath
                if (mediaPath != null) {
                    updateMediaPathIfMissing(sender, app, message, timestampMs, dedupWindowMs, mediaPath)
                }
                return -1L
            }

            val values = ContentValues().apply {
                put("sender", sender)
                put("message", message)
                put("app", app)
                put("timestamp", timestampMs)
                put("isDeleted", 0)
                put("isRead", 0)
                put("senderName", senderName)
                put("isGroupChat", if (isGroupChat) 1 else 0)
                if (avatarPath != null) put("avatarPath", avatarPath)
                if (mediaPath != null) put("mediaPath", mediaPath)
            }

            val rowId = database.insertWithOnConflict(
                "messages", null, values,
                SQLiteDatabase.CONFLICT_IGNORE
            )

            if (rowId > 0) {
                Log.i(TAG, "✓ Inserted #$rowId from '$sender' (media=${mediaPath != null})")
                // Reverse-link waiting media if this message arrived without media (or with a temporary image preview for a video) AND is an explicit media placeholder
                val isVideoPlaceholder = message.lowercase().let { 
                    it.contains("video") || it.contains("🎥") || it.contains("📹") 
                }
                val canCheckWaitingMedia = (mediaPath == null || (isVideoPlaceholder && (mediaPath.endsWith(".jpg", ignoreCase = true) || mediaPath.endsWith(".jpeg", ignoreCase = true) || mediaPath.endsWith(".png", ignoreCase = true))))
                if (canCheckWaitingMedia && isMediaPlaceholderText(message) && app.contains("whatsapp")) {
                    linkWaitingMediaToMessage(rowId, sender, senderName, message, timestampMs)
                }
                MainActivity.notifyFlutterMessageOrMediaUpdated()
            }
            return rowId
        } catch (e: Exception) {
            Log.e(TAG, "insertMessage error: ${e.message}")
            return -1L
        }
    }

    /**
     * Checks if a message text represents an explicit media placeholder
     * (e.g. "Photo", "Video", "📷 Photo", "Voice Message", or empty text).
     * Plain text messages (like "Tu bata", "Sett", "Ok") and reactions return false.
     */
    fun isMediaPlaceholderText(text: String?): Boolean {
        if (text == null || text.isBlank()) return true
        val lower = text.lowercase().trim()
        if (lower.startsWith("reacted ") || lower.startsWith("reacted to ")) return false
        
        // ── CALL NOTIFICATION EXCLUSION ─────────────────────────────
        // "Missed voice call" contains "voice", which previously matched
        // the audio placeholder check below. Call notifications are NOT
        // media placeholders and must NEVER trigger media linking.
        if (lower.contains("call") && (lower.contains("missed") || lower.contains("incoming") || 
            lower.contains("ongoing") || lower.contains("ringing") || lower.contains("ended"))) {
            return false
        }
        if (lower == "voice call" || lower == "video call" || lower == "group call") return false
        
        // Exact WhatsApp notification labels (WhatsApp uses these when sending media without caption)
        val exactLabels = setOf(
            "photo", "image", "voice message", "voice note", "video message",
            "sticker", "gif", "contact card", "location", "live location",
            "photo omitted", "video omitted", "audio omitted", "voice message omitted", "sticker omitted", "document omitted",
            "sent a photo", "sent a video", "sent a picture", "sent an audio", "sent a voice message", "sent a document", "sent a sticker", "sent a gif"
        )
        if (exactLabels.contains(lower)) return true

        if (lower.startsWith("sent a ") || lower.startsWith("sent an ")) {
            val rest = lower.substringAfter("sent a").substringAfter("sent an").trim()
            if (rest.contains("photo") || rest.contains("video") || rest.contains("image") ||
                rest.contains("voice") || rest.contains("audio") || rest.contains("document") ||
                rest.contains("sticker") || rest.contains("gif") || rest.contains("picture")) {
                return true
            }
        }

        // Media emoji prefixes
        if (lower.startsWith("📷") || lower.startsWith("🖼") || lower.startsWith("📹") ||
            lower.startsWith("🎥") || lower.startsWith("🎞") || lower.startsWith("🎤") ||
            lower.startsWith("🎙") || lower.startsWith("🎵") || lower.startsWith("📄") ||
            lower.startsWith("📎")) {
            return true
        }

        // Internal WhatsApp filename prefixes
        if (lower.startsWith("ptt-") || lower.startsWith("aud-") || lower.startsWith("vid-") ||
            lower.startsWith("doc-") || lower.startsWith("stk-") || lower.startsWith("img-")) {
            return true
        }

        // WhatsApp duration tags: e.g. "🎤 Voice message (0:02)" or "Voice message (0:02)" or "Video (0:05)"
        if (Regex("""^[🎤🎙]\s*(?:voice|audio)?\s*(?:message|note)?(?:\s*\(\d+:\d+\))?$""").matches(lower)) return true
        if (Regex("""^voice\s+(?:message|note)(?:\s*\(\d+:\d+\))?$""").matches(lower)) return true
        if (Regex("""^(?:voice|audio)\s*\(\d+:\d+\)$""").matches(lower)) return true
        if (Regex("""^[🎥📹]\s*video(?:\s*\(\d+:\d+\))?$""").matches(lower)) return true
        if (Regex("""^video\s*\(\d+:\d+\)$""").matches(lower)) return true

        // Document extensions at the end of filename
        if (Regex("""\.(pdf|docx?|xlsx?|pptx?|txt|zip|rar|csv)$""").containsMatchIn(lower)) return true

        return false
    }

    /**
     * One-time database cleanup to repair historical misattributions, duplicates,
     * and reaction messages that erroneously got media links.
     */
    fun cleanupCorruptedMediaLinks() {
        try {
            val database = safeDb() // Use resilient connection
            database.beginTransactionNonExclusive()
            try {
                // 1. Clear mediaPath on emoji reaction messages
                database.execSQL("""
                    UPDATE messages 
                    SET mediaPath = NULL 
                    WHERE (message LIKE 'Reacted %' OR message LIKE 'Reacted to %') 
                      AND mediaPath IS NOT NULL 
                      AND mediaPath != ''
                """.trimIndent())

                // 1b. Clear mediaPath on call notification messages (e.g. "Missed voice call")
                // WhatsApp call notifications are NOT messages and must NEVER have media attached.
                database.execSQL("""
                    UPDATE messages 
                    SET mediaPath = NULL 
                    WHERE ((LOWER(message) LIKE '%call%' 
                            AND (LOWER(message) LIKE '%missed%' 
                                 OR LOWER(message) LIKE '%incoming%' 
                                 OR LOWER(message) LIKE '%ongoing%' 
                                 OR LOWER(message) LIKE '%ringing%' 
                                 OR LOWER(message) LIKE '%ended%'))
                           OR LOWER(message) = 'voice call'
                           OR LOWER(message) = 'video call'
                           OR LOWER(message) = 'group call')
                      AND mediaPath IS NOT NULL 
                      AND mediaPath != ''
                """.trimIndent())

                // 1c. Delete WhatsApp system and security notifications that were mistakenly saved as chat messages
                // (e.g. "Recent WhatsApp login", "WhatsApp Web", "Checking for new messages", etc.)
                database.execSQL("""
                    DELETE FROM messages 
                    WHERE app LIKE '%whatsapp%' 
                      AND (
                        LOWER(sender) LIKE '%whatsapp login%' 
                        OR LOWER(sender) LIKE '%recent whatsapp login%' 
                        OR LOWER(sender) LIKE '%recent login%' 
                        OR LOWER(sender) = 'whatsapp' 
                        OR LOWER(sender) = 'whatsapp web' 
                        OR LOWER(sender) = 'whatsapp desktop' 
                        OR LOWER(message) LIKE '%logged in to whatsapp%' 
                        OR LOWER(message) LIKE '%log in to whatsapp%' 
                        OR LOWER(message) LIKE '%checking for new messages%' 
                        OR LOWER(message) LIKE '%whatsapp web is currently active%'
                        OR LOWER(message) LIKE '%backup in progress%'
                      )
                """.trimIndent())

                // 1d. Clear audio mediaPath on messages that have text that is NOT an audio placeholder
                // (e.g. "Voice note ka masla he", "Send me a voice note", "Tu bata", etc.)
                // WhatsApp voice notes (.opus, .m4a, .mp3, etc.) NEVER carry text captions.
                try {
                    val audioUnlinkIds = mutableListOf<Long>()
                    database.rawQuery("""
                        SELECT id, message, mediaPath FROM messages 
                        WHERE app LIKE '%whatsapp%' 
                          AND mediaPath IS NOT NULL AND mediaPath != ''
                          AND (
                              LOWER(mediaPath) LIKE '%.opus' 
                              OR LOWER(mediaPath) LIKE '%.m4a' 
                              OR LOWER(mediaPath) LIKE '%.mp3' 
                              OR LOWER(mediaPath) LIKE '%.wav' 
                              OR LOWER(mediaPath) LIKE '%.ogg' 
                              OR LOWER(mediaPath) LIKE '%.aac'
                          )
                    """.trimIndent(), null).use { audioCur ->
                        while (audioCur.moveToNext()) {
                            val mId = audioCur.getLong(0)
                            val mText = audioCur.getString(1) ?: ""
                            if (!isMediaPlaceholderText(mText)) {
                                audioUnlinkIds.add(mId)
                            }
                        }
                    }
                    for (id in audioUnlinkIds) {
                        database.execSQL("UPDATE messages SET mediaPath = NULL WHERE id = ?", arrayOf(id.toString()))
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "Error cleaning erroneously linked audio messages: ${e.message}")
                }

                // 2. Find any mediaPath that is assigned to more than 1 message
                val duplicatePaths = mutableListOf<String>()
                database.rawQuery("""
                    SELECT mediaPath, COUNT(*) as cnt 
                    FROM messages 
                    WHERE mediaPath IS NOT NULL AND mediaPath != '' 
                    GROUP BY mediaPath 
                    HAVING cnt > 1
                """.trimIndent(), null).use { dupCursor ->
                    while (dupCursor.moveToNext()) {
                        val p = dupCursor.getString(0)
                        if (!p.isNullOrEmpty()) duplicatePaths.add(p)
                    }
                }

                for (path in duplicatePaths) {
                    val rows = mutableListOf<Triple<Long, String, Long>>()
                    database.rawQuery("""
                        SELECT id, message, timestamp 
                        FROM messages 
                        WHERE mediaPath = ? 
                        ORDER BY timestamp ASC
                    """.trimIndent(), arrayOf(path)).use { msgCursor ->
                        while (msgCursor.moveToNext()) {
                            rows.add(Triple(msgCursor.getLong(0), msgCursor.getString(1) ?: "", msgCursor.getLong(2)))
                        }
                    }

                    var winnerId: Long? = null
                    val otherIds = mutableListOf<Long>()

                    for (row in rows) {
                        if (winnerId == null && isMediaPlaceholderText(row.second)) {
                            winnerId = row.first
                        } else {
                            otherIds.add(row.first)
                        }
                    }

                    if (winnerId == null && rows.isNotEmpty()) {
                        winnerId = rows.first().first
                        otherIds.clear()
                        for (i in 1 until rows.size) {
                            otherIds.add(rows[i].first)
                        }
                    }

                    for (id in otherIds) {
                        database.execSQL("UPDATE messages SET mediaPath = NULL WHERE id = ?", arrayOf(id.toString()))
                    }
                }

                // 3. Clear matched media_attachments where notification_id points to message with null mediaPath
                database.execSQL("""
                    UPDATE media_attachments 
                    SET matched = 0, notification_id = NULL 
                    WHERE matched = 1 
                      AND notification_id IS NOT NULL 
                      AND notification_id NOT IN (
                          SELECT id FROM messages WHERE mediaPath IS NOT NULL AND mediaPath != ''
                      )
                """.trimIndent())

                // 4. Unlink cross-chat misattributions where media_attachments sender differs from messages sender
                database.execSQL("""
                    UPDATE messages 
                    SET mediaPath = NULL 
                    WHERE id IN (
                        SELECT m.id 
                        FROM messages m 
                        JOIN media_attachments a ON a.file_path = m.mediaPath 
                        WHERE a.sender_name IS NOT NULL 
                          AND a.sender_name != '' 
                          AND a.sender_name NOT LIKE '%.%' 
                          AND LOWER(TRIM(m.sender)) != LOWER(TRIM(a.sender_name)) 
                          AND LOWER(TRIM(m.senderName)) != LOWER(TRIM(a.sender_name))
                    )
                """.trimIndent())

                // 5. Unlink audio/voice notes where time delta is > 2 minutes (120,000 ms)
                database.execSQL("""
                    UPDATE messages 
                    SET mediaPath = NULL 
                    WHERE id IN (
                        SELECT m.id 
                        FROM messages m 
                        JOIN media_attachments a ON a.file_path = m.mediaPath 
                        WHERE (a.media_type = 'audio' OR m.mediaPath LIKE '%.opus')
                          AND ABS(m.timestamp - a.captured_at) > 120000
                    )
                """.trimIndent())

                // 6. Reset matched flag on unlinked media_attachments
                database.execSQL("""
                    UPDATE media_attachments 
                    SET matched = 0, notification_id = NULL 
                    WHERE matched = 1 
                      AND notification_id IS NOT NULL 
                      AND notification_id NOT IN (
                          SELECT id FROM messages WHERE mediaPath IS NOT NULL AND mediaPath != ''
                      )
                """.trimIndent())

                // 7. Auto-reconcile orphaned recent media placeholders (last 24 hours)
                // If a WhatsApp message was saved with text like "Photo" or "Video" but mediaPath is null,
                // and an unmatched media_attachment of matching type exists, link them!
                try {
                    val recentCutoff = System.currentTimeMillis() - 24 * 60 * 60 * 1000L
                    val unlinkedMessages = mutableListOf<Map<String, Any>>()
                    
                    database.rawQuery("""
                        SELECT id, sender, senderName, message, timestamp 
                        FROM messages 
                        WHERE (mediaPath IS NULL OR mediaPath = '') 
                          AND app LIKE '%whatsapp%' 
                          AND timestamp >= $recentCutoff
                          AND message NOT LIKE 'Reacted %'
                        ORDER BY timestamp DESC
                    """.trimIndent(), null).use { unlinkedCursor ->
                        while (unlinkedCursor.moveToNext()) {
                            val mId = unlinkedCursor.getLong(0)
                            val mSender = unlinkedCursor.getString(1) ?: ""
                            val mSenderName = unlinkedCursor.getString(2) ?: ""
                            val mText = unlinkedCursor.getString(3) ?: ""
                            val mTs = unlinkedCursor.getLong(4)
                            if (isMediaPlaceholderText(mText)) {
                                unlinkedMessages.add(mapOf(
                                    "id" to mId,
                                    "sender" to mSender,
                                    "senderName" to mSenderName,
                                    "text" to mText,
                                    "timestamp" to mTs
                                ))
                            }
                        }
                    }

                    for (msg in unlinkedMessages) {
                        val mId = msg["id"] as Long
                        val mSender = msg["sender"] as String
                        val mSenderName = msg["senderName"] as String
                        val mText = (msg["text"] as String).lowercase()
                        val mTs = msg["timestamp"] as Long

                        val targetType = when {
                            mText.contains("photo") || mText.contains("image") || mText.contains("📷") || mText.contains("🖼") -> "image"
                            mText.contains("video") || mText.contains("📹") || mText.contains("🎥") -> "video"
                            mText.contains("document") || mText.contains("file") || mText.contains("📄") || mText.contains("📎") -> "document"
                            mText.contains("voice") || mText.contains("audio") || mText.contains("🎤") || mText.contains("🎙") -> "audio"
                            else -> null
                        } ?: continue

                        // Look for an unmatched attachment of matching type where sender either matches or is empty/filename
                        database.rawQuery("""
                            SELECT id, file_path, sender_name 
                            FROM media_attachments 
                            WHERE matched = 0 
                              AND media_type = ?
                              AND (sender_name IS NULL OR sender_name = '' OR sender_name LIKE '%.%' OR LOWER(TRIM(sender_name)) = LOWER(?) OR LOWER(TRIM(sender_name)) = LOWER(?))
                              AND file_path NOT IN (SELECT mediaPath FROM messages WHERE mediaPath IS NOT NULL AND mediaPath != '')
                            ORDER BY ABS(captured_at - $mTs) ASC 
                            LIMIT 1
                        """.trimIndent(), arrayOf(targetType, mSender.trim(), mSenderName.trim())).use { attachCursor ->
                            if (attachCursor.moveToFirst()) {
                                val aId = attachCursor.getLong(0)
                                val fPath = attachCursor.getString(1)
                                val file = File(fPath)
                                if (file.exists() && file.length() > 0L) {
                                    database.execSQL("UPDATE messages SET mediaPath = ? WHERE id = ?", arrayOf(fPath, mId.toString()))
                                    database.execSQL("UPDATE media_attachments SET matched = 1, notification_id = ?, sender_name = ? WHERE id = ?", 
                                        arrayOf(mId.toString(), mSender, aId.toString()))
                                    Log.i(TAG, "✓ Auto-reconciled orphaned $targetType $fPath to message #$mId ($mSender)")
                                }
                            }
                        }
                    }

                    // 7b. Recover any unindexed files in media_attachments dir from the last 24 hours
                    val attachmentsDir = File(appContext.filesDir, "media_attachments")
                    if (attachmentsDir.exists()) {
                        val recentFiles = attachmentsDir.listFiles()?.filter {
                            it.isFile && it.length() > 0 &&
                            (System.currentTimeMillis() - it.lastModified() < 24 * 60 * 60 * 1000L)
                        } ?: emptyList()

                        for (f in recentFiles) {
                            val fPath = f.absolutePath
                            val isLinked = database.rawQuery(
                                "SELECT id FROM messages WHERE mediaPath = ? LIMIT 1",
                                arrayOf(fPath)
                            ).use { it.moveToFirst() }
                            if (isLinked) continue

                            val modTime = f.lastModified()
                            val fName = f.name.lowercase()
                            val isImg = fName.startsWith("img-") || fName.endsWith(".jpg") || fName.endsWith(".png") || fName.endsWith(".jpeg")
                            val isVid = fName.startsWith("vid-") || fName.endsWith(".mp4")
                            val isAud = fName.startsWith("ptt-") || fName.startsWith("aud-") || fName.endsWith(".opus")

                            val query = if (isAud) {
                                """
                                SELECT id, sender FROM messages
                                WHERE (mediaPath IS NULL OR mediaPath = '')
                                  AND app LIKE '%whatsapp%'
                                  AND ABS(timestamp - $modTime) < 180000
                                  AND (message LIKE '🎤%' OR message LIKE '🎙%' OR LOWER(message) LIKE '%voice%' OR LOWER(message) LIKE '%audio%')
                                ORDER BY ABS(timestamp - $modTime) ASC
                                LIMIT 1
                                """
                            } else {
                                """
                                SELECT id, sender FROM messages
                                WHERE (mediaPath IS NULL OR mediaPath = '')
                                  AND app LIKE '%whatsapp%'
                                  AND ABS(timestamp - $modTime) < 300000
                                  AND message NOT LIKE 'Reacted %'
                                ORDER BY ABS(timestamp - $modTime) ASC
                                LIMIT 1
                                """
                            }

                            database.rawQuery(query.trimIndent(), null).use { cur ->
                                if (cur.moveToFirst()) {
                                    val mId = cur.getLong(0)
                                    val sender = cur.getString(1) ?: ""
                                    database.execSQL("UPDATE messages SET mediaPath = ? WHERE id = ?", arrayOf(fPath, mId.toString()))
                                    val mType = if (isVid) "video" else if (isAud) "audio" else "image"
                                    database.execSQL("""
                                        INSERT OR REPLACE INTO media_attachments (notification_id, media_type, file_path, original_uri, sender_name, captured_at, matched)
                                        VALUES (?, ?, ?, '', ?, ?, 1)
                                    """.trimIndent(), arrayOf(mId.toString(), mType, fPath, sender, modTime.toString()))
                                    Log.i(TAG, "✓ Recovered unindexed file $fPath -> linked to msg #$mId ($sender)")
                                }
                            }
                        }
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "Auto-reconcile orphaned media error: ${e.message}")
                }

                database.setTransactionSuccessful()
                Log.i(TAG, "✓ Completed cleanupCorruptedMediaLinks")
            } finally {
                database.endTransaction()
            }
        } catch (e: Exception) {
            Log.e(TAG, "cleanupCorruptedMediaLinks error: ${e.message}")
        }
    }

    /**
     * Checks whether a media path is already linked to any message in the database.
     */
    fun isMediaAlreadyLinked(mediaPath: String): Boolean {
        try {
            val database = safeDb()
            val inMessages = database.rawQuery("SELECT id FROM messages WHERE mediaPath = ? LIMIT 1", arrayOf(mediaPath)).use { it.moveToFirst() }
            if (inMessages) return true

            return database.rawQuery("SELECT id FROM media_attachments WHERE file_path = ? AND matched = 1 AND notification_id IS NOT NULL LIMIT 1", arrayOf(mediaPath)).use { it.moveToFirst() }
        } catch (e: Exception) {
            return false
        }
    }

    /**
     * Batch insert multiple messages in a single transaction.
     * Returns a list of inserted row IDs (or -1L for duplicates/errors).
     */
    fun insertMessagesBatch(messages: List<Map<String, Any?>>): List<Long> {
        if (messages.isEmpty()) return emptyList()

        val insertedIds = mutableListOf<Long>()
        var insertedCount = 0
        try {
            val database = safeDb()
            database.beginTransactionNonExclusive()
            try {
                for (msg in messages) {
                    val sender = msg["sender"] as? String
                    val message = msg["message"] as? String
                    val app = msg["app"] as? String
                    val timestampMs = msg["timestampMs"] as? Long
                    if (sender == null || message == null || app == null || timestampMs == null) {
                        insertedIds.add(-1L)
                        continue
                    }
                    val result = insertMessage(
                        sender = sender,
                        message = message,
                        app = app,
                        timestampMs = timestampMs,
                        senderName = msg["senderName"] as? String ?: "",
                        isGroupChat = msg["isGroupChat"] as? Boolean ?: false,
                        avatarPath = msg["avatarPath"] as? String,
                        mediaPath = msg["mediaPath"] as? String
                    )
                    insertedIds.add(result)
                    if (result > 0) insertedCount++
                }
                database.setTransactionSuccessful()
            } finally {
                database.endTransaction()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Batch insert error: ${e.message}")
        }

        if (insertedCount > 0) {
            Log.i(TAG, "✓ Batch inserted $insertedCount/${messages.size} messages")
            MainActivity.notifyFlutterMessageOrMediaUpdated()
        }
        return insertedIds
    }

    /**
     * If a dedup-matched message exists without media, update its mediaPath.
     * Handles the WhatsApp double-post pattern where the text message arrives
     * first, then a second notification brings the BigPicture media.
     */
    private fun updateMediaPathIfMissing(
        sender: String, app: String, message: String,
        timestampMs: Long, windowMs: Long, mediaPath: String
    ) {
        try {
            val effectiveWindow = maxOf(windowMs, 60_000L) // Allow up to 60s for double-post arrival
            val start = timestampMs - effectiveWindow
            val end = timestampMs + effectiveWindow
            val database = safeDb()
            val values = ContentValues().apply {
                put("mediaPath", mediaPath)
            }
            val isVideo = mediaPath.endsWith(".mp4", ignoreCase = true)
            val mediaPathCond = if (isVideo) 
                "(mediaPath IS NULL OR mediaPath = '' OR mediaPath LIKE '%.jpg' OR mediaPath LIKE '%.jpeg' OR mediaPath LIKE '%.png')"
            else 
                "(mediaPath IS NULL OR mediaPath = '')"

            val rows = database.update(
                "messages",
                values,
                "sender = ? AND app = ? AND $mediaPathCond AND timestamp BETWEEN ? AND ? AND message NOT LIKE 'Reacted %' AND message NOT LIKE 'Reacted to %'",
                arrayOf(sender, app, start.toString(), end.toString())
            )
            if (rows > 0) {
                Log.d(TAG, "Updated mediaPath for existing message ($rows rows): $mediaPath")
                // Also update media_attachments to track as matched
                try {
                    val file = File(mediaPath)
                    val attachVals = ContentValues().apply {
                        put("sender_name", sender)
                        put("matched", 1)
                    }
                    database.update("media_attachments", attachVals, "file_path = ?", arrayOf(mediaPath))
                } catch (_: Exception) {}
                MainActivity.notifyFlutterMessageOrMediaUpdated()
            }
        } catch (e: Exception) {
            Log.d(TAG, "updateMediaPathIfMissing skipped: ${e.message}")
        }
    }

    /**
     * Reverse-linking: When a message arrives without media, check if a media file
     * was already captured and is waiting in media_attachments (matched = 0).
     * Enforces strict media type matching and sender matching, completely rejecting
     * plain text messages.
     */
    private fun linkWaitingMediaToMessage(messageId: Long, sender: String, senderName: String, messageText: String, timestampMs: Long) {
        try {
            // ── CALL NOTIFICATION GUARD ─────────────────────────────────
            // If the message text is a call notification, NEVER link media to it.
            val lowerMsg = messageText.lowercase().trim()
            if (lowerMsg.contains("call") && (lowerMsg.contains("missed") || lowerMsg.contains("incoming") || 
                lowerMsg.contains("ongoing") || lowerMsg.contains("ringing") || lowerMsg.contains("ended"))) {
                Log.d(TAG, "linkWaitingMediaToMessage: skipping call text '$messageText'")
                return
            }
            
            val now = System.currentTimeMillis()
            val windowStart = minOf(timestampMs, now) - 24 * 60 * 60 * 1000L // 24 hours
            val windowEnd = maxOf(timestampMs, now) + 60_000L // 1 min future buffer for clock skew
            val database = safeDb() // Use resilient connection for the whole linking operation
            val cursor = database.rawQuery(
                """
                SELECT id, media_type, file_path, captured_at, sender_name 
                FROM media_attachments 
                WHERE matched = 0 
                  AND captured_at BETWEEN $windowStart AND $windowEnd
                ORDER BY ABS(captured_at - $timestampMs) ASC 
                LIMIT 10
                """.trimIndent(),
                null
            )

            var matchedAttachmentId: Long? = null
            var matchedFilePath: String? = null

            cursor.use {
                while (it.moveToNext()) {
                    val attachId = it.getLong(0)
                    val mType = it.getString(1) ?: ""
                    val fPath = it.getString(2) ?: ""
                    val capAt = it.getLong(3)
                    val attachSender = it.getString(4) ?: ""

                    val file = File(fPath)
                    if (!file.exists() || file.length() <= 0L) continue

                    // Check if this file is already linked in the messages table
                    val alreadyUsed = database.rawQuery("SELECT id FROM messages WHERE mediaPath = ? LIMIT 1", arrayOf(fPath)).use { it.moveToFirst() }
                    if (alreadyUsed) {
                        // Mark as matched so it won't be checked again
                        val markVals = ContentValues().apply { put("matched", 1) }
                        database.update("media_attachments", markVals, "id = ?", arrayOf(attachId.toString()))
                        continue
                    }

                    // ── STRICT SENDER MATCHING ──────────────────────────────
                    // A sender_name that is really a captured file name (stored when no sender was known).
                    // NOTE: previously ANY sender containing '.' was rejected, which broke legit chat
                    // names like "Dr. Ali" or "m.suleman_.05". Detect real filenames precisely instead.
                    val attachSenderIsFilename = attachSender.contains('.') && (
                        attachSender.startsWith("IMG-") || attachSender.startsWith("VID-") ||
                        attachSender.startsWith("AUD-") || attachSender.startsWith("PTT-") ||
                        attachSender.startsWith("DOC-") || attachSender.startsWith("STK-") ||
                        attachSender.endsWith(".jpg") || attachSender.endsWith(".jpeg") ||
                        attachSender.endsWith(".mp4") || attachSender.endsWith(".opus") ||
                        attachSender.endsWith(".webp") || attachSender.endsWith(".aac") ||
                        attachSender.endsWith(".pdf") || attachSender.endsWith(".zip")
                    )

                    // Sender-confirmed files must ALSO be close in time to this message (5 min) so a
                    // stale unlinked file from the same chat is never attached to a newer message.
                    // Audio keeps its existing behaviour.
                    val closeInTime = mType == "audio" || Math.abs(capAt - timestampMs) <= 300_000L

                    val senderMatches = attachSender.isNotEmpty() && !attachSenderIsFilename && closeInTime && (
                        attachSender.equals(sender, ignoreCase = true) ||
                        (senderName.isNotEmpty() && attachSender.equals(senderName, ignoreCase = true)) ||
                        attachSender.trim().equals(sender.trim(), ignoreCase = true)
                    )

                    // ── UNASSIGNED SENDER FALLBACK ───────────────────────────────────────
                    // When a file is captured by ContentObserver before the notification
                    // arrives, it is stored with sender_name = fileName (e.g. "IMG-xxx.jpg")
                    // or empty string. We allow reverse-linking under strict time constraints:
                    //
                    //   • attachSender == ""       → truly unknown sender: 45s window (rare case)
                    //   • attachSender == fileName → captured without a sender: 10s tight window
                    //     (was 45s — the primary cause of cross-user misattribution)
                    //
                    // In both cases the media type must explicitly match the message text;
                    // blank messages are NOT accepted as wildcards (see requireExplicitMediaKeyword).

                    val isRecentUnassigned = when {
                        // Audio/voice notes: allow reverse-linking within 45s of arrival if no collision
                        mType == "audio" -> Math.abs(capAt - timestampMs) <= 45_000L
                        // Truly empty — 30s window
                        attachSender.isEmpty() -> Math.abs(capAt - timestampMs) <= 30_000L
                        // Filename stored as sender — captured without notification: 30s window
                        attachSenderIsFilename -> Math.abs(capAt - timestampMs) <= 30_000L
                        else -> false
                    }

                    // For the unconfirmed path: require an explicit media keyword in the message.
                    // A blank placeholder (lowerMsg.isEmpty()) alone must NOT match an unknown-sender
                    // file — that was the direct cause of "Mamma Photo/Video" misattribution.
                    val requireExplicitMediaKeyword = !senderMatches && isRecentUnassigned

                    if (!senderMatches && !isRecentUnassigned) {
                        continue
                    }

                    // ── ANTI-COLLISION PRIVACY GUARD ──────────────────────────────────────────
                    // For unassigned audio (mType == "audio"), verify that NO OTHER chat in the
                    // database also received an unlinked voice note within this 45-second window.
                    // If multiple chats qualify, abort immediately so audio is never linked to the wrong user!
                    if (mType == "audio" && !senderMatches) {
                        val otherAudioCount = database.rawQuery("""
                            SELECT COUNT(DISTINCT sender) FROM messages 
                            WHERE app LIKE '%whatsapp%' 
                              AND id != ? 
                              AND (mediaPath IS NULL OR mediaPath = '') 
                              AND timestamp BETWEEN ? AND ?
                              AND (LOWER(message) LIKE '%voice%' OR LOWER(message) LIKE '%audio%' OR LOWER(message) LIKE '%🎤%' OR LOWER(message) LIKE '%🎙%')
                        """.trimIndent(), arrayOf(
                            messageId.toString(),
                            (timestampMs - 45_000L).toString(),
                            (timestampMs + 45_000L).toString()
                        )).use { if (it.moveToFirst()) it.getInt(0) else 0 }

                        if (otherAudioCount > 0) {
                            Log.w(TAG, "Ambiguous unassigned audio detected ($otherAudioCount other chats). Aborting link to prevent cross-chat misattribution.")
                            continue
                        }
                    }

                    val cleanBase = file.nameWithoutExtension.lowercase()
                    val isMatch = when (mType) {
                        "image" -> !requireExplicitMediaKeyword || isMediaPlaceholderText(lowerMsg) || (cleanBase.length >= 3 && lowerMsg.contains(cleanBase))
                        "video" -> !requireExplicitMediaKeyword || isMediaPlaceholderText(lowerMsg) || (cleanBase.length >= 3 && lowerMsg.contains(cleanBase))
                        "audio" -> isMediaPlaceholderText(lowerMsg) || (!requireExplicitMediaKeyword && lowerMsg.isEmpty())
                        "document" -> !requireExplicitMediaKeyword || isMediaPlaceholderText(lowerMsg) || (cleanBase.length >= 3 && lowerMsg.contains(cleanBase))
                        else -> false
                    }

                    if (isMatch && !lowerMsg.startsWith("reacted ")) {
                        matchedAttachmentId = attachId
                        matchedFilePath = fPath
                        break
                    }
                }
            }

            if (matchedAttachmentId != null && matchedFilePath != null) {
                database.beginTransactionNonExclusive()
                try {
                    val msgVals = ContentValues().apply { put("mediaPath", matchedFilePath) }
                    database.update("messages", msgVals, "id = ?", arrayOf(messageId.toString()))

                    val attachVals = ContentValues().apply {
                        put("notification_id", messageId)
                        put("sender_name", sender)
                        put("matched", 1)
                    }
                    database.update("media_attachments", attachVals, "id = ?", arrayOf(matchedAttachmentId.toString()))

                    database.setTransactionSuccessful()
                    Log.i(TAG, "✓ Reverse-linked waiting media $matchedFilePath to msg #$messageId ($sender)")
                } finally {
                    database.endTransaction()
                }
                MainActivity.notifyFlutterMessageOrMediaUpdated()
            }
        } catch (e: Exception) {
            Log.d(TAG, "linkWaitingMediaToMessage skipped: ${e.message}")
        }
    }

    /**
     * Attempts to find a matching message in the last 24 hours that lacks a media path,
     * matching by media type. If found, updates the message and inserts the media attachment
     * in a single transaction.
     * 
     * Returns true if successfully matched and linked.
     */
    @Synchronized
    fun matchAndLinkMedia(
        fileName: String,
        mediaPath: String,
        mediaType: String, // "image", "video", "audio", "document"
        fileTimestamp: Long,
        originalUri: String,
        fileSizeBytes: Long,
        targetSender: String? = null
    ): Boolean {
        try {
            // Strict 1-to-1 Uniqueness: If mediaPath is already assigned, do NOT assign again!
            if (isMediaAlreadyLinked(mediaPath)) {
                Log.d(TAG, "mediaPath $mediaPath is already linked. Skipping duplicate linking.")
                return true
            }

            // ─────────────────────────────────────────────────────────────────────────────────
            // The no-sender fallback can now safely auto-link only when a single valid candidate
            // exists. All remaining sender-aware logic below is still used when targetSender is known.

            val now = System.currentTimeMillis()
            val effectiveTime = if (fileTimestamp > 1_000_000_000_000L) fileTimestamp else now
            // Audio files (voice notes): when targetSender is confirmed, allow up to 3 minutes window
            // (sender-scoped, 100% safe against cross-user contamination).
            // When targetSender is null (senderless), enforce tight 45s window + single candidate uniqueness!
            val windowStart = if (mediaType == "audio") {
                if (!targetSender.isNullOrBlank()) {
                    maxOf(effectiveTime - 180_000L, 0L)
                } else {
                    maxOf(minOf(effectiveTime, now) - 45_000L, 0L)
                }
            } else {
                minOf(effectiveTime, now) - 24 * 60 * 60 * 1000L
            }
            val windowEnd = if (mediaType == "audio") {
                if (!targetSender.isNullOrBlank()) {
                    effectiveTime + 120_000L
                } else {
                    minOf(effectiveTime, now) + 45_000L
                }
            } else {
                maxOf(effectiveTime, now) + 60_000L // 1 min buffer
            }

            val cleanBase = fileName.substringBeforeLast('.').lowercase()
            val cleanBaseNorm = cleanBase.replace('_', ' ')

            fun checkMatch(msgText: String): Boolean {
                // NOTE: Do NOT short-circuit on blank text here — blank messages are
                // handled upstream by isMediaPlaceholderText(). Returning true for any
                // blank text here would cause false-positive links to plain-text messages
                // that got normalized/truncated to empty.
                if (msgText.isBlank()) return false
                if (msgText.startsWith("reacted ") || msgText.startsWith("reacted to ")) return false
                // ── CALL NOTIFICATION EXCLUSION ─────────────────────────────
                // Prevent "Missed voice call" (contains "voice") from matching audio media.
                // This check is redundant with shouldProcessNotification but acts as a
                // safety net in case a call text somehow reaches the database.
                if (msgText.startsWith("reacted ") || msgText.startsWith("reacted to ")) return false
                if (msgText.contains("call") && (msgText.contains("missed") || msgText.contains("incoming") || 
                    msgText.contains("ongoing") || msgText.contains("ringing") || msgText.contains("ended"))) return false
                if (msgText == "voice call" || msgText == "video call" || msgText == "group call") return false
                if (msgText.contains("logged in to whatsapp") || msgText.contains("log in to whatsapp") ||
                    msgText.contains("checking for new messages") || msgText.contains("backup in progress") ||
                    msgText.contains("whatsapp web is currently active")) return false
                
                val matchesBase = cleanBase.length >= 3 && (
                    msgText.contains(cleanBase) ||
                    msgText.contains(cleanBaseNorm) ||
                    msgText.contains(fileName.lowercase())
                )
                return when (mediaType) {
                    "image" -> {
                        val isSticker = fileName.startsWith("STK-", ignoreCase = true) || fileName.endsWith(".webp", ignoreCase = true)
                        if (isSticker) {
                            msgText.isEmpty() || msgText == "sticker" || msgText == "gif" || msgText.contains("👾") || msgText.contains("💟") || msgText.startsWith("stk-")
                        } else {
                            // Images commonly have text captions (and DB messages may be encrypted).
                            // When targetSender is confirmed, any unlinked message from that sender is an eligible candidate!
                            !targetSender.isNullOrBlank() || isMediaPlaceholderText(msgText) || matchesBase
                        }
                    }
                    "video" -> !targetSender.isNullOrBlank() || isMediaPlaceholderText(msgText) || matchesBase
                    "audio" -> isMediaPlaceholderText(msgText)
                    "document" -> isMediaPlaceholderText(msgText) || matchesBase
                    else -> false
                }
            }

            var matchedMessageId: Long? = null
            var matchedSenderName: String = ""

            val mediaPathCond = if (mediaType == "video") 
                "(mediaPath IS NULL OR mediaPath = '' OR mediaPath LIKE '%.jpg' OR mediaPath LIKE '%.jpeg' OR mediaPath LIKE '%.png')" 
            else 
                "(mediaPath IS NULL OR mediaPath = '')"

            // Zero-touch fallback: if no sender context exists yet, only auto-link when there
            // is exactly one valid message candidate in the time window. Multiple matches remain
            // ambiguous and must be left pending instead of guessing across chats.
            if (targetSender.isNullOrBlank()) {
                var senderlessCandidateCount = 0
                var senderlessMatchId: Long? = null
                var senderlessMatchSender: String = ""

                val senderlessCursor = safeDb().rawQuery(
                    """
                    SELECT id, message, timestamp, sender, senderName
                    FROM messages
                    WHERE (app LIKE '%whatsapp%')
                      AND $mediaPathCond
                      AND timestamp BETWEEN $windowStart AND $windowEnd
                      AND (message NOT LIKE 'Reacted %' AND message NOT LIKE 'Reacted to %')
                    ORDER BY ABS(timestamp - $effectiveTime) ASC
                    """.trimIndent(), null
                )

                senderlessCursor.use {
                    while (it.moveToNext()) {
                        val msgText = it.getString(1)?.lowercase() ?: ""
                        if (!checkMatch(msgText)) continue

                        senderlessCandidateCount += 1
                        if (senderlessCandidateCount == 1) {
                            senderlessMatchId = it.getLong(0)
                            senderlessMatchSender = it.getString(4) ?: it.getString(3) ?: ""
                        } else {
                            senderlessMatchId = null
                            senderlessMatchSender = ""
                        }
                    }
                }

                if (senderlessCandidateCount == 1 && senderlessMatchId != null) {
                    matchedMessageId = senderlessMatchId
                    matchedSenderName = senderlessMatchSender
                }
            }

            // Pass 1: If targetSender is known, prioritize matching unlinked messages from that specific sender/chat
            if (!targetSender.isNullOrBlank()) {
                val cleanTarget = targetSender.trim()
                val senderCursor = safeDb().rawQuery(
                    """
                    SELECT id, message, timestamp, sender, senderName 
                    FROM messages 
                    WHERE (app LIKE '%whatsapp%') 
                      AND (sender = ? COLLATE NOCASE OR senderName = ? COLLATE NOCASE OR LOWER(TRIM(sender)) = LOWER(?) OR LOWER(TRIM(senderName)) = LOWER(?))
                      AND $mediaPathCond 
                      AND timestamp BETWEEN $windowStart AND $windowEnd
                      AND (message NOT LIKE 'Reacted %' AND message NOT LIKE 'Reacted to %')
                    ORDER BY ABS(timestamp - $effectiveTime) ASC
                    LIMIT 10
                    """.trimIndent(),
                    arrayOf(cleanTarget, cleanTarget, cleanTarget, cleanTarget)
                )

                senderCursor.use {
                    var bestGenericId: Long? = null
                    var bestGenericSender: String = ""

                    while (it.moveToNext()) {
                        val msgId = it.getLong(0)
                        val msgText = it.getString(1)?.lowercase() ?: ""
                        val sender = it.getString(3) ?: ""
                        val senderName = it.getString(4) ?: sender

                        val hasFilenameMatch = cleanBase.length >= 3 && (
                            msgText.contains(cleanBase) ||
                            msgText.contains(cleanBaseNorm) ||
                            msgText.contains(fileName.lowercase())
                        )

                        if (hasFilenameMatch) {
                            matchedMessageId = msgId
                            matchedSenderName = senderName
                            break
                        } else if (bestGenericId == null && checkMatch(msgText)) {
                            bestGenericId = msgId
                            bestGenericSender = senderName
                        }
                    }
                    if (matchedMessageId == null && bestGenericId != null) {
                        matchedMessageId = bestGenericId
                        matchedSenderName = bestGenericSender
                    }
                }
            }

            // Strict per-chat/user ID scoping:
            // Under no circumstances should unmatched media fall back to a global search across all senders in the database!
            // If Pass 1 found no matching message for targetSender, we do NOT guess or assign to another chat.
            if (matchedMessageId != null) {
                val database = safeDb()
                database.beginTransactionNonExclusive()
                try {
                    // Re-verify uniqueness inside transaction
                    val alreadyInUse = database.rawQuery("SELECT id FROM messages WHERE mediaPath = ? LIMIT 1", arrayOf(mediaPath)).use { it.moveToFirst() }
                    if (alreadyInUse) {
                        Log.w(TAG, "mediaPath $mediaPath was claimed by another thread. Aborting duplicate link.")
                        return true
                    }

                    // Update the message
                    val msgValues = ContentValues().apply {
                        put("mediaPath", mediaPath)
                    }
                    database.update("messages", msgValues, "id = ?", arrayOf(matchedMessageId.toString()))

                    // Insert or update the attachment record
                    val existingCursor = database.rawQuery("SELECT id FROM media_attachments WHERE file_path = ?", arrayOf(mediaPath))
                    val exists = existingCursor.moveToFirst()
                    val existingId = if (exists) existingCursor.getLong(0) else -1L
                    existingCursor.close()

                    if (exists) {
                        val attachValues = ContentValues().apply {
                            put("notification_id", matchedMessageId)
                            put("sender_name", matchedSenderName)
                            put("matched", 1)
                        }
                        database.update("media_attachments", attachValues, "id = ?", arrayOf(existingId.toString()))
                    } else {
                        val attachValues = ContentValues().apply {
                            put("notification_id", matchedMessageId)
                            put("media_type", mediaType)
                            put("file_path", mediaPath)
                            put("original_uri", originalUri)
                            put("sender_name", matchedSenderName)
                            put("captured_at", fileTimestamp)
                            put("matched", 1)
                        }
                        database.insert("media_attachments", null, attachValues)
                    }

                    database.setTransactionSuccessful()
                    Log.i(TAG, "✓ Natively matched and linked media $mediaType to msg $matchedMessageId ($matchedSenderName)")
                    MainActivity.notifyFlutterMessageOrMediaUpdated()
                    return true
                } finally {
                    database.endTransaction()
                }
            } else {
                // If not matched immediately with targetSender, record in media_attachments with matched = 0 and confirmed sender_name
                // so when the notification arrives later, linkWaitingMediaToMessage will claim it!
                try {
                    val database = safeDb()
                    val existingCursor = database.rawQuery("SELECT id FROM media_attachments WHERE file_path = ?", arrayOf(mediaPath))
                    val exists = existingCursor.moveToFirst()
                    existingCursor.close()
                    if (!exists) {
                        val attachValues = ContentValues().apply {
                            putNull("notification_id")
                            put("media_type", mediaType)
                            put("file_path", mediaPath)
                            put("original_uri", originalUri)
                            put("sender_name", targetSender ?: "") // Explicit targetSender, never guess fileName
                            put("captured_at", fileTimestamp)
                            put("matched", 0)
                        }
                        database.insert("media_attachments", null, attachValues)
                        Log.d(TAG, "Recorded waiting media for reverse-linking: $fileName (sender=${targetSender ?: "unknown"})")
                    }
                } catch (e: Exception) {
                    Log.d(TAG, "Failed to record waiting attachment: ${e.message}")
                }
            }
            return false
        } catch (e: Exception) {
            Log.e(TAG, "matchAndLinkMedia error: ${e.message}")
            return false
        }
    }

    /**
     * Link an asynchronously extracted media file directly to a message by sender/title and timestamp.
     */
    fun linkExtractedMediaToMessage(title: String, timestamp: Long, mediaPath: String, mediaType: String): Boolean {
        try {
            val database = safeDb()
            database.beginTransactionNonExclusive()
            try {
                // Find matching message without mediaPath
                var targetId: Long? = null
                val cursor = database.rawQuery(
                    """
                    SELECT id FROM messages 
                    WHERE (senderName = ? OR sender = ? OR sender LIKE ?) 
                      AND (mediaPath IS NULL OR mediaPath = '')
                      AND ABS(timestamp - ?) <= 60000
                      AND message NOT LIKE 'Reacted %' AND message NOT LIKE 'Reacted to %'
                    ORDER BY ABS(timestamp - ?) ASC LIMIT 1
                    """.trimIndent(),
                    arrayOf(title, title, "%$title%", timestamp.toString(), timestamp.toString())
                )
                cursor.use {
                    if (it.moveToFirst()) {
                        targetId = it.getLong(0)
                    }
                }

                if (targetId != null) {
                    val msgValues = ContentValues().apply {
                        put("mediaPath", mediaPath)
                    }
                    database.update("messages", msgValues, "id = ?", arrayOf(targetId.toString()))
                    val attachValues = ContentValues().apply {
                        put("notification_id", targetId)
                        put("media_type", mediaType)
                        put("file_path", mediaPath)
                        put("original_uri", mediaPath)
                        put("sender_name", title)
                        put("captured_at", timestamp)
                        put("matched", 1)
                    }
                    database.insertWithOnConflict("media_attachments", null, attachValues, SQLiteDatabase.CONFLICT_REPLACE)
                    database.setTransactionSuccessful()
                    Log.i(TAG, "✓ linkExtractedMediaToMessage linked $mediaPath to msg #$targetId ($title)")
                    MainActivity.notifyFlutterMessageOrMediaUpdated()
                    return true
                }
            } finally {
                database.endTransaction()
            }
        } catch (e: Exception) {
            Log.e(TAG, "linkExtractedMediaToMessage error: ${e.message}")
        }
        return false
    }

    /**
     * Rolling cache cleanup for media_attachments:
     * - Removes unmatched temporary media files older than maxAgeMs (default: 7 days)
     * - Preserves 100% of messages and media linked to messages (mediaPath)
     * - Removes orphaned/empty 0-byte or .tmp files from media_attachments directory
     * This keeps disk and resident memory within safe limits, avoiding OEM watchdog kills.
     */
    fun pruneOrphanedMedia(maxAgeMs: Long = 7L * 24 * 60 * 60 * 1000L): Int {
        var prunedCount = 0
        try {
            val database = safeDb()
            val cutoff = System.currentTimeMillis() - maxAgeMs

            // 1. Find unmatched media older than cutoff
            val stalePaths = mutableListOf<Pair<Long, String>>()
            database.rawQuery("""
                SELECT id, file_path 
                FROM media_attachments 
                WHERE matched = 0 
                  AND captured_at < $cutoff
            """.trimIndent(), null).use { cursor ->
                while (cursor.moveToNext()) {
                    val id = cursor.getLong(0)
                    val path = cursor.getString(1) ?: continue
                    stalePaths.add(Pair(id, path))
                }
            }

            for ((id, path) in stalePaths) {
                // Ensure this path is NOT currently linked to any saved message
                val isLinked = database.rawQuery(
                    "SELECT id FROM messages WHERE mediaPath = ? LIMIT 1",
                    arrayOf(path)
                ).use { it.moveToFirst() }

                if (!isLinked) {
                    try {
                        val file = File(path)
                        if (file.exists()) {
                            file.delete()
                        }
                    } catch (_: Exception) {}
                    database.execSQL("DELETE FROM media_attachments WHERE id = ?", arrayOf(id.toString()))
                    prunedCount++
                }
            }

            // 2. Scan media_attachments directory for empty or abandoned temp files
            val attachmentsDir = File(appContext.filesDir, "media_attachments")
            if (attachmentsDir.exists() && attachmentsDir.isDirectory) {
                attachmentsDir.listFiles()?.forEach { file ->
                    if (file.isFile && (file.length() == 0L || file.name.endsWith(".tmp"))) {
                        file.delete()
                        prunedCount++
                    }
                }
            }

            Log.i(TAG, "Pruned $prunedCount obsolete unlinked media attachments")
        } catch (e: Exception) {
            Log.w(TAG, "pruneOrphanedMedia error: ${e.message}")
        }
        return prunedCount
    }

    /**
     * Retention sweep: every captured WhatsApp media file (matched or not) is kept for
     * [maxAgeMs] (default 15 days) and then removed from disk and from the DB.
     * Media that belongs to a message the user explicitly saved (isSaved = 1) is never touched.
     * Also removes stray files on disk that have no DB row but are older than the cutoff.
     */
    fun pruneExpiredMedia(maxAgeMs: Long = 15L * 24 * 60 * 60 * 1000L): Int {
        var removed = 0
        try {
            val database = safeDb()
            val cutoff = System.currentTimeMillis() - maxAgeMs

            // Paths protected because the user saved the owning message
            val protectedPaths = HashSet<String>()
            database.rawQuery(
                "SELECT mediaPath FROM messages WHERE isSaved = 1 AND mediaPath IS NOT NULL AND mediaPath != ''",
                null
            ).use { c -> while (c.moveToNext()) c.getString(0)?.let { protectedPaths.add(it) } }

            // 1. DB-tracked attachments older than cutoff
            val expired = mutableListOf<Pair<Long, String>>()
            database.rawQuery(
                "SELECT id, file_path FROM media_attachments WHERE captured_at < $cutoff", null
            ).use { c ->
                while (c.moveToNext()) {
                    val path = c.getString(1) ?: continue
                    expired.add(Pair(c.getLong(0), path))
                }
            }
            for ((id, path) in expired) {
                if (path in protectedPaths) continue
                try { File(path).takeIf { it.exists() }?.delete() } catch (_: Exception) {}
                database.execSQL("UPDATE messages SET mediaPath = NULL WHERE mediaPath = ? AND isSaved = 0", arrayOf(path))
                database.execSQL("DELETE FROM media_attachments WHERE id = ?", arrayOf(id.toString()))
                removed++
            }

            // 2. Stray files on disk (no DB row / lost row) older than cutoff
            for (dirName in listOf("media_attachments", "media")) {
                val dir = File(appContext.filesDir, dirName)
                if (!dir.isDirectory) continue
                dir.listFiles()?.forEach { f ->
                    if (f.isFile && f.lastModified() < cutoff && f.absolutePath !in protectedPaths) {
                        if (f.delete()) removed++
                    }
                }
            }
            Log.i(TAG, "pruneExpiredMedia: removed $removed expired media item(s)")
        } catch (e: Exception) {
            Log.w(TAG, "pruneExpiredMedia error: ${e.message}")
        }
        return removed
    }

    /**
     * One-time cleanup: the old LargeIcon fallback saved the sender/group profile picture
     * as if it were the message's media (files named *_notif_media_*). Unlink those from
     * messages and delete the files.
     */
    fun purgeAvatarMisusedMedia(): Int {
        var count = 0
        try {
            val database = safeDb()
            val paths = mutableListOf<String>()
            database.rawQuery(
                "SELECT DISTINCT mediaPath FROM messages WHERE mediaPath LIKE '%_notif_media_%'", null
            ).use { c -> while (c.moveToNext()) c.getString(0)?.let { paths.add(it) } }
            for (p in paths) {
                database.execSQL("UPDATE messages SET mediaPath = NULL WHERE mediaPath = ?", arrayOf(p))
                try { File(p).takeIf { it.exists() }?.delete() } catch (_: Exception) {}
                count++
            }
            File(appContext.filesDir, "media").listFiles()?.forEach { f ->
                if (f.isFile && f.name.contains("_notif_media_") && f.delete()) count++
            }
            Log.i(TAG, "purgeAvatarMisusedMedia: cleaned $count item(s)")
        } catch (e: Exception) {
            Log.w(TAG, "purgeAvatarMisusedMedia error: ${e.message}")
        }
        return count
    }
}

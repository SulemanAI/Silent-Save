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
        private const val DB_VERSION = 8

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
        val database = SQLiteDatabase.openOrCreateDatabase(dbPath, null)
        // Enable WAL for concurrent reader+writer (Flutter sqflite + this Kotlin writer)
        database.enableWriteAheadLogging()
        // 8s busy timeout: gives Flutter sqflite time to release its lock before we fail.
        // Increased from 5s to be more resilient when both sides write simultaneously.
        database.execSQL("PRAGMA busy_timeout = 8000;")
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
                    mediaPath TEXT
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

            // One-time cleanup for any historically corrupted or cross-linked media
            cleanupCorruptedMediaLinks()

            Log.i(TAG, "Schema verified/created successfully")
        } catch (e: Exception) {
            Log.e(TAG, "Schema initialization error: ${e.message}")
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
                "mediaPath" to "TEXT"
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
            val cursor = database.query(
                "messages",
                arrayOf("id"),
                "sender = ? AND app = ? AND message = ? AND timestamp BETWEEN ? AND ?",
                arrayOf(
                    sender, app, message,
                    (timestampMs - dedupWindowMs).toString(),
                    (timestampMs + dedupWindowMs).toString()
                ),
                null, null, null, "1"
            )
            val isDuplicate = cursor.count > 0
            cursor.close()

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
                // Reverse-link waiting media ONLY if this message arrived without media AND is an explicit media placeholder
                if (mediaPath == null && isMediaPlaceholderText(message) && app.contains("whatsapp")) {
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
        
        val genericLabels = listOf(
            "photo", "image", "video", "audio", "voice message", "voice", "document", "file",
            "sticker", "gif", "📷", "🖼", "📹", "🎥", "🎞", "🎤", "🎙", "🎵", "📄", "📎",
            ".pdf", ".doc", ".docx", ".csv", ".xls", ".xlsx", ".txt", ".ppt", ".zip"
        )
        return genericLabels.any { lower.contains(it) }
    }

    /**
     * One-time database cleanup to repair historical misattributions, duplicates,
     * and reaction messages that erroneously got media links.
     */
    fun cleanupCorruptedMediaLinks() {
        try {
            val database = safeDb() // Use resilient connection
            database.beginTransaction()
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

                // 2. Find any mediaPath that is assigned to more than 1 message
                val dupCursor = database.rawQuery("""
                    SELECT mediaPath, COUNT(*) as cnt 
                    FROM messages 
                    WHERE mediaPath IS NOT NULL AND mediaPath != '' 
                    GROUP BY mediaPath 
                    HAVING cnt > 1
                """.trimIndent(), null)

                val duplicatePaths = mutableListOf<String>()
                while (dupCursor.moveToNext()) {
                    val p = dupCursor.getString(0)
                    if (!p.isNullOrEmpty()) duplicatePaths.add(p)
                }
                dupCursor.close()

                for (path in duplicatePaths) {
                    val msgCursor = database.rawQuery("""
                        SELECT id, message, timestamp 
                        FROM messages 
                        WHERE mediaPath = ? 
                        ORDER BY timestamp ASC
                    """.trimIndent(), arrayOf(path))

                    val rows = mutableListOf<Triple<Long, String, Long>>()
                    while (msgCursor.moveToNext()) {
                        rows.add(Triple(msgCursor.getLong(0), msgCursor.getString(1) ?: "", msgCursor.getLong(2)))
                    }
                    msgCursor.close()

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
            val c1 = database.rawQuery("SELECT id FROM messages WHERE mediaPath = ? LIMIT 1", arrayOf(mediaPath))
            val inMessages = c1.moveToFirst()
            c1.close()
            if (inMessages) return true

            val c2 = database.rawQuery("SELECT id FROM media_attachments WHERE file_path = ? AND matched = 1 AND notification_id IS NOT NULL LIMIT 1", arrayOf(mediaPath))
            val inAttachments = c2.moveToFirst()
            c2.close()
            return inAttachments
        } catch (e: Exception) {
            return false
        }
    }

    /**
     * Batch insert multiple messages in a single transaction.
     * Returns the count of messages actually inserted.
     */
    fun insertMessagesBatch(messages: List<Map<String, Any?>>): Int {
        if (messages.isEmpty()) return 0

        var inserted = 0
        try {
            val database = safeDb()
            database.beginTransaction()
            try {
                for (msg in messages) {
                    val result = insertMessage(
                        sender = msg["sender"] as? String ?: continue,
                        message = msg["message"] as? String ?: continue,
                        app = msg["app"] as? String ?: continue,
                        timestampMs = msg["timestampMs"] as? Long ?: continue,
                        senderName = msg["senderName"] as? String ?: "",
                        isGroupChat = msg["isGroupChat"] as? Boolean ?: false,
                        avatarPath = msg["avatarPath"] as? String,
                        mediaPath = msg["mediaPath"] as? String
                    )
                    if (result > 0) inserted++
                }
                database.setTransactionSuccessful()
            } finally {
                database.endTransaction()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Batch insert error: ${e.message}")
        }

        if (inserted > 0) {
            Log.i(TAG, "✓ Batch inserted $inserted/${messages.size} messages")
        }
        return inserted
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
            val start = timestampMs - windowMs
            val end = timestampMs + windowMs
            val values = ContentValues().apply {
                put("mediaPath", mediaPath)
            }
            val rows = safeDb().update(
                "messages",
                values,
                "sender = ? AND app = ? AND message = ? AND timestamp BETWEEN ? AND ? AND (mediaPath IS NULL OR mediaPath = '')",
                arrayOf(sender, app, message, start.toString(), end.toString())
            )
            if (rows > 0) {
                Log.d(TAG, "Updated mediaPath for existing message ($rows rows): $mediaPath")
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
                    val checkCursor = database.rawQuery("SELECT id FROM messages WHERE mediaPath = ? LIMIT 1", arrayOf(fPath))
                    val alreadyUsed = checkCursor.moveToFirst()
                    checkCursor.close()
                    if (alreadyUsed) {
                        // Mark as matched so it won't be checked again
                        val markVals = ContentValues().apply { put("matched", 1) }
                        database.update("media_attachments", markVals, "id = ?", arrayOf(attachId.toString()))
                        continue
                    }

                    // ── STRICT SENDER MATCHING ──────────────────────────────
                    val senderMatches = attachSender.isNotEmpty() && !attachSender.contains('.') && (
                        attachSender.equals(sender, ignoreCase = true) ||
                        (senderName.isNotEmpty() && attachSender.equals(senderName, ignoreCase = true)) ||
                        attachSender.trim().equals(sender.trim(), ignoreCase = true)
                    )

                    // If attachSender was unassigned (e.g. captured by ContentObserver from directory before notification arrived):
                    // allow linking ONLY if captured within 45 seconds of this incoming message.
                    val isRecentUnassigned = (attachSender.isEmpty() || attachSender.endsWith(".jpg") || attachSender.endsWith(".mp4") || attachSender.endsWith(".opus")) 
                        && Math.abs(capAt - timestampMs) <= 45_000L

                    if (!senderMatches && !isRecentUnassigned) {
                        continue
                    }

                    val cleanBase = file.nameWithoutExtension.lowercase()
                    val isMatch = when (mType) {
                        "image" -> lowerMsg.contains("photo") || lowerMsg.contains("📷") || lowerMsg.contains("🖼") || lowerMsg.contains("image") || lowerMsg.contains("sticker") || lowerMsg.contains("gif") || lowerMsg.contains("👾") || lowerMsg.contains("💟") || lowerMsg.isEmpty()
                        "video" -> lowerMsg.contains("video") || lowerMsg.contains("🎥") || lowerMsg.contains("📹") || lowerMsg.contains("🎞") || lowerMsg.contains("gif") || lowerMsg.isEmpty()
                        "audio" -> lowerMsg.contains("voice") || lowerMsg.contains("audio") || lowerMsg.contains("🎙") || lowerMsg.contains("🎤") || lowerMsg.contains("🎵") || lowerMsg.isEmpty()
                        "document" -> lowerMsg.contains("document") || lowerMsg.contains("📄") || lowerMsg.contains("📎") || lowerMsg.contains("file") || lowerMsg.contains(".pdf") || lowerMsg.contains(".doc") || lowerMsg.contains(".csv") || lowerMsg.contains(".xls") || lowerMsg.contains(".txt") || lowerMsg.contains(".ppt") || lowerMsg.contains(".zip") || (cleanBase.length >= 3 && lowerMsg.contains(cleanBase)) || lowerMsg.isEmpty()
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
                database.beginTransaction()
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

            val now = System.currentTimeMillis()
            val effectiveTime = if (fileTimestamp > 1_000_000_000_000L) fileTimestamp else now
            val windowStart = minOf(effectiveTime, now) - 24 * 60 * 60 * 1000L
            val windowEnd = maxOf(effectiveTime, now) + 60_000L // 1 min buffer

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
                if (msgText.contains("call") && (msgText.contains("missed") || msgText.contains("incoming") || 
                    msgText.contains("ongoing") || msgText.contains("ringing") || msgText.contains("ended"))) return false
                if (msgText == "voice call" || msgText == "video call" || msgText == "group call") return false
                
                val matchesBase = cleanBase.length >= 3 && (
                    msgText.contains(cleanBase) ||
                    msgText.contains(cleanBaseNorm) ||
                    msgText.contains(fileName.lowercase())
                )
                return when (mediaType) {
                    "image" -> msgText.contains("photo") || msgText.contains("📷") || msgText.contains("🖼") || msgText.contains("image") || msgText.contains("sticker") || msgText.contains("gif") || msgText.contains("👾") || msgText.contains("💟") || (fileName.startsWith("STK-") && msgText.contains("sticker")) || matchesBase
                    "video" -> msgText.contains("video") || msgText.contains("🎥") || msgText.contains("📹") || msgText.contains("🎞") || msgText.contains("gif") || matchesBase
                    "audio" -> msgText.contains("voice") || msgText.contains("audio") || msgText.contains("🎙") || msgText.contains("🎤") || msgText.contains("🎵") || matchesBase
                    "document" -> msgText.contains("document") || msgText.contains("📄") || msgText.contains("📎") || msgText.contains("file") || msgText.contains(".pdf") || msgText.contains(".doc") || msgText.contains(".csv") || msgText.contains(".xls") || msgText.contains(".txt") || msgText.contains(".ppt") || msgText.contains(".zip") || matchesBase
                    else -> false
                }
            }

            var matchedMessageId: Long? = null
            var matchedSenderName: String = ""

            // Pass 1: If targetSender is known, prioritize matching unlinked messages from that specific sender/chat
            if (!targetSender.isNullOrBlank()) {
                val cleanTarget = targetSender.trim()
                val senderCursor = safeDb().rawQuery(
                    """
                    SELECT id, message, timestamp, sender, senderName 
                    FROM messages 
                    WHERE (app LIKE '%whatsapp%') 
                      AND (sender = ? COLLATE NOCASE OR senderName = ? COLLATE NOCASE OR LOWER(TRIM(sender)) = LOWER(?) OR LOWER(TRIM(senderName)) = LOWER(?))
                      AND (mediaPath IS NULL OR mediaPath = '') 
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

            // Pass 2: If no sender-specific match found in Pass 1:
            // - If targetSender is blank, check global unlinked messages within 24h.
            // - If targetSender was specified but Pass 1 found nothing, check global pool
            //   ONLY within a tight ±45-second window around this file's capture time.
            //   This allows matching if there was a minor sender title variance (e.g. contact name vs group name vs phone number)
            //   while strictly preventing cross-chat misattribution of older messages.
            if (matchedMessageId == null) {
                val p2WindowStart = if (!targetSender.isNullOrBlank()) maxOf(windowStart, effectiveTime - 45_000L) else windowStart
                val p2WindowEnd = if (!targetSender.isNullOrBlank()) minOf(windowEnd, effectiveTime + 45_000L) else windowEnd
                val globalCursor = safeDb().rawQuery(
                    """
                    SELECT id, message, timestamp, sender, senderName 
                    FROM messages 
                    WHERE (app LIKE '%whatsapp%') 
                      AND (mediaPath IS NULL OR mediaPath = '') 
                      AND timestamp BETWEEN $p2WindowStart AND $p2WindowEnd
                      AND (message NOT LIKE 'Reacted %' AND message NOT LIKE 'Reacted to %')
                    ORDER BY ABS(timestamp - $effectiveTime) ASC
                    LIMIT 20
                    """.trimIndent(),
                    null
                )

                globalCursor.use {
                    var bestGenericId: Long? = null
                    var bestGenericSender: String = ""

                    while (it.moveToNext()) {
                        val msgId = it.getLong(0)
                        val msgText = it.getString(1)?.lowercase() ?: ""
                        val sender = it.getString(3) ?: ""
                        val senderName = it.getString(4) ?: sender

                        // Skip call notifications that somehow made it into the DB
                        if (msgText.contains("call") && (msgText.contains("missed") || msgText.contains("incoming") || 
                            msgText.contains("ongoing") || msgText.contains("ringing"))) continue

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

            // NOTE: Arbitrary 10-minute fallback to plain text messages has been completely removed.
            // A media file is NEVER attached to plain text messages like "Tu bata", "Sett", or "Ok".

            if (matchedMessageId != null) {
                val database = safeDb()
                database.beginTransaction()
                try {
                    // Re-verify uniqueness inside transaction
                    val checkCursor = database.rawQuery("SELECT id FROM messages WHERE mediaPath = ? LIMIT 1", arrayOf(mediaPath))
                    val alreadyInUse = checkCursor.moveToFirst()
                    checkCursor.close()
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
                // If not matched immediately, record in media_attachments with matched = 0
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
                            put("sender_name", targetSender ?: fileName)
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
}

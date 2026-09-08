package com.silentsave.silentsave

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.PowerManager
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.util.Log
import androidx.documentfile.provider.DocumentFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile

/**
 * MediaWatcherService — captures WhatsApp media files (images, videos, voice notes)
 * that arrive while SilentSave is running, copies them to app-private storage, and
 * enqueues metadata for Flutter to read on its next poll cycle.
 *
 * ARCHITECTURE — why no direct SQLite access from Kotlin:
 *   sqflite holds a WAL connection while Flutter is alive. Opening a second raw
 *   connection from Kotlin risks "database is locked" errors and silent data loss.
 *   Instead we follow the same pattern as pending_notifications.json:
 *     1. Kotlin writes events to  media_queue.json  (atomic lock/rename)
 *     2. Flutter reads + clears the queue on resume / 10s poll
 *     3. Flutter owns all SQLite writes to media_attachments table
 *
 * LIFECYCLE:
 *   Non-foreground — relies on KeepAliveService process. Returns START_STICKY.
 *   No foregroundServiceType to avoid Android 14+ dataSync 6h budget.
 */
class MediaWatcherService : Service() {

    companion object {
        private const val TAG = "MediaWatcher"
        private const val PREFS_NAME = "media_watcher_prefs"
        private const val PREF_SAF_URI = "saf_tree_uri"
        private const val PREF_LAST_SCAN_TS_PREFIX = "last_scan_ts_"
        const val MEDIA_QUEUE_FILE = "media_queue.json"
        private const val MAX_QUEUE_ENTRIES = 500
        private const val WHATSAPP_PACKAGE = "com.whatsapp"
        private const val WHATSAPP_BUSINESS_PACKAGE = "com.whatsapp.w4b"

        @Volatile
        private var instance: MediaWatcherService? = null
        private var scanWakeLock: PowerManager.WakeLock? = null
        @Volatile
        private var pendingBurstScan: Triple<Uri, String?, String?>? = null

        /**
         * Triggers an immediate zero-touch scan with burst retries.
         * Acquires a 45-second WakeLock so the CPU remains active while scanning
         * and copying media even if the screen is off or the app is backgrounded.
         * Automatically released early as soon as the media matches.
         */
        fun triggerImmediateScan(
            context: Context, 
            hintSubdir: String? = null, 
            reason: String = "unknown",
            targetSender: String? = null
        ) {
            Log.i(TAG, "triggerImmediateScan: hint=$hintSubdir reason=$reason targetSender=$targetSender")
            val treeUri = getPersistedUri(context) ?: run {
                Log.w(TAG, "triggerImmediateScan: No SAF URI persisted")
                return
            }

            try {
                if (scanWakeLock == null) {
                    val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
                    scanWakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "SilentSave::MediaScanWakeLock").apply {
                        setReferenceCounted(false)
                    }
                }
                scanWakeLock?.acquire(45_000L)
            } catch (e: Exception) {
                Log.w(TAG, "WakeLock acquire error: ${e.message}")
            }

            val currentInstance = instance
            if (currentInstance != null) {
                currentInstance.scheduleBurstScans(treeUri, hintSubdir, targetSender)
            } else {
                pendingBurstScan = Triple(treeUri, hintSubdir, targetSender)
                start(context)
            }
        }

        private val WA_MEDIA_SUBDIRS = setOf(
            "WhatsApp Images",
            "WhatsApp Video",
            "WhatsApp Voice Notes",
            "WhatsApp Audio",
            "WhatsApp Animated Gifs",
            "WhatsApp Documents",
            "WhatsApp Stickers",
            "WhatsApp Business Images",
            "WhatsApp Business Video",
            "WhatsApp Business Voice Notes",
            "WhatsApp Business Audio",
            "WhatsApp Business Animated Gifs",
            "WhatsApp Business Documents",
            "WhatsApp Business Stickers"
        )

        private val MIME_TO_TYPE = mapOf(
            "image/" to "image",
            "video/" to "video",
            "audio/" to "audio"
        )

        fun start(context: Context) {
            context.startService(Intent(context, MediaWatcherService::class.java))
            Log.i(TAG, "start requested")
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, MediaWatcherService::class.java))
        }

        fun onSafUriGranted(context: Context, treeUri: Uri) {
            try {
                context.contentResolver.takePersistableUriPermission(
                    treeUri, Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
                context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                    .edit().putString(PREF_SAF_URI, treeUri.toString()).apply()
                Log.i(TAG, "SAF URI persisted: $treeUri")
                start(context)
            } catch (e: SecurityException) {
                Log.e(TAG, "SAF persist failed (OEM restriction?): ${e.message}")
            } catch (e: Exception) {
                Log.e(TAG, "SAF persist error: ${e.message}")
            }
        }

        fun getPersistedUri(context: Context): Uri? {
            return try {
                val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                val uriStr = prefs.getString(PREF_SAF_URI, null) ?: return null
                val uri = Uri.parse(uriStr)
                val stillGranted = context.contentResolver.persistedUriPermissions
                    .any { it.uri == uri && it.isReadPermission }
                if (!stillGranted) {
                    Log.w(TAG, "SAF URI revoked — clearing")
                    prefs.edit().remove(PREF_SAF_URI).apply()
                    null
                } else uri
            } catch (e: Exception) {
                Log.e(TAG, "getPersistedUri error: ${e.message}"); null
            }
        }

        fun hasSafPermission(context: Context): Boolean = getPersistedUri(context) != null

        fun getMediaAttachmentsDir(context: Context): File =
            File(context.filesDir, "media_attachments").also { if (!it.exists()) it.mkdirs() }

        fun getMediaQueueFile(context: Context): File =
            File(context.filesDir, MEDIA_QUEUE_FILE)
    }

    private val ioThread = HandlerThread("MediaWatcherIO").also { it.start() }
    private val ioHandler = Handler(ioThread.looper)
    private val contentObservers = mutableListOf<Pair<Uri, ContentObserver>>()
    private val prefs by lazy { getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE) }
    private var nativeDb: NativeDatabaseHelper? = null
    private var periodicScanRunnable: Runnable? = null
    private var cachedTreeUri: Uri? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        Log.i(TAG, "CREATED")
        try {
            nativeDb = NativeDatabaseHelper.getInstance(applicationContext)
            Log.i(TAG, "NativeDatabaseHelper initialized in MediaWatcher")
        } catch (e: Exception) {
            Log.e(TAG, "NativeDatabaseHelper init failed: ${e.message}")
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.i(TAG, "onStartCommand")
        if (!isWhatsAppInstalled()) {
            Log.i(TAG, "WhatsApp not installed — standing down")
            stopSelf(); return START_NOT_STICKY
        }
        val treeUri = getPersistedUri(applicationContext)
        if (treeUri == null) {
            Log.i(TAG, "No SAF URI — waiting for user grant"); return START_STICKY
        }
        cachedTreeUri = treeUri
        registerObservers(treeUri)
        ioHandler.post { scanAllSubdirs(treeUri) }
        startPeriodicScan()

        pendingBurstScan?.let { (uri, hint, sender) ->
            pendingBurstScan = null
            scheduleBurstScans(uri, hint, sender)
        }

        return START_STICKY
    }

    override fun onDestroy() {
        if (instance == this) instance = null
        Log.w(TAG, "onDestroy — unregistering observers")
        burstScanRunnables.forEach { ioHandler.removeCallbacks(it) }
        burstScanRunnables.clear()
        stopPeriodicScan()
        unregisterObservers()
        ioThread.quitSafely()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ── Burst scans ────────────────────────────────────────────────────────

    private val burstScanRunnables = mutableListOf<Runnable>()
    private val subdirUriMap = java.util.concurrent.ConcurrentHashMap<String, Uri>()

    fun cancelBurstScans() {
        burstScanRunnables.forEach { ioHandler.removeCallbacks(it) }
        burstScanRunnables.clear()
        try {
            if (scanWakeLock?.isHeld == true) {
                scanWakeLock?.release()
                Log.d(TAG, "Burst scans cancelled & WakeLock released early")
            }
        } catch (_: Exception) {}
    }

    fun scheduleBurstScans(treeUri: Uri, hintSubdir: String? = null, targetSender: String? = null) {
        burstScanRunnables.forEach { ioHandler.removeCallbacks(it) }
        burstScanRunnables.clear()

        // 7-step exponential backoff (0s to 40s): covers real-world download latency
        // while cutting scan frequency by nearly 50% compared to tight polling.
        val delays = listOf(0L, 1200L, 3000L, 7000L, 14000L, 25000L, 40000L)
        for (delay in delays) {
            val runnable = Runnable {
                Log.d(TAG, "Executing burst scan (delay=${delay}ms, hint=$hintSubdir, sender=$targetSender)")
                if (hintSubdir != null) {
                    scanSubdirByName(treeUri, hintSubdir, targetSender)
                }
                scanAllSubdirs(treeUri, targetSender)
            }
            burstScanRunnables.add(runnable)
            if (delay == 0L) {
                ioHandler.post(runnable)
            } else {
                ioHandler.postDelayed(runnable, delay)
            }
        }
    }

    private fun scanSubdirByName(treeUri: Uri, subdirName: String, targetSender: String? = null) {
        val uri = subdirUriMap[subdirName]
        if (uri != null) {
            scanSubdir(treeUri, uri, subdirName, targetSender)
        }
    }

    // ── ContentObserver registration ──────────────────────────────────────

    private fun registerObservers(treeUri: Uri) {
        unregisterObservers()
        try {
            val rootDoc = DocumentFile.fromTreeUri(applicationContext, treeUri)
            if (rootDoc == null || !rootDoc.exists()) {
                Log.w(TAG, "SAF root invalid: $treeUri"); return
            }
            var registered = 0
            try {
                fun registerMatching(parent: DocumentFile) {
                    parent.listFiles().forEach { subdir ->
                        val name = subdir.name ?: return@forEach
                        if (name !in WA_MEDIA_SUBDIRS) return@forEach
                        subdirUriMap[name] = subdir.uri
                        val obs = makeObserver(treeUri, subdir.uri, name)
                        contentResolver.registerContentObserver(subdir.uri, true, obs)
                        contentObservers.add(Pair(subdir.uri, obs))
                        registered++
                        Log.i(TAG, "Observer registered: $name")
                    }
                }
                registerMatching(rootDoc)
                if (registered == 0) {
                    // Check if user selected WhatsApp parent folder containing "Media"
                    rootDoc.findFile("Media")?.takeIf { it.isDirectory }?.let { mediaDoc ->
                        registerMatching(mediaDoc)
                    }
                }
                if (registered == 0 && (rootDoc.name ?: "") in WA_MEDIA_SUBDIRS) {
                    val obs = makeObserver(treeUri, rootDoc.uri, rootDoc.name ?: "root")
                    contentResolver.registerContentObserver(rootDoc.uri, true, obs)
                    contentObservers.add(Pair(rootDoc.uri, obs))
                    registered++
                }
            } catch (e: Exception) {
                Log.e(TAG, "listFiles error: ${e.message}")
            }
            if (registered == 0) {
                Log.w(TAG, "No WA subdirs found — root observer fallback")
                val obs = makeObserver(treeUri, treeUri, "root")
                contentResolver.registerContentObserver(treeUri, true, obs)
                contentObservers.add(Pair(treeUri, obs))
            }
            // Also observe system MediaStore for instant change notifications
            registerMediaStoreObservers()
        } catch (e: SecurityException) {
            Log.e(TAG, "SecurityException — permission revoked: ${e.message}")
            getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit().remove(PREF_SAF_URI).apply()
        } catch (e: Exception) {
            Log.e(TAG, "registerObservers error: ${e.message}")
        }
    }

    private fun registerMediaStoreObservers() {
        try {
            val mediaStoreUris = listOf(
                MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                MediaStore.Files.getContentUri("external")
            )
            val msObserver = object : ContentObserver(ioHandler) {
                override fun onChange(selfChange: Boolean, uri: Uri?) {
                    Log.d(TAG, "MediaStore onChange fired: uri=$uri")
                    val treeUri = cachedTreeUri ?: getPersistedUri(applicationContext) ?: return
                    scheduleBurstScans(treeUri, null)
                }
            }
            for (msUri in mediaStoreUris) {
                try {
                    contentResolver.registerContentObserver(msUri, true, msObserver)
                    contentObservers.add(Pair(msUri, msObserver))
                    Log.i(TAG, "MediaStore observer registered: $msUri")
                } catch (e: Exception) {
                    Log.w(TAG, "MediaStore observer failed for $msUri: ${e.message}")
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "registerMediaStoreObservers error: ${e.message}")
        }
    }

    private val scanRunnables = mutableMapOf<String, Runnable>()

    private fun makeObserver(treeUri: Uri, subdirUri: Uri, name: String) =
        object : ContentObserver(ioHandler) {
            override fun onChange(selfChange: Boolean, uri: Uri?) {
                Log.d(TAG, "onChange fired: '$name' (selfChange=$selfChange)")
                val key = subdirUri.toString()
                
                // 1. INSTANT CAPTURE: Run immediately without debounce to beat "Delete for Everyone"
                ioHandler.post { scanSubdir(treeUri, subdirUri, name) }
                
                // 2. DELAYED CAPTURE: Run again 1500ms later to catch large videos that take time to finish downloading
                scanRunnables[key]?.let { ioHandler.removeCallbacks(it) }
                val runnable = Runnable { scanSubdir(treeUri, subdirUri, name) }
                scanRunnables[key] = runnable
                ioHandler.postDelayed(runnable, 1500)
            }
        }

    private fun unregisterObservers() {
        contentObservers.forEach { (uri, obs) ->
            try { contentResolver.unregisterContentObserver(obs) } catch (_: Exception) {}
        }
        contentObservers.clear()
    }

    // ── Periodic fallback scan (every 60 s) ───────────────────────────────

    private fun startPeriodicScan() {
        stopPeriodicScan()
        periodicScanRunnable = object : Runnable {
            override fun run() {
                val uri = cachedTreeUri ?: getPersistedUri(applicationContext)
                if (uri != null) {
                    cachedTreeUri = uri
                    ioHandler.post { scanAllSubdirs(uri) }
                }
                ioHandler.postDelayed(this, 60_000L)
            }
        }.also { ioHandler.postDelayed(it, 60_000L) }
    }

    private fun stopPeriodicScan() {
        periodicScanRunnable?.let { ioHandler.removeCallbacks(it) }
        periodicScanRunnable = null
    }

    // ── File scanning ─────────────────────────────────────────────────────

    private fun scanAllSubdirs(treeUri: Uri, targetSender: String? = null) {
        try {
            val root = DocumentFile.fromTreeUri(applicationContext, treeUri) ?: return
            if (!root.exists()) return
            var scanned = 0
            root.listFiles().forEach { sub ->
                val n = sub.name ?: return@forEach
                if (n in WA_MEDIA_SUBDIRS) {
                    subdirUriMap[n] = sub.uri
                    scanSubdir(treeUri, sub.uri, n, targetSender)
                    scanned++
                }
            }
            // Fallback: If no subdirs matched directly, check for a "Media" directory
            if (scanned == 0) {
                root.findFile("Media")?.takeIf { it.isDirectory }?.listFiles()?.forEach { sub ->
                    val n = sub.name ?: return@forEach
                    if (n in WA_MEDIA_SUBDIRS) {
                        subdirUriMap[n] = sub.uri
                        scanSubdir(treeUri, sub.uri, n, targetSender)
                        scanned++
                    }
                }
            }
            // Fallback: If root itself is a WhatsApp media directory
            if (scanned == 0 && (root.name ?: "") in WA_MEDIA_SUBDIRS) {
                val rName = root.name ?: "root"
                subdirUriMap[rName] = root.uri
                scanSubdir(treeUri, root.uri, rName, targetSender)
            }
        } catch (e: Exception) { Log.e(TAG, "scanAllSubdirs: ${e.message}") }
    }

    private fun scanSubdir(treeUri: Uri, subdirUri: Uri, subdirName: String, targetSender: String? = null) {
        try {
            val lastScanKey = "$PREF_LAST_SCAN_TS_PREFIX$subdirName"
            val scanStart  = System.currentTimeMillis()
            val cutoffTime = scanStart - 24 * 60 * 60 * 1000L // 24-hour window for active captures

            val initialDocId: String = try {
                DocumentsContract.getDocumentId(subdirUri)
            } catch (_: Exception) {
                try { DocumentsContract.getTreeDocumentId(subdirUri) }
                catch (e: Exception) { Log.e(TAG, "No docId for $subdirName: ${e.message}"); return }
            }

            var found = 0
            val queue = mutableListOf(initialDocId)

            while (queue.isNotEmpty()) {
                val currentDocId = queue.removeAt(0)
                val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, currentDocId)
                
                val cursor = try {
                    contentResolver.query(childrenUri, arrayOf(
                        DocumentsContract.Document.COLUMN_DOCUMENT_ID,   // 0
                        DocumentsContract.Document.COLUMN_DISPLAY_NAME,  // 1
                        DocumentsContract.Document.COLUMN_MIME_TYPE,     // 2
                        DocumentsContract.Document.COLUMN_SIZE,          // 3
                        DocumentsContract.Document.COLUMN_LAST_MODIFIED  // 4
                    ), null, null, null)
                } catch (e: Exception) { Log.e(TAG, "query($subdirName): ${e.message}"); continue }

                val pendingDirs = mutableListOf<Pair<String, String>>() // (docId, name)

                cursor?.use { c ->
                    while (c.moveToNext()) {
                        try {
                            val docId    = c.getString(0) ?: continue
                            val name     = c.getString(1) ?: continue
                            val mime     = c.getString(2) ?: "application/octet-stream"
                            val size     = c.getLong(3)
                            val rawModified = c.getLong(4)

                            if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                                // Skip Sent, .Shared, .Links, .Statuses, and cache folders
                                if (name != "Sent" && name != ".Shared" && !name.startsWith(".")) {
                                    pendingDirs.add(Pair(docId, name))
                                }
                                continue
                            }

                            if (name.startsWith(".") || name == ".nomedia" || name.endsWith(".thumb")) continue

                            // Skip empty or incomplete downloads
                            if (size <= 0L) {
                                Log.d(TAG, "Skipping empty/incomplete file: $name (size=$size)")
                                continue
                            }

                            // Prune historical files: ONLY skip if rawModified is a valid millisecond timestamp (> year 2001)
                            // AND strictly older than cutoffTime. If 0, -1, or unpopulated by OEM, keep it!
                            if (rawModified > 1_000_000_000_000L && rawModified < cutoffTime) {
                                continue
                            }

                            // Skip files that have already been copied and successfully linked
                            val safeName = name.replace(Regex("[^a-zA-Z0-9._-]"), "_")
                            val destDir  = getMediaAttachmentsDir(applicationContext)
                            val destFile = File(destDir, safeName)
                            if (destFile.exists() && destFile.length() == size && (linkedPaths.contains(destFile.absolutePath) || nativeDb?.isMediaAlreadyLinked(destFile.absolutePath) == true)) {
                                continue
                            }

                            val fileUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
                            val type    = mimeToMediaType(mime, name)
                            found++

                            val path = copyToPrivateStorage(fileUri, name, size)
                            if (path != null) {
                                // Use actual file modified time if valid, else current time
                                val captureTime = if (rawModified > 1_000_000_000_000L) rawModified else System.currentTimeMillis()
                                processMediaEvent(fileUri.toString(), type, path, captureTime, size, name, 0, targetSender)
                            }
                        } catch (e: Exception) { Log.e(TAG, "file processing: ${e.message}") }
                    }
                }

                // Prioritize subdirectories intelligently
                if (pendingDirs.isNotEmpty()) {
                    if (subdirName.contains("Voice Notes")) {
                        // WhatsApp Voice Notes has weekly folders (e.g. 202637, 202636).
                        // Separate numeric folders from non-numeric so stray directories don't disrupt chronological sort.
                        val (numericFolders, otherFolders) = pendingDirs.partition {
                            it.second.matches(Regex("^\\d{4,8}$"))
                        }
                        val sortedWeekly = numericFolders.sortedByDescending { it.second }.take(3)
                        for (dir in sortedWeekly) queue.add(dir.first)
                        // If any non-numeric folders exist (e.g. backup or custom), inspect up to 2
                        for (dir in otherFolders.take(2)) queue.add(dir.first)
                    } else if (subdirName.contains("Video")) {
                        // In WhatsApp Video, prioritize "Private" folder first because incoming videos arrive there
                        val (privateDirs, otherDirs) = pendingDirs.partition { it.second.equals("Private", ignoreCase = true) }
                        for (dir in privateDirs) queue.add(dir.first)
                        for (dir in otherDirs) queue.add(dir.first)
                    } else {
                        for (dir in pendingDirs) queue.add(dir.first)
                    }
                }
            }
            if (found > 0) Log.i(TAG, "scan $subdirName: $found file(s) checked")
            prefs.edit().putLong(lastScanKey, scanStart).apply()
        } catch (e: Exception) { Log.e(TAG, "scanSubdir($subdirName): ${e.message}") }
    }

    // ── File copy ─────────────────────────────────────────────────────────

    private fun copyToPrivateStorage(sourceUri: Uri, displayName: String, sizeBytes: Long): String? {
        return try {
            val destDir  = getMediaAttachmentsDir(applicationContext)
            val safeName = displayName.replace(Regex("[^a-zA-Z0-9._-]"), "_")
            val destFile = File(destDir, safeName)
            
            // Fix 1: If already copied with matching size, return the EXISTING path
            // instead of null. Returning null caused the caller to skip processMediaEvent,
            // which meant re-scans could never attempt DB matching for already-copied files.
            if (destFile.exists() && destFile.length() == sizeBytes) {
                Log.d(TAG, "Already copied (same size): ${destFile.name}")
                return destFile.absolutePath
            }

            contentResolver.openInputStream(sourceUri)?.use { input ->
                FileOutputStream(destFile).use { out ->
                    val buf = ByteArray(8192); var n: Int
                    while (input.read(buf).also { n = it } != -1) out.write(buf, 0, n)
                    out.flush()
                }
            }
            Log.i(TAG, "Copied: ${destFile.name} (${destFile.length()}B)")
            destFile.absolutePath
        } catch (e: SecurityException) {
            Log.e(TAG, "SecurityException copying $displayName: ${e.message}"); null
        } catch (e: Exception) {
            Log.e(TAG, "copy error ($displayName): ${e.message}"); null
        }
    }

    // ── Queue writer ──────────────────────────────────────────────────────

    // Tracks files that have been successfully linked or are currently being retried,
    // so periodic scans don't redundantly schedule retries.
    private val linkedPaths = java.util.Collections.synchronizedSet(mutableSetOf<String>())
    private val pendingRetries = java.util.Collections.synchronizedSet(mutableSetOf<String>())

    private fun processMediaEvent(
        originalUri: String, mediaType: String, privatePath: String,
        fileTimestampMs: Long, sizeBytes: Long, displayName: String,
        retryCount: Int = 0, targetSender: String? = null
    ) {
        // Skip if this file was already successfully linked
        if (linkedPaths.contains(privatePath)) return

        // Also check if already linked in SQLite database!
        if (nativeDb?.isMediaAlreadyLinked(privatePath) == true) {
            linkedPaths.add(privatePath)
            return
        }

        // On initial call (not a retry), skip if we're already retrying this file
        if (retryCount == 0 && pendingRetries.contains(privatePath)) return

        // Attempt native zero-touch matching immediately
        val matched = nativeDb?.matchAndLinkMedia(
            fileName = displayName,
            mediaPath = privatePath,
            mediaType = mediaType,
            fileTimestamp = fileTimestampMs,
            originalUri = originalUri,
            fileSizeBytes = sizeBytes,
            targetSender = targetSender
        ) == true

        if (matched) {
            Log.i(TAG, "Zero-touch matched media: $displayName ($targetSender)")
            linkedPaths.add(privatePath)
            pendingRetries.remove(privatePath)
            cancelBurstScans() // Early exit on match: stops remaining burst scans & releases WakeLock
            // Cap linkedPaths to prevent memory leak
            if (linkedPaths.size > 500) {
                val iter = linkedPaths.iterator()
                if (iter.hasNext()) { iter.next(); iter.remove() }
            }
            return
        }

        // Handle Case B race condition: SAF file copied before notification arrives
        when (retryCount) {
            0 -> {
                Log.d(TAG, "Match failed for $displayName. Retrying in 3s...")
                pendingRetries.add(privatePath)
                ioHandler.postDelayed({
                    processMediaEvent(originalUri, mediaType, privatePath, fileTimestampMs, sizeBytes, displayName, 1, targetSender)
                }, 3000)
            }
            1 -> {
                Log.d(TAG, "Match failed (retry 1) for $displayName. Retrying in 7s...")
                ioHandler.postDelayed({
                    processMediaEvent(originalUri, mediaType, privatePath, fileTimestampMs, sizeBytes, displayName, 2, targetSender)
                }, 7000)
            }
            else -> {
                Log.w(TAG, "All retries failed for $displayName. Queueing to JSON fallback.")
                pendingRetries.remove(privatePath)
                enqueueToJSON(originalUri, mediaType, privatePath, fileTimestampMs, sizeBytes, displayName, targetSender)
            }
        }
    }

    private fun enqueueToJSON(
        originalUri: String, mediaType: String, privatePath: String?,
        fileTimestampMs: Long, sizeBytes: Long, displayName: String,
        targetSender: String? = null
    ) {
        try {
            val event = JSONObject().apply {
                put("originalUri", originalUri)
                put("mediaType", mediaType)
                if (privatePath != null) put("filePath", privatePath)
                put("fileTimestampMs", fileTimestampMs)
                put("sizeBytes", sizeBytes)
                put("displayName", displayName)
            }
            val file     = getMediaQueueFile(applicationContext)
            val lockFile = File(file.absolutePath + ".lock")
            val tmpFile  = File(file.absolutePath + ".tmp")
            lockFile.createNewFile()

            RandomAccessFile(lockFile, "rw").use { raf ->
                raf.channel.lock().use { _ ->
                    val arr = try {
                        val txt = if (file.exists()) file.readText().trim() else "[]"
                        if (txt.isEmpty()) JSONArray() else JSONArray(txt)
                    } catch (_: Exception) { JSONArray() }

                    while (arr.length() >= MAX_QUEUE_ENTRIES) arr.remove(0)
                    arr.put(event)

                    tmpFile.writeText(arr.toString())
                    if (!tmpFile.renameTo(file)) {
                        file.delete()
                        if (!tmpFile.renameTo(file)) { file.writeText(arr.toString()); tmpFile.delete() }
                    }
                    Log.i(TAG, "Enqueued to fallback: $displayName (q=${arr.length()})")
                }
            }
        } catch (e: Exception) { Log.e(TAG, "enqueue error: ${e.message}") }
    }

    // ── Utilities ─────────────────────────────────────────────────────────

    private fun isWhatsAppInstalled(): Boolean = try {
        applicationContext.packageManager.getPackageInfo(WHATSAPP_PACKAGE, 0); true
    } catch (_: PackageManager.NameNotFoundException) {
        try { applicationContext.packageManager.getPackageInfo(WHATSAPP_BUSINESS_PACKAGE, 0); true }
        catch (_: PackageManager.NameNotFoundException) { false }
    }

    private fun mimeToMediaType(mime: String, name: String): String {
        if (mime.startsWith("image/")) return "image"
        if (mime.startsWith("video/")) return "video"
        if (mime.startsWith("audio/")) return "audio"
        val ext = name.substringAfterLast('.', "").lowercase(java.util.Locale.US)
        if (ext in listOf("jpg", "jpeg", "png", "webp", "gif")) return "image"
        if (ext in listOf("mp4", "mkv", "avi", "mov", "3gp")) return "video"
        if (ext in listOf("mp3", "opus", "m4a", "wav", "aac", "ogg")) return "audio"
        if (ext in listOf("pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "zip", "rar", "apk")) return "document"
        if (mime.startsWith("application/") || mime.startsWith("text/")) return "document"
        return "unknown"
    }
}

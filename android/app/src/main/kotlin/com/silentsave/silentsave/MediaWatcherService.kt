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
import android.provider.DocumentsContract
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

        private val WA_MEDIA_SUBDIRS = setOf(
            "WhatsApp Images",
            "WhatsApp Video",
            "WhatsApp Voice Notes",
            "WhatsApp Business Images",
            "WhatsApp Business Video",
            "WhatsApp Business Voice Notes"
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

    override fun onCreate() { super.onCreate(); Log.i(TAG, "CREATED") }

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
        registerObservers(treeUri)
        ioHandler.post { scanAllSubdirs(treeUri) }
        return START_STICKY
    }

    override fun onDestroy() {
        Log.w(TAG, "onDestroy — unregistering observers")
        unregisterObservers()
        ioThread.quitSafely()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

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
                rootDoc.listFiles().forEach { subdir ->
                    val name = subdir.name ?: return@forEach
                    if (name !in WA_MEDIA_SUBDIRS) return@forEach
                    val obs = makeObserver(treeUri, subdir.uri, name)
                    contentResolver.registerContentObserver(subdir.uri, true, obs)
                    contentObservers.add(Pair(subdir.uri, obs))
                    registered++
                    Log.i(TAG, "Observer registered: $name")
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
        } catch (e: SecurityException) {
            Log.e(TAG, "SecurityException — permission revoked: ${e.message}")
            getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit().remove(PREF_SAF_URI).apply()
        } catch (e: Exception) {
            Log.e(TAG, "registerObservers error: ${e.message}")
        }
    }

    private val scanRunnables = mutableMapOf<String, Runnable>()

    private fun makeObserver(treeUri: Uri, subdirUri: Uri, name: String) =
        object : ContentObserver(ioHandler) {
            override fun onChange(selfChange: Boolean, uri: Uri?) {
                Log.d(TAG, "onChange fired: '$name' (selfChange=$selfChange)")
                val key = subdirUri.toString()
                scanRunnables[key]?.let { ioHandler.removeCallbacks(it) }
                val runnable = Runnable { scanSubdir(treeUri, subdirUri, name) }
                scanRunnables[key] = runnable
                // Debounce for 500ms to consolidate rapid chunk writes
                ioHandler.postDelayed(runnable, 500)
            }
        }

    private fun unregisterObservers() {
        scanRunnables.values.forEach { ioHandler.removeCallbacks(it) }
        scanRunnables.clear()
        contentObservers.forEach { (_, obs) ->
            try { contentResolver.unregisterContentObserver(obs) } catch (_: Exception) {}
        }
        contentObservers.clear()
    }

    // ── File scanning ─────────────────────────────────────────────────────

    private fun scanAllSubdirs(treeUri: Uri) {
        try {
            val root = DocumentFile.fromTreeUri(applicationContext, treeUri) ?: return
            if (!root.exists()) return
            root.listFiles().forEach { sub ->
                val n = sub.name ?: return@forEach
                if (n in WA_MEDIA_SUBDIRS) scanSubdir(treeUri, sub.uri, n)
            }
        } catch (e: Exception) { Log.e(TAG, "scanAllSubdirs: ${e.message}") }
    }

    private fun scanSubdir(treeUri: Uri, subdirUri: Uri, subdirName: String) {
        try {
            val lastScanKey = "$PREF_LAST_SCAN_TS_PREFIX$subdirName"
            // Look back 24 hours on the first run so we don't miss files that arrived just before SAF was granted
            val lastScanTs = prefs.getLong(lastScanKey, System.currentTimeMillis() - 86400_000L)
            val scanStart  = System.currentTimeMillis()

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

                cursor?.use { c ->
                    while (c.moveToNext()) {
                        try {
                            val docId    = c.getString(0) ?: continue
                            val name     = c.getString(1) ?: continue
                            val mime     = c.getString(2) ?: "application/octet-stream"
                            val size     = c.getLong(3)
                            val modified = c.getLong(4)

                            if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                                // Skip Sent and .Shared folders, but recurse into Private and Voice Note folders
                                if (name != "Sent" && name != ".Shared") {
                                    queue.add(docId)
                                }
                                continue
                            }

                            if (name.startsWith(".") || name == ".nomedia" || name.endsWith(".thumb")) continue
                            
                            // Look back 1 hour from lastScanTs to catch slow downloads & renames
                            if (modified <= lastScanTs - 3600_000L) continue

                            val fileUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
                            val type    = mimeToMediaType(mime, name)
                            found++

                            val path = copyToPrivateStorage(fileUri, name, size)
                            if (path != null) {
                                enqueueMediaEvent(fileUri.toString(), type, path, modified, size, name)
                            }
                        } catch (e: Exception) { Log.e(TAG, "file processing: ${e.message}") }
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
            val destFile = File(destDir, "${sizeBytes}_$safeName")
            
            // If we already copied this exact file with this exact size, skip it entirely!
            if (destFile.exists() && destFile.length() > 0) return null

            // Delete any older partial copies of this exact file to prevent storage bloat
            destDir.listFiles { _, n -> n.endsWith("_$safeName") }?.forEach { it.delete() }

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

    private fun enqueueMediaEvent(
        originalUri: String, mediaType: String, privatePath: String?,
        fileTimestampMs: Long, sizeBytes: Long, displayName: String
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
                    Log.i(TAG, "Enqueued: $displayName (q=${arr.length()})")
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
        return "unknown"
    }
}

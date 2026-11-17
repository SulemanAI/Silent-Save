package com.silentsave.silentsave.callrecorder

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.net.Uri
import android.os.Environment
import android.os.StatFs
import android.provider.MediaStore
import android.util.Log
import com.silentsave.silentsave.NativeDatabaseHelper
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Repository layer for the Call Recorder module.
 *
 * Responsibilities:
 *  1. Manage temporary staging files during active capture and persist session metadata
 *     so partial recordings can be finalized or recovered if the service is killed.
 *  2. Publish completed/recovered recordings into Android `MediaStore` under
 *     `Movies/CallRecordings` (video) or `Music/CallRecordings` (voice).
 *  3. Keep `silentsave.db` (`call_recordings` table via [NativeDatabaseHelper]) strictly
 *     synchronized with `MediaStore` across list, rename, delete, and external file changes.
 *  4. Monitor available device storage via [StatFs].
 */
class CallRecordingRepository(context: Context) {

    companion object {
        private const val TAG = "CallRecRepo"
        private const val SESSION_PREFS = "call_recorder_session"
        private const val KEY_STAGING_PATH = "active_staging_path"
        private const val KEY_MODE = "active_mode"
        private const val KEY_AUDIO_SOURCE = "active_audio_source"
        private const val KEY_STARTED_AT = "active_started_at_ms"

        const val VIDEO_RELATIVE_DIR = "Movies/CallRecordings"
        const val AUDIO_RELATIVE_DIR = "Music/CallRecordings"

        // Minimum 50 MB free to start a new recording; auto-finalize at 25 MB free
        const val MIN_START_STORAGE_BYTES = 50L * 1024L * 1024L
        const val CRITICAL_LOW_STORAGE_BYTES = 25L * 1024L * 1024L

        @Volatile
        private var INSTANCE: CallRecordingRepository? = null

        fun getInstance(context: Context): CallRecordingRepository {
            return INSTANCE ?: synchronized(this) {
                INSTANCE ?: CallRecordingRepository(context.applicationContext).also {
                    INSTANCE = it
                }
            }
        }
    }

    private val appContext: Context = context.applicationContext
    private val dbHelper: NativeDatabaseHelper = NativeDatabaseHelper.getInstance(appContext)

    /**
     * App-private staging directory where MediaRecorder writes while a call is in progress.
     */
    fun getStagingDir(): File {
        val base = appContext.getExternalFilesDir(null) ?: appContext.filesDir
        val dir = File(base, "CallRecordingsStaging")
        if (!dir.exists()) dir.mkdirs()
        return dir
    }

    /**
     * Available bytes on external/shared storage partition.
     */
    fun getAvailableStorageBytes(): Long {
        return try {
            val targetPath = (appContext.getExternalFilesDir(null)
                ?: Environment.getDataDirectory()).absolutePath
            val stat = StatFs(targetPath)
            stat.availableBytes
        } catch (e: Exception) {
            Log.w(TAG, "StatFs error: ${e.message}")
            Long.MAX_VALUE
        }
    }

    fun hasEnoughStorageToStart(): Boolean = getAvailableStorageBytes() >= MIN_START_STORAGE_BYTES

    fun isStorageCriticallyLow(): Boolean = getAvailableStorageBytes() < CRITICAL_LOW_STORAGE_BYTES

    /**
     * Generates a unique filename formatted like `WhatsApp_2026-11-03_14-30_video.mp4`
     * or `WhatsApp_2026-11-03_14-30_voice.m4a`, appending `_2`, `_3`, ... if another
     * recording was already created in the same minute.
     */
    fun createStagingFile(mode: RecordingMode, startedAtMs: Long = System.currentTimeMillis()): File {
        val stamp = SimpleDateFormat("yyyy-MM-dd_HH-mm", Locale.US).format(Date(startedAtMs))
        val baseStem = "WhatsApp_${stamp}_${mode.wireValue}"
        val ext = mode.fileExtension
        val stagingDir = getStagingDir()

        var candidateName = "$baseStem.$ext"
        var counter = 2
        while (File(stagingDir, candidateName).exists() || displayNameExistsInMediaStore(mode, candidateName)) {
            candidateName = "${baseStem}_$counter.$ext"
            counter++
        }
        return File(stagingDir, candidateName)
    }

    private fun displayNameExistsInMediaStore(mode: RecordingMode, displayName: String): Boolean {
        return try {
            val collection = getMediaStoreCollection(mode)
            val relativePrefix = if (mode == RecordingMode.VIDEO) VIDEO_RELATIVE_DIR else AUDIO_RELATIVE_DIR
            appContext.contentResolver.query(
                collection,
                arrayOf(MediaStore.MediaColumns._ID),
                "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND ${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?",
                arrayOf(displayName, "%$relativePrefix%"),
                null
            )?.use { it.moveToFirst() } ?: false
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Record active session info so interrupted files can be recovered after an OS/OEM kill.
     */
    fun markActiveSession(
        stagingFile: File,
        mode: RecordingMode,
        audioSource: AudioSourceOption,
        startedAtMs: Long
    ) {
        appContext.getSharedPreferences(SESSION_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_STAGING_PATH, stagingFile.absolutePath)
            .putString(KEY_MODE, mode.wireValue)
            .putString(KEY_AUDIO_SOURCE, audioSource.wireValue)
            .putLong(KEY_STARTED_AT, startedAtMs)
            .apply()
    }

    fun clearActiveSession() {
        appContext.getSharedPreferences(SESSION_PREFS, Context.MODE_PRIVATE)
            .edit()
            .clear()
            .apply()
    }

    /**
     * Publishes a finalized staging file into `MediaStore` (`Movies/CallRecordings` or
     * `Music/CallRecordings`), extracts accurate duration, deletes the staging file,
     * and stores metadata in `silentsave.db` (`call_recordings` table).
     */
    fun publishStagingFileToMediaStore(
        stagingFile: File,
        mode: RecordingMode,
        audioSource: AudioSourceOption,
        startedAtMs: Long,
        fallbackDurationMs: Long = 0L,
        isPartial: Boolean = false
    ): CallRecordingEntity? {
        if (!stagingFile.exists() || stagingFile.length() <= 0L) {
            Log.w(TAG, "Staging file missing or empty: ${stagingFile.absolutePath}")
            try { stagingFile.delete() } catch (_: Exception) {}
            clearActiveSession()
            return null
        }

        val extractedDuration = extractDurationMs(stagingFile).let {
            if (it > 0L) it else fallbackDurationMs.coerceAtLeast(0L)
        }
        val sizeBytes = stagingFile.length()
        val displayName = stagingFile.name
        val collection = getMediaStoreCollection(mode)
        val relativePath = if (mode == RecordingMode.VIDEO) {
            "${Environment.DIRECTORY_MOVIES}/CallRecordings"
        } else {
            "${Environment.DIRECTORY_MUSIC}/CallRecordings"
        }

        val resolver = appContext.contentResolver
        val insertValues = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mode.mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            put(MediaStore.MediaColumns.DATE_ADDED, startedAtMs / 1000L)
            put(MediaStore.MediaColumns.DATE_MODIFIED, System.currentTimeMillis() / 1000L)
            if (extractedDuration > 0L) {
                put(MediaStore.MediaColumns.DURATION, extractedDuration)
            }
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }

        var insertedUri: Uri? = null
        return try {
            insertedUri = resolver.insert(collection, insertValues)
                ?: throw IllegalStateException("MediaStore.insert returned null for $displayName")

            resolver.openOutputStream(insertedUri)?.use { outStream ->
                FileInputStream(stagingFile).use { inStream ->
                    inStream.copyTo(outStream, bufferSize = 64 * 1024)
                    outStream.flush()
                }
            } ?: throw IllegalStateException("Could not open MediaStore OutputStream for $insertedUri")

            val finalizeValues = ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
                if (extractedDuration > 0L) {
                    put(MediaStore.MediaColumns.DURATION, extractedDuration)
                }
            }
            resolver.update(insertedUri, finalizeValues, null, null)

            // Query MediaStore row back for canonical _ID, SIZE, and filesystem DATA path
            val mediaStoreId = ContentUris.parseId(insertedUri)
            var resolvedFilePath: String? = null
            var resolvedSize = sizeBytes
            var resolvedName = displayName

            resolver.query(
                insertedUri,
                arrayOf(
                    MediaStore.MediaColumns.DISPLAY_NAME,
                    MediaStore.MediaColumns.SIZE,
                    MediaStore.MediaColumns.DATA
                ),
                null,
                null,
                null
            )?.use { cur ->
                if (cur.moveToFirst()) {
                    resolvedName = cur.getString(0) ?: displayName
                    val s = cur.getLong(1)
                    if (s > 0L) resolvedSize = s
                    resolvedFilePath = cur.getString(2)
                }
            }

            // Delete temporary staging file and clear session state
            try { stagingFile.delete() } catch (_: Exception) {}
            clearActiveSession()

            val entity = CallRecordingEntity(
                mediaStoreId = mediaStoreId,
                mediaUri = insertedUri.toString(),
                filePath = resolvedFilePath,
                displayName = resolvedName,
                mode = mode,
                audioSource = audioSource,
                mimeType = mode.mimeType,
                durationMs = extractedDuration,
                sizeBytes = resolvedSize,
                createdAtMs = startedAtMs,
                isPartial = isPartial,
                backupSynced = false
            )

            val saved = dbHelper.upsertCallRecording(entity, preserveExistingMetadata = false)
            Log.i(TAG, "✓ Published call recording to MediaStore & SQLite: ${saved.displayName} (${saved.sizeBytes} bytes, partial=$isPartial)")
            saved
        } catch (e: Exception) {
            Log.e(TAG, "Failed to publish staging file to MediaStore: ${e.message}", e)
            if (insertedUri != null) {
                try { resolver.delete(insertedUri, null, null) } catch (_: Exception) {}
            }
            null
        }
    }

    /**
     * Scans `CallRecordingsStaging` for any interrupted recording left behind by a hard
     * process kill (e.g. OEM force-stop or battery exhaustion).
     * Must ONLY be called when [CallRecorderService.isActivelyRecording] is false.
     */
    @Synchronized
    fun recoverInterruptedRecordings(): List<CallRecordingEntity> {
        if (CallRecorderService.isActivelyRecording) return emptyList()

        val recovered = mutableListOf<CallRecordingEntity>()
        val prefs = appContext.getSharedPreferences(SESSION_PREFS, Context.MODE_PRIVATE)
        val savedAudioSource = AudioSourceOption.fromWire(prefs.getString(KEY_AUDIO_SOURCE, "MIC"))
        val stagingDir = getStagingDir()
        val files = stagingDir.listFiles()?.filter {
            it.isFile && !it.name.endsWith(".repaired")
        } ?: emptyList()

        if (files.isEmpty()) {
            clearActiveSession()
            return emptyList()
        }

        for (file in files) {
            try {
                if (file.length() < 1024L) {
                    Log.w(TAG, "Deleting unrecoverable stub staging file (${file.length()}B): ${file.name}")
                    file.delete()
                    continue
                }

                val mode = if (file.extension.equals("mp4", ignoreCase = true)) {
                    RecordingMode.VIDEO
                } else {
                    RecordingMode.VOICE
                }

                var candidateFile = file
                var durationMs = extractDurationMs(candidateFile)

                // If container index wasn't flushed, attempt packet-level remux recovery
                if (durationMs <= 0L) {
                    val remuxed = tryRemuxPartialContainer(file, mode)
                    if (remuxed != null && remuxed.exists() && remuxed.length() > 1024L) {
                        file.delete()
                        remuxed.renameTo(file)
                        candidateFile = file
                        durationMs = extractDurationMs(candidateFile)
                    }
                }

                if (durationMs > 0L || isContainerReadable(candidateFile)) {
                    val entity = publishStagingFileToMediaStore(
                        stagingFile = candidateFile,
                        mode = mode,
                        audioSource = savedAudioSource,
                        startedAtMs = candidateFile.lastModified().takeIf { it > 0L } ?: System.currentTimeMillis(),
                        fallbackDurationMs = durationMs.coerceAtLeast(0L),
                        isPartial = true
                    )
                    if (entity != null) {
                        recovered.add(entity)
                        Log.i(TAG, "✓ Recovered interrupted call recording: ${entity.displayName}")
                    }
                } else {
                    Log.w(TAG, "Unfinalized container could not be salvaged (SIGKILL mid-stream): ${file.name}")
                    file.delete()
                }
            } catch (e: Exception) {
                Log.w(TAG, "Recovery error for ${file.name}: ${e.message}")
            }
        }

        clearActiveSession()
        return recovered
    }

    /**
     * Synchronizes `MediaStore` (`Movies/CallRecordings` + `Music/CallRecordings`) with
     * SQLite (`call_recordings` table) and returns all recordings ordered newest-first.
     */
    @Synchronized
    fun syncAndListRecordings(): List<CallRecordingEntity> {
        recoverInterruptedRecordings()

        val validUris = HashSet<String>()
        try {
            val videoEntries = queryMediaStoreDirectory(RecordingMode.VIDEO, VIDEO_RELATIVE_DIR)
            val voiceEntries = queryMediaStoreDirectory(RecordingMode.VOICE, AUDIO_RELATIVE_DIR)

            for (entry in (videoEntries + voiceEntries)) {
                validUris.add(entry.mediaUri)
                dbHelper.upsertCallRecording(entry, preserveExistingMetadata = true)
            }

            // Prune SQLite rows that were deleted externally in Files / Gallery apps
            dbHelper.pruneMissingCallRecordings(validUris)
        } catch (e: Exception) {
            Log.e(TAG, "syncAndListRecordings error: ${e.message}", e)
        }

        return dbHelper.getAllCallRecordings()
    }

    private fun queryMediaStoreDirectory(
        mode: RecordingMode,
        relativeDirMatch: String
    ): List<CallRecordingEntity> {
        val list = mutableListOf<CallRecordingEntity>()
        val collection = getMediaStoreCollection(mode)
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.MIME_TYPE,
            MediaStore.MediaColumns.DURATION,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_ADDED,
            MediaStore.MediaColumns.DATA,
            MediaStore.MediaColumns.IS_PENDING
        )
        val selection = "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ? AND ${MediaStore.MediaColumns.IS_PENDING} = 0"
        val selectionArgs = arrayOf("%$relativeDirMatch%")

        appContext.contentResolver.query(
            collection,
            projection,
            selection,
            selectionArgs,
            "${MediaStore.MediaColumns.DATE_ADDED} DESC"
        )?.use { cur ->
            val idCol = cur.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            val nameCol = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
            val mimeCol = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE)
            val durCol = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.DURATION)
            val sizeCol = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
            val dateCol = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_ADDED)
            val dataCol = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.DATA)

            while (cur.moveToNext()) {
                val msId = cur.getLong(idCol)
                val uri = ContentUris.withAppendedId(collection, msId)
                val name = cur.getString(nameCol) ?: continue
                val mime = cur.getString(mimeCol) ?: mode.mimeType
                val dur = if (cur.isNull(durCol)) 0L else cur.getLong(durCol)
                val size = if (cur.isNull(sizeCol)) 0L else cur.getLong(sizeCol)
                val dateAddedSec = if (cur.isNull(dateCol)) 0L else cur.getLong(dateCol)
                val dataPath = if (cur.isNull(dataCol)) null else cur.getString(dataCol)

                list.add(
                    CallRecordingEntity(
                        mediaStoreId = msId,
                        mediaUri = uri.toString(),
                        filePath = dataPath,
                        displayName = name,
                        mode = mode,
                        audioSource = AudioSourceOption.MIC, // Preserved if already in SQLite
                        mimeType = mime,
                        durationMs = dur,
                        sizeBytes = size,
                        createdAtMs = if (dateAddedSec > 0L) dateAddedSec * 1000L else System.currentTimeMillis()
                    )
                )
            }
        }
        return list
    }

    /**
     * Renames a recording in both `MediaStore` and SQLite (`call_recordings`).
     */
    @Synchronized
    fun renameRecording(id: Long, rawNewName: String): CallRecordingEntity {
        val existing = dbHelper.getCallRecordingById(id)
            ?: throw IllegalArgumentException("Recording #$id not found")

        // Strip illegal filesystem characters and ensure proper extension
        val cleanedBase = rawNewName
            .trim()
            .replace(Regex("""[\\/:*?"<>|]"""), "_")
            .removeSuffix(".${existing.mode.fileExtension}")
            .removeSuffix(".${existing.mode.fileExtension.uppercase(Locale.US)}")
            .trim()

        if (cleanedBase.isEmpty()) {
            throw IllegalArgumentException("Recording name cannot be empty")
        }

        val targetDisplayName = "$cleanedBase.${existing.mode.fileExtension}"
        if (targetDisplayName == existing.displayName) return existing

        val uri = Uri.parse(existing.mediaUri)
        val resolver = appContext.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, targetDisplayName)
        }

        val updatedRows = resolver.update(uri, values, null, null)
        if (updatedRows <= 0) {
            throw IllegalStateException("MediaStore refused rename for ${existing.displayName}")
        }

        // Read back canonical DISPLAY_NAME and DATA path (MediaStore may suffix if duplicate)
        var actualName = targetDisplayName
        var actualPath = existing.filePath
        resolver.query(
            uri,
            arrayOf(MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.DATA),
            null,
            null,
            null
        )?.use { cur ->
            if (cur.moveToFirst()) {
                actualName = cur.getString(0) ?: targetDisplayName
                actualPath = cur.getString(1) ?: existing.filePath
            }
        }

        dbHelper.updateCallRecordingRename(id, actualName, actualPath)
        return dbHelper.getCallRecordingById(id) ?: existing.copy(
            displayName = actualName,
            filePath = actualPath
        )
    }

    /**
     * Deletes a recording from both `MediaStore` and SQLite (`call_recordings`).
     */
    @Synchronized
    fun deleteRecording(id: Long): Boolean {
        val existing = dbHelper.getCallRecordingById(id) ?: return false
        try {
            val uri = Uri.parse(existing.mediaUri)
            appContext.contentResolver.delete(uri, null, null)
        } catch (e: SecurityException) {
            Log.e(TAG, "SecurityException deleting MediaStore entry ${existing.mediaUri}: ${e.message}")
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "MediaStore delete warning (may already be deleted): ${e.message}")
        }

        // Also remove any cached playback copy
        try {
            val cacheCopy = File(File(appContext.cacheDir, "call_playback"), existing.displayName)
            if (cacheCopy.exists()) cacheCopy.delete()
        } catch (_: Exception) {}

        return dbHelper.deleteCallRecordingById(id)
    }

    /**
     * Resolves a guaranteed-readable local filesystem path for Flutter playback & sharing.
     * On Android 11+ (API 30+), app-owned MediaStore `DATA` paths are directly readable via FUSE.
     * On Android 10 (API 29), Scoped Storage blocks raw `File` reads on shared directories,
     * so we fall back to streaming the `content://` URI into `cacheDir/call_playback/`.
     */
    fun resolveReadableFilePath(id: Long): String {
        val entity = dbHelper.getCallRecordingById(id)
            ?: throw IllegalArgumentException("Recording #$id not found")

        val directPath = entity.filePath
        if (!directPath.isNullOrBlank()) {
            val directFile = File(directPath)
            if (directFile.exists() && directFile.canRead() && directFile.length() > 0L) {
                return directFile.absolutePath
            }
        }

        val cacheDir = File(appContext.cacheDir, "call_playback").apply {
            if (!exists()) mkdirs()
        }
        val safeName = entity.displayName.ifBlank { "recording_${entity.id}.${entity.mode.fileExtension}" }
        val cachedFile = File(cacheDir, safeName)

        if (!cachedFile.exists() || cachedFile.length() != entity.sizeBytes || cachedFile.length() == 0L) {
            val uri = Uri.parse(entity.mediaUri)
            appContext.contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(cachedFile).use { output ->
                    input.copyTo(output, bufferSize = 64 * 1024)
                    output.flush()
                }
            } ?: throw IllegalStateException("Cannot open stream for ${entity.mediaUri}")
        }

        return cachedFile.absolutePath
    }

    private fun getMediaStoreCollection(mode: RecordingMode): Uri {
        return if (mode == RecordingMode.VIDEO) {
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        }
    }

    private fun extractDurationMs(file: File): Long {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(file.absolutePath)
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
        } catch (_: Exception) {
            0L
        } finally {
            try { retriever.release() } catch (_: Exception) {}
        }
    }

    private fun isContainerReadable(file: File): Boolean {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(file.absolutePath)
            extractor.trackCount > 0
        } catch (_: Exception) {
            false
        } finally {
            try { extractor.release() } catch (_: Exception) {}
        }
    }

    /**
     * Best-effort packet remux using [MediaExtractor] + [MediaMuxer] for partial MP4/M4A files.
     */
    private fun tryRemuxPartialContainer(source: File, mode: RecordingMode): File? {
        val extractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        val repaired = File(source.parentFile, "${source.name}.repaired")
        return try {
            extractor.setDataSource(source.absolutePath)
            val trackCount = extractor.trackCount
            if (trackCount <= 0) return null

            muxer = MediaMuxer(repaired.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val trackMap = HashMap<Int, Int>()
            for (i in 0 until trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString( android.media.MediaFormat.KEY_MIME ) ?: continue
                if (mime.startsWith("audio/") || (mode == RecordingMode.VIDEO && mime.startsWith("video/"))) {
                    extractor.selectTrack(i)
                    trackMap[i] = muxer.addTrack(format)
                }
            }
            if (trackMap.isEmpty()) return null

            muxer.start()
            val buffer = ByteBuffer.allocate(256 * 1024)
            val bufferInfo = MediaCodec.BufferInfo()

            while (true) {
                val trackIndex = extractor.sampleTrackIndex
                if (trackIndex < 0) break
                val sampleSize = extractor.readSampleData(buffer, 0)
                if (sampleSize < 0) break

                val dstTrack = trackMap[trackIndex]
                if (dstTrack != null) {
                    bufferInfo.offset = 0
                    bufferInfo.size = sampleSize
                    bufferInfo.presentationTimeUs = extractor.sampleTime.coerceAtLeast(0L)
                    bufferInfo.flags = if ((extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC) != 0) {
                        MediaCodec.BUFFER_FLAG_KEY_FRAME
                    } else {
                        0
                    }
                    muxer.writeSampleData(dstTrack, buffer, bufferInfo)
                }
                extractor.advance()
            }
            muxer.stop()
            repaired
        } catch (_: Exception) {
            try { repaired.delete() } catch (_: Exception) {}
            null
        } finally {
            try { extractor.release() } catch (_: Exception) {}
            try { muxer?.release() } catch (_: Exception) {}
        }
    }
}


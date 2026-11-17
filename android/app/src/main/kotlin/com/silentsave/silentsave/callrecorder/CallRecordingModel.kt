package com.silentsave.silentsave.callrecorder

import android.media.MediaRecorder

/**
 * Capture modes supported by the Call Recorder module.
 * - [VIDEO]: MediaProjection screen capture + microphone audio -> MP4 (H.264 + AAC)
 * - [VOICE]: Microphone-only audio -> M4A (MPEG-4 container + AAC)
 */
enum class RecordingMode(
    val wireValue: String,
    val fileExtension: String,
    val mimeType: String
) {
    VIDEO("video", "mp4", "video/mp4"),
    VOICE("voice", "m4a", "audio/mp4");

    companion object {
        fun fromWire(value: String?): RecordingMode {
            return when (value?.lowercase()) {
                "video" -> VIDEO
                else -> VOICE
            }
        }
    }
}

/**
 * User-selectable microphone audio sources for call recording.
 * Different Android OEMs route audio HAL streams differently during VoIP calls:
 * - [MIC]: Raw main microphone input; widest hardware support.
 * - [VOICE_COMMUNICATION]: VoIP-tuned mic with acoustic echo cancellation (AEC) & AGC;
 *   may conflict with WhatsApp's own VOICE_COMMUNICATION session on some chipsets.
 * - [VOICE_RECOGNITION]: Unprocessed recognition path; often bypasses OEM VoIP blocks
 *   and aggressive noise gates that mute speakerphone audio.
 */
enum class AudioSourceOption(val wireValue: String, val androidSource: Int) {
    MIC("MIC", MediaRecorder.AudioSource.MIC),
    VOICE_COMMUNICATION("VOICE_COMMUNICATION", MediaRecorder.AudioSource.VOICE_COMMUNICATION),
    VOICE_RECOGNITION("VOICE_RECOGNITION", MediaRecorder.AudioSource.VOICE_RECOGNITION);

    companion object {
        fun fromWire(value: String?): AudioSourceOption {
            return entries.firstOrNull { it.wireValue.equals(value, ignoreCase = true) } ?: MIC
        }
    }
}

/**
 * Lifecycle states emitted over the EventChannel (`com.silentsave/call_recorder_events`).
 */
enum class RecorderState(val wireValue: String) {
    IDLE("idle"),
    PREPARING("preparing"),
    RECORDING("recording"),
    STOPPING("stopping"),
    COMPLETED("completed"),
    ERROR("error")
}

/**
 * Standardized error codes surfaced across Kotlin -> Flutter platform channels.
 */
object RecorderErrorCodes {
    const val PERMISSION_DENIED = "PERMISSION_DENIED"
    const val PROJECTION_DENIED = "PROJECTION_DENIED"
    const val PROJECTION_REVOKED = "PROJECTION_REVOKED"
    const val MIC_IN_USE = "MIC_IN_USE"
    const val LOW_STORAGE = "LOW_STORAGE"
    const val SERVICE_KILLED = "SERVICE_KILLED"
    const val RECORDER_ERROR = "RECORDER_ERROR"
    const val NOT_FOUND = "NOT_FOUND"
    const val RENAME_FAILED = "RENAME_FAILED"
    const val DELETE_FAILED = "DELETE_FAILED"
}

/**
 * Persistent metadata entity stored in SQLite (`call_recordings` table)
 * and synchronized with Android's `MediaStore` (`Movies/CallRecordings` or `Music/CallRecordings`).
 */
data class CallRecordingEntity(
    val id: Long = 0L,
    val mediaStoreId: Long? = null,
    val mediaUri: String,
    val filePath: String? = null,
    val displayName: String,
    val mode: RecordingMode,
    val audioSource: AudioSourceOption,
    val mimeType: String,
    val durationMs: Long,
    val sizeBytes: Long,
    val createdAtMs: Long,
    val isPartial: Boolean = false,
    val backupSynced: Boolean = false
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "id" to id,
        "mediaStoreId" to mediaStoreId,
        "mediaUri" to mediaUri,
        "filePath" to filePath,
        "displayName" to displayName,
        "mode" to mode.wireValue,
        "audioSource" to audioSource.wireValue,
        "mimeType" to mimeType,
        "durationMs" to durationMs,
        "sizeBytes" to sizeBytes,
        "createdAtMs" to createdAtMs,
        "isPartial" to isPartial,
        "backupSynced" to backupSynced
    )
}

/**
 * Real-time state / progress / error payload streamed over EventChannel.
 */
data class RecorderEvent(
    val state: RecorderState,
    val mode: RecordingMode? = null,
    val audioSource: AudioSourceOption? = null,
    val elapsedMs: Long = 0L,
    val fileName: String? = null,
    val recording: CallRecordingEntity? = null,
    val errorCode: String? = null,
    val errorMessage: String? = null,
    val warningMessage: String? = null
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "state" to state.wireValue,
        "mode" to mode?.wireValue,
        "audioSource" to audioSource?.wireValue,
        "elapsedMs" to elapsedMs,
        "fileName" to fileName,
        "recording" to recording?.toMap(),
        "errorCode" to errorCode,
        "errorMessage" to errorMessage,
        "warningMessage" to warningMessage
    )
}


package com.silentsave.silentsave.callrecorder

import android.annotation.SuppressLint
import android.content.Context
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.os.Build
import android.util.DisplayMetrics
import android.util.Log
import android.view.WindowManager
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs

/**
 * Typed exception carrying a platform-channel [errorCode] from [RecorderErrorCodes].
 */
class RecorderEngineException(
    val errorCode: String,
    override val message: String,
    cause: Throwable? = null
) : Exception(message, cause)

/**
 * Recorder layer encapsulating:
 *  - **Voice Call mode (`M4A/AAC`):** In-process [AudioRecord] (attributed directly to
 *    [CallRecorderAccessibilityService]'s [Context] via `AudioRecord.Builder.setContext`) +
 *    hardware [MediaCodec] (`audio/mp4a-latm` AAC-LC) + [MediaMuxer] (`MPEG_4`), with live
 *    PCM silence detection and automatic source hot-swapping (`VOICE_RECOGNITION` -> `MIC` ->
 *    `UNPROCESSED` -> `CAMCORDER` -> `VOICE_COMMUNICATION`).
 *  - **Video Call mode (`MP4`):** [MediaProjection] [VirtualDisplay] + [MediaRecorder].
 */
class CallMediaRecorderEngine(
    private val context: Context,
    private val onRuntimeError: (errorCode: String, message: String) -> Unit
) {

    companion object {
        private const val TAG = "CallMediaEngine"
        private const val MAX_VIDEO_LONG_EDGE = 1280
        private const val VIDEO_FRAME_RATE = 30
        private const val VIDEO_BITRATE_BPS = 4_500_000
        private const val AUDIO_BITRATE_BPS = 128_000
        private const val AUDIO_SAMPLE_RATE_HZ = 44_100
        private const val CODEC_TIMEOUT_US = 10_000L
    }

    private data class CandidateAudioSource(val name: String, val androidSource: Int)

    // Video mode handles
    private var mediaRecorder: MediaRecorder? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var mediaProjection: MediaProjection? = null

    // Voice mode (AudioRecord + MediaCodec + MediaMuxer) handles
    @Volatile
    private var isVoiceLoopRunning: Boolean = false
    private var voiceThread: Thread? = null

    @Volatile
    private var latestPeakAmplitude: Int = 0

    @Volatile
    var isStarted: Boolean = false
        private set

    /**
     * Prepares and starts a Voice-only (`M4A/AAC`) recording into [outputFile] using
     * in-process [AudioRecord] + [MediaCodec] + [MediaMuxer].
     */
    @Throws(RecorderEngineException::class)
    fun startVoiceRecording(
        outputFile: File,
        audioSource: AudioSourceOption
    ) {
        val candidates = buildCandidateSources(audioSource)
        val minBufBytes = AudioRecord.getMinBufferSize(
            AUDIO_SAMPLE_RATE_HZ,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        ).coerceAtLeast(4096)
        val bufferSizeInBytes = (minBufBytes * 2).coerceAtLeast(8192)

        // Open initial AudioRecord using AccessibilityService attribution context
        var initialRecord: AudioRecord? = null
        var chosenIndex = 0
        for (i in candidates.indices) {
            val rec = tryOpenAudioRecord(candidates[i], bufferSizeInBytes)
            if (rec != null) {
                initialRecord = rec
                chosenIndex = i
                break
            }
        }

        if (initialRecord == null) {
            throw RecorderEngineException(
                RecorderErrorCodes.MIC_IN_USE,
                "Could not initialize microphone with any audio source (${audioSource.wireValue}).",
                null
            )
        }

        var codec: MediaCodec? = null
        var muxer: MediaMuxer? = null
        try {
            val format = MediaFormat.createAudioFormat(
                MediaFormat.MIMETYPE_AUDIO_AAC,
                AUDIO_SAMPLE_RATE_HZ,
                1
            ).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, AUDIO_BITRATE_BPS)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
            }

            codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC).apply {
                configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                start()
            }

            muxer = MediaMuxer(outputFile.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

            isVoiceLoopRunning = true
            isStarted = true
            latestPeakAmplitude = 0

            val activeCodec = codec
            val activeMuxer = muxer
            val firstRecord = initialRecord
            val startIndex = chosenIndex

            voiceThread = Thread(
                {
                    runVoiceEncodeLoop(
                        firstRecord = firstRecord,
                        startCandidateIndex = startIndex,
                        candidates = candidates,
                        bufferSizeInBytes = bufferSizeInBytes,
                        codec = activeCodec,
                        muxer = activeMuxer
                    )
                },
                "SilentSave-VoiceCodecThread"
            ).apply {
                priority = Thread.MAX_PRIORITY
                start()
            }

            Log.i(
                TAG,
                "✓ In-process AudioRecord+MediaCodec voice recorder started -> ${outputFile.name} " +
                    "(initialSource=${candidates[startIndex].name}, a11yCtx=${CallRecorderAccessibilityService.instance != null})"
            )
        } catch (e: Exception) {
            safeReleaseAudioRecord(initialRecord)
            try { codec?.stop() } catch (_: Exception) {}
            try { codec?.release() } catch (_: Exception) {}
            try { muxer?.release() } catch (_: Exception) {}
            isVoiceLoopRunning = false
            isStarted = false
            throw RecorderEngineException(
                RecorderErrorCodes.RECORDER_ERROR,
                "Failed to start AAC voice encoder: ${e.message ?: "unknown error"}",
                e
            )
        }
    }

    private fun buildCandidateSources(preferred: AudioSourceOption): List<CandidateAudioSource> {
        // Note: During a WhatsApp call on Android 10–16, VOICE_RECOGNITION (6) and MIC (1)
        // are prioritized for AccessibilityService concurrent capture; VOICE_COMMUNICATION (7)
        // conflicts with the active VoIP call's VOICE_COMMUNICATION session and strips speakerphone audio.
        val primary = if (preferred == AudioSourceOption.VOICE_COMMUNICATION) {
            CandidateAudioSource("VOICE_RECOGNITION", MediaRecorder.AudioSource.VOICE_RECOGNITION)
        } else {
            CandidateAudioSource(preferred.wireValue, preferred.androidSource)
        }

        val all = listOf(
            primary,
            CandidateAudioSource("VOICE_RECOGNITION", MediaRecorder.AudioSource.VOICE_RECOGNITION),
            CandidateAudioSource("MIC", MediaRecorder.AudioSource.MIC),
            CandidateAudioSource("UNPROCESSED", MediaRecorder.AudioSource.UNPROCESSED),
            CandidateAudioSource("CAMCORDER", MediaRecorder.AudioSource.CAMCORDER)
        )
        return all.distinctBy { it.androidSource }
    }

    @SuppressLint("MissingPermission")
    private fun tryOpenAudioRecord(
        candidate: CandidateAudioSource,
        bufferSizeInBytes: Int
    ): AudioRecord? {
        val attrCtx = CallRecorderAccessibilityService.getCaptureAttributionContext(context)
        return try {
            val audioFormat = AudioFormat.Builder()
                .setSampleRate(AUDIO_SAMPLE_RATE_HZ)
                .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .build()

            val builder = AudioRecord.Builder()
                .setAudioSource(candidate.androidSource)
                .setAudioFormat(audioFormat)
                .setBufferSizeInBytes(bufferSizeInBytes)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                builder.setContext(attrCtx)
            }

            val record = builder.build()
            if (record.state != AudioRecord.STATE_INITIALIZED) {
                record.release()
                return null
            }
            record.startRecording()
            if (record.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                record.release()
                return null
            }
            record
        } catch (e: Exception) {
            Log.w(TAG, "tryOpenAudioRecord(${candidate.name}) failed: ${e.message}")
            null
        }
    }

    private fun runVoiceEncodeLoop(
        firstRecord: AudioRecord,
        startCandidateIndex: Int,
        candidates: List<CandidateAudioSource>,
        bufferSizeInBytes: Int,
        codec: MediaCodec,
        muxer: MediaMuxer
    ) {
        var currentRecord: AudioRecord? = firstRecord
        var currentCandidateIdx = startCandidateIndex
        var muxerTrackIndex = -1
        var muxerStarted = false

        val pcmShorts = ShortArray(2048) // ~46.4ms per read at 44.1 kHz
        val bufferInfo = MediaCodec.BufferInfo()
        var totalSamplesSubmitted = 0L
        var silentReadStreak = 0
        var telemetryReadCount = 0
        var telemetryPeak = 0
        var hotSwapsPerformed = 0

        try {
            while (isVoiceLoopRunning) {
                val rec = currentRecord ?: break
                val shortsRead = rec.read(pcmShorts, 0, pcmShorts.size)

                if (shortsRead > 0) {
                    var readPeak = 0
                    for (i in 0 until shortsRead) {
                        val s = pcmShorts[i].toInt()
                        val absVal = abs(s)
                        if (absVal > readPeak) readPeak = absVal
                        // Apply 2.2x gain boost with saturation clamp so speakerphone voice is clear
                        val boosted = ((s * 22) / 10).coerceIn(-32768, 32767)
                        pcmShorts[i] = boosted.toShort()
                    }

                    if (readPeak > latestPeakAmplitude) {
                        latestPeakAmplitude = readPeak
                    }
                    if (readPeak > telemetryPeak) {
                        telemetryPeak = readPeak
                    }

                    telemetryReadCount++
                    if (telemetryReadCount >= 22) { // ~1.0s
                        Log.i(
                            TAG,
                            "Voice PCM telemetry [source=${candidates[currentCandidateIdx].name}]: peak=$telemetryPeak"
                        )
                        telemetryReadCount = 0
                        telemetryPeak = 0
                    }

                    // Only treat exact digital zero (readPeak == 0, which AudioFlinger writes when a
                    // stream is virtually muted) as OS silencing; a quiet room has ADC thermal noise >= 1.
                    if (readPeak == 0) {
                        silentReadStreak++
                        if (silentReadStreak >= 36 && hotSwapsPerformed < candidates.size) {
                            silentReadStreak = 0
                            val nextIdx = (currentCandidateIdx + 1) % candidates.size
                            val nextCandidate = candidates[nextIdx]
                            Log.w(
                                TAG,
                                "Source ${candidates[currentCandidateIdx].name} returned exact digital 0 for 1.7s — " +
                                    "hot-swapping AudioRecord to ${nextCandidate.name}"
                            )
                            safeReleaseAudioRecord(currentRecord)
                            val replacement = tryOpenAudioRecord(nextCandidate, bufferSizeInBytes)
                            if (replacement != null) {
                                currentRecord = replacement
                                currentCandidateIdx = nextIdx
                                hotSwapsPerformed++
                            } else {
                                currentRecord = tryOpenAudioRecord(
                                    candidates[currentCandidateIdx],
                                    bufferSizeInBytes
                                )
                            }
                        }
                    } else {
                        silentReadStreak = 0
                    }

                    // Feed all read PCM samples into MediaCodec input buffers without dropping any chunk
                    var sampleOffset = 0
                    while (sampleOffset < shortsRead && isVoiceLoopRunning) {
                        val inBufIdx = codec.dequeueInputBuffer(CODEC_TIMEOUT_US)
                        if (inBufIdx >= 0) {
                            val inBuf = codec.getInputBuffer(inBufIdx)
                            val remainingShorts = shortsRead - sampleOffset
                            val maxShortsInBuf = (inBuf?.remaining() ?: 0) / 2
                            val shortCount = minOf(remainingShorts, maxShortsInBuf)
                            if (inBuf != null && shortCount > 0) {
                                inBuf.clear()
                                inBuf.order(ByteOrder.nativeOrder())
                                    .asShortBuffer()
                                    .put(pcmShorts, sampleOffset, shortCount)
                                val ptsUs = (totalSamplesSubmitted * 1_000_000L) / AUDIO_SAMPLE_RATE_HZ
                                codec.queueInputBuffer(inBufIdx, 0, shortCount * 2, ptsUs, 0)
                                totalSamplesSubmitted += shortCount
                                sampleOffset += shortCount
                            } else {
                                codec.queueInputBuffer(inBufIdx, 0, 0, 0L, 0)
                                break
                            }
                        }

                        // Drain encoded AAC frames into MediaMuxer
                        val drainState = drainEncoder(
                            codec = codec,
                            muxer = muxer,
                            bufferInfo = bufferInfo,
                            trackIndex = muxerTrackIndex,
                            muxerStarted = muxerStarted
                        )
                        muxerTrackIndex = drainState.first
                        muxerStarted = drainState.second
                    }
                } else {
                    Thread.sleep(10L)
                }
            }

            // Signal End-Of-Stream (EOS) to flush final AAC frames cleanly
            val eosInIdx = codec.dequeueInputBuffer(CODEC_TIMEOUT_US)
            if (eosInIdx >= 0) {
                val ptsUs = (totalSamplesSubmitted * 1_000_000L) / AUDIO_SAMPLE_RATE_HZ
                codec.queueInputBuffer(
                    eosInIdx,
                    0,
                    0,
                    ptsUs,
                    MediaCodec.BUFFER_FLAG_END_OF_STREAM
                )
            }
            val finalState = drainEncoder(
                codec = codec,
                muxer = muxer,
                bufferInfo = bufferInfo,
                trackIndex = muxerTrackIndex,
                muxerStarted = muxerStarted
            )
            muxerStarted = finalState.second
        } catch (e: Exception) {
            Log.e(TAG, "Error in runVoiceEncodeLoop: ${e.message}", e)
        } finally {
            safeReleaseAudioRecord(currentRecord)
            try { codec.stop() } catch (_: Exception) {}
            try { codec.release() } catch (_: Exception) {}
            if (muxerStarted) {
                try { muxer.stop() } catch (e: Exception) {
                    Log.w(TAG, "MediaMuxer.stop() warning: ${e.message}")
                }
            }
            try { muxer.release() } catch (_: Exception) {}
        }
    }

    private fun drainEncoder(
        codec: MediaCodec,
        muxer: MediaMuxer,
        bufferInfo: MediaCodec.BufferInfo,
        trackIndex: Int,
        muxerStarted: Boolean
    ): Pair<Int, Boolean> {
        var curTrack = trackIndex
        var started = muxerStarted

        while (true) {
            val outIdx = codec.dequeueOutputBuffer(bufferInfo, 0L)
            when {
                outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> break
                outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    if (!started) {
                        curTrack = muxer.addTrack(codec.outputFormat)
                        muxer.start()
                        started = true
                    }
                }
                outIdx >= 0 -> {
                    val outBuf: ByteBuffer? = codec.getOutputBuffer(outIdx)
                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                        bufferInfo.size = 0
                    }
                    if (bufferInfo.size > 0 && started && outBuf != null) {
                        outBuf.position(bufferInfo.offset)
                        outBuf.limit(bufferInfo.offset + bufferInfo.size)
                        muxer.writeSampleData(curTrack, outBuf, bufferInfo)
                    }
                    codec.releaseOutputBuffer(outIdx, false)
                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        break
                    }
                }
                else -> break
            }
        }
        return Pair(curTrack, started)
    }

    private fun safeReleaseAudioRecord(record: AudioRecord?) {
        if (record == null) return
        try {
            if (record.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                record.stop()
            }
        } catch (_: Exception) {}
        try {
            record.release()
        } catch (_: Exception) {}
    }

    /**
     * Prepares and starts a Video (`MediaProjection` screen + mic audio -> `MP4`) recording.
     */
    @Throws(RecorderEngineException::class)
    fun startVideoRecording(
        outputFile: File,
        audioSource: AudioSourceOption,
        projection: MediaProjection
    ) {
        var recorder: MediaRecorder? = null
        var display: VirtualDisplay? = null
        try {
            val (width, height, densityDpi) = computeCodecAlignedScreenMetrics()
            val effectiveSource = if (audioSource == AudioSourceOption.VOICE_COMMUNICATION) {
                MediaRecorder.AudioSource.VOICE_RECOGNITION
            } else {
                audioSource.androidSource
            }
            Log.i(TAG, "Configuring video screen capture: ${width}x${height} @ ${densityDpi}dpi (source=${audioSource.wireValue})")

            recorder = createMediaRecorderInstance().apply {
                setAudioSource(effectiveSource)
                setVideoSource(MediaRecorder.VideoSource.SURFACE)
                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                setOutputFile(outputFile.absolutePath)
                setVideoEncoder(MediaRecorder.VideoEncoder.H264)
                setVideoSize(width, height)
                setVideoFrameRate(VIDEO_FRAME_RATE)
                setVideoEncodingBitRate(VIDEO_BITRATE_BPS)
                setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                setAudioEncodingBitRate(AUDIO_BITRATE_BPS)
                setAudioSamplingRate(AUDIO_SAMPLE_RATE_HZ)
                attachListeners(this)
                prepare()
            }

            display = projection.createVirtualDisplay(
                "SilentSaveCallRecorder",
                width,
                height,
                densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                recorder.surface,
                null,
                null
            )

            try {
                recorder.start()
            } catch (startErr: RuntimeException) {
                throw RecorderEngineException(
                    RecorderErrorCodes.MIC_IN_USE,
                    "Screen + mic recorder failed to start (${audioSource.wireValue}).",
                    startErr
                )
            }

            mediaProjection = projection
            virtualDisplay = display
            mediaRecorder = recorder
            isStarted = true
            Log.i(TAG, "✓ Video MediaRecorder + VirtualDisplay started -> ${outputFile.name}")
        } catch (e: SecurityException) {
            try { display?.release() } catch (_: Exception) {}
            safeReleaseRecorder(recorder)
            try { projection.stop() } catch (_: Exception) {}
            throw RecorderEngineException(
                RecorderErrorCodes.PERMISSION_DENIED,
                "MediaProjection or microphone permission denied: ${e.message}",
                e
            )
        } catch (e: RecorderEngineException) {
            try { display?.release() } catch (_: Exception) {}
            safeReleaseRecorder(recorder)
            try { projection.stop() } catch (_: Exception) {}
            throw e
        } catch (e: Exception) {
            try { display?.release() } catch (_: Exception) {}
            safeReleaseRecorder(recorder)
            try { projection.stop() } catch (_: Exception) {}
            throw RecorderEngineException(
                RecorderErrorCodes.RECORDER_ERROR,
                "Failed to start video screen recorder: ${e.message ?: "unknown error"}",
                e
            )
        }
    }

    /**
     * Reads current peak microphone amplitude since the previous call (0..32767).
     */
    fun pollMaxAmplitude(): Int {
        if (!isStarted) return 0
        if (isVoiceLoopRunning) {
            val peak = latestPeakAmplitude
            latestPeakAmplitude = 0
            return peak
        }
        return try {
            mediaRecorder?.maxAmplitude ?: 0
        } catch (_: Exception) {
            0
        }
    }

    /**
     * Finalizes the MPEG-4 container (`moov` atom flush) and releases all native handles.
     */
    @Synchronized
    fun stopAndRelease(stopProjection: Boolean = true): Boolean {
        val wasStarted = isStarted
        isStarted = false

        var stoppedCleanly = false

        // 1. Stop in-process voice codec loop if active
        if (isVoiceLoopRunning) {
            isVoiceLoopRunning = false
            try {
                voiceThread?.join(3500L)
                stoppedCleanly = true
            } catch (e: Exception) {
                Log.w(TAG, "Voice thread join warning: ${e.message}")
            }
            voiceThread = null
        }

        // 2. Stop Video MediaRecorder if active
        val recorder = mediaRecorder
        mediaRecorder = null
        if (recorder != null) {
            try {
                if (wasStarted) {
                    recorder.stop()
                    stoppedCleanly = true
                }
            } catch (e: RuntimeException) {
                Log.w(TAG, "MediaRecorder.stop() runtime warning: ${e.message}")
            } catch (e: Exception) {
                Log.e(TAG, "MediaRecorder.stop() error: ${e.message}")
            } finally {
                safeReleaseRecorder(recorder)
            }
        }

        try {
            virtualDisplay?.release()
        } catch (e: Exception) {
            Log.w(TAG, "VirtualDisplay release warning: ${e.message}")
        }
        virtualDisplay = null

        val proj = mediaProjection
        mediaProjection = null
        if (proj != null && stopProjection) {
            try {
                proj.stop()
            } catch (e: Exception) {
                Log.w(TAG, "MediaProjection stop warning: ${e.message}")
            }
        }

        return stoppedCleanly
    }

    private fun attachListeners(recorder: MediaRecorder) {
        recorder.setOnErrorListener { _, what, extra ->
            Log.e(TAG, "MediaRecorder OnError: what=$what extra=$extra")
            onRuntimeError(
                RecorderErrorCodes.RECORDER_ERROR,
                "MediaRecorder hardware error (code=$what, extra=$extra)"
            )
        }
        recorder.setOnInfoListener { _, what, _ ->
            if (what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_FILESIZE_REACHED) {
                onRuntimeError(
                    RecorderErrorCodes.LOW_STORAGE,
                    "Maximum file size or storage limit reached; finalizing recording."
                )
            }
        }
    }

    private fun computeCodecAlignedScreenMetrics(): Triple<Int, Int, Int> {
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val rawWidth: Int
        val rawHeight: Int
        val densityDpi: Int

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bounds = wm.currentWindowMetrics.bounds
            rawWidth = bounds.width().coerceAtLeast(320)
            rawHeight = bounds.height().coerceAtLeast(320)
            densityDpi = context.resources.configuration.densityDpi.takeIf { it > 0 }
                ?: DisplayMetrics.DENSITY_HIGH
        } else {
            val dm = DisplayMetrics()
            @Suppress("DEPRECATION")
            wm.defaultDisplay.getRealMetrics(dm)
            rawWidth = dm.widthPixels.coerceAtLeast(320)
            rawHeight = dm.heightPixels.coerceAtLeast(320)
            densityDpi = dm.densityDpi.takeIf { it > 0 } ?: DisplayMetrics.DENSITY_HIGH
        }

        val longEdge = maxOf(rawWidth, rawHeight)
        val scale = if (longEdge > MAX_VIDEO_LONG_EDGE) {
            MAX_VIDEO_LONG_EDGE.toDouble() / longEdge.toDouble()
        } else {
            1.0
        }

        val scaledW = ((rawWidth * scale).toInt() / 16) * 16
        val scaledH = ((rawHeight * scale).toInt() / 16) * 16
        return Triple(scaledW.coerceAtLeast(320), scaledH.coerceAtLeast(320), densityDpi)
    }

    private fun createMediaRecorderInstance(): MediaRecorder {
        val attrCtx = CallRecorderAccessibilityService.getCaptureAttributionContext(context)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            MediaRecorder(attrCtx)
        } else {
            @Suppress("DEPRECATION")
            MediaRecorder()
        }
    }

    private fun safeReleaseRecorder(recorder: MediaRecorder?) {
        if (recorder == null) return
        try { recorder.reset() } catch (_: Exception) {}
        try { recorder.release() } catch (_: Exception) {}
    }
}

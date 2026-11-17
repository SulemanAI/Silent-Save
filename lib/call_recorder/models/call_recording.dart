/// Domain and data models for the Call Recorder module.
library;

/// Recording capture mode:
/// - [video]: `MediaProjection` screen capture + microphone audio -> `.mp4` (`Movies/CallRecordings`)
/// - [voice]: Microphone-only audio -> `.m4a` (`Music/CallRecordings`)
enum CallRecordingMode {
  video('video', 'Video Call', 'MP4 • Screen + Mic', 'Movies/CallRecordings'),
  voice('voice', 'Voice Call', 'M4A/AAC • Mic Only', 'Music/CallRecordings');

  final String wireValue;
  final String label;
  final String subtitle;
  final String mediaStoreFolder;

  const CallRecordingMode(
    this.wireValue,
    this.label,
    this.subtitle,
    this.mediaStoreFolder,
  );

  static CallRecordingMode fromWire(String? value) {
    return value?.toLowerCase() == 'video'
        ? CallRecordingMode.video
        : CallRecordingMode.voice;
  }
}

/// Selectable Android `MediaRecorder.AudioSource` options.
enum CallAudioSource {
  mic(
    'MIC',
    'MIC (Default)',
    'Standard main microphone. Most reliable across devices.',
  ),
  voiceRecognition(
    'VOICE_RECOGNITION',
    'VOICE_RECOGNITION',
    'Unprocessed speech mic. Often captures speakerphone audio best without OEM noise suppression.',
  ),
  voiceCommunication(
    'VOICE_COMMUNICATION',
    'VOICE_COMMUNICATION',
    'VoIP communication source with echo cancellation. May conflict with WhatsApp on some chipsets.',
  );

  final String wireValue;
  final String label;
  final String description;

  const CallAudioSource(this.wireValue, this.label, this.description);

  static CallAudioSource fromWire(String? value) {
    for (final option in CallAudioSource.values) {
      if (option.wireValue.toUpperCase() == value?.toUpperCase()) {
        return option;
      }
    }
    return CallAudioSource.mic;
  }
}

/// Live lifecycle status of the foreground `CallRecorderService`.
enum CallRecorderStatus {
  idle('idle'),
  preparing('preparing'),
  recording('recording'),
  stopping('stopping'),
  completed('completed'),
  error('error');

  final String wireValue;
  const CallRecorderStatus(this.wireValue);

  bool get isActive =>
      this == CallRecorderStatus.preparing ||
      this == CallRecorderStatus.recording ||
      this == CallRecorderStatus.stopping;

  static CallRecorderStatus fromWire(String? value) {
    for (final s in CallRecorderStatus.values) {
      if (s.wireValue == value) return s;
    }
    return CallRecorderStatus.idle;
  }
}

/// Immutable representation of a saved call recording synchronized between
/// `silentsave.db` (`call_recordings` table) and Android `MediaStore`.
class CallRecording {
  final int id;
  final int? mediaStoreId;
  final String mediaUri;
  final String? filePath;
  final String displayName;
  final CallRecordingMode mode;
  final CallAudioSource audioSource;
  final String mimeType;
  final int durationMs;
  final int sizeBytes;
  final DateTime createdAt;
  final bool isPartial;
  final bool backupSynced;

  const CallRecording({
    required this.id,
    this.mediaStoreId,
    required this.mediaUri,
    this.filePath,
    required this.displayName,
    required this.mode,
    required this.audioSource,
    required this.mimeType,
    required this.durationMs,
    required this.sizeBytes,
    required this.createdAt,
    this.isPartial = false,
    this.backupSynced = false,
  });

  Duration get duration => Duration(milliseconds: durationMs);

  /// Parses recording metadata from either the Kotlin MethodChannel map
  /// (camelCase keys) or a direct `sqflite` row map (snake_case keys).
  factory CallRecording.fromMap(Map<dynamic, dynamic> map) {
    final rawCreatedAt = map['createdAtMs'] ?? map['created_at'] ?? 0;
    final createdAtMs = (rawCreatedAt is num)
        ? rawCreatedAt.toInt()
        : int.tryParse(rawCreatedAt.toString()) ?? 0;

    final rawPartial = map['isPartial'] ?? map['is_partial'] ?? false;
    final isPartial = rawPartial == true || rawPartial == 1;

    final rawSynced = map['backupSynced'] ?? map['backup_synced'] ?? false;
    final backupSynced = rawSynced == true || rawSynced == 1;

    return CallRecording(
      id: (map['id'] as num? ?? 0).toInt(),
      mediaStoreId: (map['mediaStoreId'] ?? map['media_store_id']) != null
          ? ((map['mediaStoreId'] ?? map['media_store_id']) as num).toInt()
          : null,
      mediaUri: (map['mediaUri'] ?? map['media_uri'] ?? '').toString(),
      filePath: (map['filePath'] ?? map['file_path'])?.toString(),
      displayName: (map['displayName'] ?? map['display_name'] ?? '').toString(),
      mode: CallRecordingMode.fromWire(map['mode']?.toString()),
      audioSource: CallAudioSource.fromWire(
        (map['audioSource'] ?? map['audio_source'])?.toString(),
      ),
      mimeType: (map['mimeType'] ?? map['mime_type'] ?? '').toString(),
      durationMs: ((map['durationMs'] ?? map['duration_ms']) as num? ?? 0)
          .toInt(),
      sizeBytes: ((map['sizeBytes'] ?? map['size_bytes']) as num? ?? 0)
          .toInt(),
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAtMs),
      isPartial: isPartial,
      backupSynced: backupSynced,
    );
  }
}

/// Real-time event streamed from native `EventChannel('com.silentsave/call_recorder_events')`.
class CallRecorderEvent {
  final CallRecorderStatus status;
  final CallRecordingMode? mode;
  final CallAudioSource? audioSource;
  final int elapsedMs;
  final String? fileName;
  final CallRecording? recording;
  final String? errorCode;
  final String? errorMessage;
  final String? warningMessage;

  const CallRecorderEvent({
    required this.status,
    this.mode,
    this.audioSource,
    this.elapsedMs = 0,
    this.fileName,
    this.recording,
    this.errorCode,
    this.errorMessage,
    this.warningMessage,
  });

  factory CallRecorderEvent.fromMap(Map<dynamic, dynamic> map) {
    final rawRec = map['recording'];
    return CallRecorderEvent(
      status: CallRecorderStatus.fromWire(map['state']?.toString()),
      mode: map['mode'] != null
          ? CallRecordingMode.fromWire(map['mode']?.toString())
          : null,
      audioSource: map['audioSource'] != null
          ? CallAudioSource.fromWire(map['audioSource']?.toString())
          : null,
      elapsedMs: (map['elapsedMs'] as num? ?? 0).toInt(),
      fileName: map['fileName']?.toString(),
      recording: rawRec is Map ? CallRecording.fromMap(rawRec) : null,
      errorCode: map['errorCode']?.toString(),
      errorMessage: map['errorMessage']?.toString(),
      warningMessage: map['warningMessage']?.toString(),
    );
  }
}


import 'dart:async';
import 'package:flutter/services.dart';
import '../models/call_recording.dart';

/// Typed platform-channel wrapper for the Call Recorder module.
///
/// Platform Contract:
/// - MethodChannel: `com.silentsave/call_recorder`
///   - `startRecording({mode, audioSource})` -> `bool`
///   - `stopRecording()` -> `bool`
///   - `getRecordingState()` -> `Map<String, dynamic>`
///   - `listRecordings({syncWithMediaStore})` -> `List<Map<String, dynamic>>`
///   - `renameRecording({id, newDisplayName})` -> `Map<String, dynamic>`
///   - `deleteRecording({id})` -> `bool`
///   - `getReadablePath({id})` -> `String`
///   - `getStorageInfo()` -> `Map<String, dynamic>`
/// - EventChannel: `com.silentsave/call_recorder_events`
///   - Streams `Map` payloads decoded into [CallRecorderEvent]
class CallRecorderPlatformChannel {
  static const String methodChannelName = 'com.silentsave/call_recorder';
  static const String eventChannelName = 'com.silentsave/call_recorder_events';

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  Stream<CallRecorderEvent>? _cachedEventStream;

  CallRecorderPlatformChannel({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  }) : _methodChannel =
           methodChannel ?? const MethodChannel(methodChannelName),
       _eventChannel = eventChannel ?? const EventChannel(eventChannelName);

  /// Broadcast stream of recording state transitions, 1s elapsed ticks, warnings, and errors.
  Stream<CallRecorderEvent> get events {
    _cachedEventStream ??= _eventChannel.receiveBroadcastStream().map((raw) {
      if (raw is Map) {
        return CallRecorderEvent.fromMap(raw);
      }
      return const CallRecorderEvent(status: CallRecorderStatus.idle);
    });
    return _cachedEventStream!;
  }

  /// Starts a recording session.
  /// In [CallRecordingMode.video], Android opens the system screen-capture consent dialog
  /// every session (required on Android 14+).
  Future<bool> startRecording({
    required CallRecordingMode mode,
    required CallAudioSource audioSource,
  }) async {
    final ok = await _methodChannel.invokeMethod<bool>('startRecording', {
      'mode': mode.wireValue,
      'audioSource': audioSource.wireValue,
    });
    return ok ?? false;
  }

  /// Requests the foreground `CallRecorderService` to finalize and save the active recording.
  Future<bool> stopRecording() async {
    final ok = await _methodChannel.invokeMethod<bool>('stopRecording');
    return ok ?? false;
  }

  /// Queries an immediate snapshot of the native service state (used on screen init / app resume).
  Future<CallRecorderEvent> getRecordingState() async {
    final map = await _methodChannel.invokeMapMethod<String, dynamic>(
      'getRecordingState',
    );
    if (map == null) {
      return const CallRecorderEvent(status: CallRecorderStatus.idle);
    }
    return CallRecorderEvent.fromMap(map);
  }

  /// Reconciles `MediaStore` (`Movies/CallRecordings` + `Music/CallRecordings`) with SQLite
  /// and returns all saved call recordings ordered newest-first.
  Future<List<CallRecording>> listRecordings({
    bool syncWithMediaStore = true,
  }) async {
    final rawList = await _methodChannel.invokeListMethod<dynamic>(
      'listRecordings',
      {'syncWithMediaStore': syncWithMediaStore},
    );
    if (rawList == null) return const [];
    return rawList
        .whereType<Map>()
        .map(CallRecording.fromMap)
        .toList(growable: false);
  }

  /// Renames a recording in both `MediaStore` and SQLite (`call_recordings`).
  Future<CallRecording> renameRecording({
    required int id,
    required String newDisplayName,
  }) async {
    final map = await _methodChannel.invokeMapMethod<String, dynamic>(
      'renameRecording',
      {'id': id, 'newDisplayName': newDisplayName},
    );
    if (map == null) {
      throw PlatformException(
        code: 'RENAME_FAILED',
        message: 'Native rename returned null',
      );
    }
    return CallRecording.fromMap(map);
  }

  /// Deletes a recording from both `MediaStore` and SQLite (`call_recordings`).
  Future<bool> deleteRecording(int id) async {
    final ok = await _methodChannel.invokeMethod<bool>('deleteRecording', {
      'id': id,
    });
    return ok ?? false;
  }

  /// Resolves a directly readable local file path for playback or `SharePlus` sharing.
  Future<String> getReadablePath(int id) async {
    final path = await _methodChannel.invokeMethod<String>('getReadablePath', {
      'id': id,
    });
    if (path == null || path.isEmpty) {
      throw PlatformException(
        code: 'NOT_FOUND',
        message: 'Recording file could not be resolved',
      );
    }
    return path;
  }

  /// Returns free disk space bytes and minimum threshold bytes.
  Future<Map<String, int>> getStorageInfo() async {
    final map = await _methodChannel.invokeMapMethod<String, dynamic>(
      'getStorageInfo',
    );
    return {
      'availableBytes': (map?['availableBytes'] as num? ?? 0).toInt(),
      'minStartBytes': (map?['minStartBytes'] as num? ?? 0).toInt(),
    };
  }

  /// Checks whether `CallRecorderAccessibilityService` is enabled in Android Settings
  /// (required on Android 11–14 for 0-tap background voice call auto-start).
  Future<bool> isAccessibilityServiceEnabled() async {
    final ok = await _methodChannel.invokeMethod<bool>(
      'isAccessibilityServiceEnabled',
    );
    return ok ?? false;
  }

  /// Opens Android's Accessibility Settings screen so the user can toggle
  /// "SilentSave Auto Call Recorder" ON.
  Future<bool> openAccessibilitySettings() async {
    final ok = await _methodChannel.invokeMethod<bool>(
      'openAccessibilitySettings',
    );
    return ok ?? false;
  }
}


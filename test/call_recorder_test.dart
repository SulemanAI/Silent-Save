import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:silentsave/call_recorder/models/call_recording.dart';
import 'package:silentsave/call_recorder/platform/call_recorder_platform_channel.dart';
import 'package:silentsave/call_recorder/repositories/call_recording_repository.dart';
import 'package:silentsave/call_recorder/screens/call_recordings_list_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:silentsave/services/database_helper.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('CallRecording model & channel parsing', () {
    test('parses camelCase MethodChannel map accurately', () {
      final rec = CallRecording.fromMap({
        'id': 7,
        'mediaStoreId': 4021,
        'mediaUri': 'content://media/external_primary/video/media/4021',
        'filePath': '/storage/emulated/0/Movies/CallRecordings/WhatsApp_2026-11-03_14-30_video.mp4',
        'displayName': 'WhatsApp_2026-11-03_14-30_video.mp4',
        'mode': 'video',
        'audioSource': 'VOICE_RECOGNITION',
        'mimeType': 'video/mp4',
        'durationMs': 125000,
        'sizeBytes': 15728640,
        'createdAtMs': 1793716200000,
        'isPartial': false,
        'backupSynced': false,
      });

      expect(rec.id, 7);
      expect(rec.mediaStoreId, 4021);
      expect(rec.mode, CallRecordingMode.video);
      expect(rec.audioSource, CallAudioSource.voiceRecognition);
      expect(rec.duration.inSeconds, 125);
      expect(rec.isPartial, isFalse);
      expect(formatRecordingDuration(rec.duration), '02:05');
      expect(formatRecordingBytes(rec.sizeBytes), '15.0 MB');
    });

    test('parses snake_case SQLite row map accurately', () {
      final rec = CallRecording.fromMap({
        'id': 12,
        'media_store_id': 998,
        'media_uri': 'content://media/external_primary/audio/media/998',
        'file_path': '/storage/emulated/0/Music/CallRecordings/WhatsApp_2026-11-03_14-30_voice.m4a',
        'display_name': 'WhatsApp_2026-11-03_14-30_voice.m4a',
        'mode': 'voice',
        'audio_source': 'MIC',
        'mime_type': 'audio/mp4',
        'duration_ms': 3661000,
        'size_bytes': 512000,
        'created_at': 1793716200000,
        'is_partial': 1,
        'backup_synced': 1,
      });

      expect(rec.mode, CallRecordingMode.voice);
      expect(rec.audioSource, CallAudioSource.mic);
      expect(rec.isPartial, isTrue);
      expect(rec.backupSynced, isTrue);
      expect(formatRecordingDuration(rec.duration), '01:01:01');
      expect(formatRecordingBytes(rec.sizeBytes), '500.0 KB');
    });

    test('parses CallRecorderEvent error with partial recording', () {
      final evt = CallRecorderEvent.fromMap({
        'state': 'error',
        'mode': 'video',
        'audioSource': 'MIC',
        'elapsedMs': 42000,
        'errorCode': 'PROJECTION_REVOKED',
        'errorMessage': 'Screen capture stopped',
        'recording': {
          'id': 3,
          'mediaUri': 'content://media/external_primary/video/media/55',
          'displayName': 'WhatsApp_2026-11-03_14-30_video.mp4',
          'mode': 'video',
          'audioSource': 'MIC',
          'mimeType': 'video/mp4',
          'durationMs': 42000,
          'sizeBytes': 4096000,
          'createdAtMs': 1793716200000,
          'isPartial': true,
        },
      });

      expect(evt.status, CallRecorderStatus.error);
      expect(evt.errorCode, 'PROJECTION_REVOKED');
      expect(evt.recording, isNotNull);
      expect(evt.recording!.isPartial, isTrue);
    });
  });

  group('DatabaseHelper v10 call_recordings schema', () {
    test('creates call_recordings table and supports backup sync queries', () async {
      final db = await DatabaseHelper.instance.database;
      await db.delete('call_recordings');

      final id = await db.insert('call_recordings', {
        'media_store_id': 777,
        'media_uri': 'content://media/external_primary/audio/media/777',
        'file_path': '/storage/emulated/0/Music/CallRecordings/WhatsApp_2026-11-04_04-00_voice.m4a',
        'display_name': 'WhatsApp_2026-11-04_04-00_voice.m4a',
        'mode': 'voice',
        'audio_source': 'MIC',
        'mime_type': 'audio/mp4',
        'duration_ms': 60000,
        'size_bytes': 1048576,
        'created_at': 1793746800000,
        'is_partial': 0,
        'backup_synced': 0,
      });

      final all = await DatabaseHelper.instance.getCallRecordings();
      expect(all.length, 1);
      expect(await DatabaseHelper.instance.getCallRecordingsTotalBytes(), 1048576);

      final unsyncedBefore = await DatabaseHelper.instance.getUnsyncedCallRecordings();
      expect(unsyncedBefore.length, 1);

      await DatabaseHelper.instance.markCallRecordingBackupSynced(id);
      final unsyncedAfter = await DatabaseHelper.instance.getUnsyncedCallRecordings();
      expect(unsyncedAfter, isEmpty);

      await db.delete('call_recordings');
    });
  });

  group('Option 1 Auto-Record preferences & Accessibility channel', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('auto-record preference defaults to true and persists toggle', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = CallRecordingRepository.instance;

      expect(await repo.getAutoRecordEnabled(), isTrue);
      await repo.setAutoRecordEnabled(false);
      expect(await repo.getAutoRecordEnabled(), isFalse);
      await repo.setAutoRecordEnabled(true);
      expect(await repo.getAutoRecordEnabled(), isTrue);
    });

    test('Accessibility MethodChannel calls serialize cleanly', () async {
      final calls = <String>[];
      const testChannel = MethodChannel('com.silentsave/call_recorder_test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(testChannel, (MethodCall call) async {
        calls.add(call.method);
        if (call.method == 'isAccessibilityServiceEnabled') return true;
        if (call.method == 'openAccessibilitySettings') return true;
        return null;
      });

      final platform = CallRecorderPlatformChannel(methodChannel: testChannel);
      expect(await platform.isAccessibilityServiceEnabled(), isTrue);
      expect(await platform.openAccessibilitySettings(), isTrue);
      expect(calls, ['isAccessibilityServiceEnabled', 'openAccessibilitySettings']);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(testChannel, null);
    });
  });
}


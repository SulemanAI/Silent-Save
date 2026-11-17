import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/database_helper.dart';
import '../../services/notification_service.dart';
import '../models/call_recording.dart';
import '../platform/call_recorder_platform_channel.dart';

/// Repository layer for the Call Recorder feature.
///
/// Reuses existing SilentSave infrastructure:
/// - [DatabaseHelper] (`silentsave.db` `call_recordings` table) for fast local reads & backup tracking
/// - [NotificationService] for OEM battery-optimization checks and system settings intents
/// - [SharedPreferences] for first-use legal consent & preferred audio source persistence
/// - [CallRecorderPlatformChannel] for foreground recording & `MediaStore` synchronization
class CallRecordingRepository {
  static final CallRecordingRepository instance =
      CallRecordingRepository._internal();

  static const String prefKeyConsentAccepted =
      'call_recorder_consent_accepted_v1';
  static const String prefKeyAudioSource = 'call_recorder_audio_source';
  static const String prefKeyPreferredMode = 'call_recorder_preferred_mode';
  static const String prefKeyAutoRecordEnabled =
      'call_recorder_auto_record_enabled';

  final CallRecorderPlatformChannel _platform;
  final DatabaseHelper _dbHelper;
  final NotificationService _notificationService;

  CallRecordingRepository._internal({
    CallRecorderPlatformChannel? platform,
    DatabaseHelper? dbHelper,
    NotificationService? notificationService,
  }) : _platform = platform ?? CallRecorderPlatformChannel(),
       _dbHelper = dbHelper ?? DatabaseHelper.instance,
       _notificationService = notificationService ?? NotificationService.instance;

  /// Stream of live recording events from the foreground Kotlin service.
  Stream<CallRecorderEvent> get events => _platform.events;

  // ── Preferences & Legal Consent ──────────────────────────────────────

  Future<bool> hasAcceptedConsent() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(prefKeyConsentAccepted) ?? false;
  }

  Future<void> setConsentAccepted(bool accepted) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKeyConsentAccepted, accepted);
  }

  Future<CallAudioSource> getPreferredAudioSource() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(prefKeyAudioSource);
    if (raw == null) return CallAudioSource.voiceRecognition;
    return CallAudioSource.fromWire(raw);
  }

  Future<void> setPreferredAudioSource(CallAudioSource source) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefKeyAudioSource, source.wireValue);
  }

  Future<CallRecordingMode> getPreferredMode() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(prefKeyPreferredMode);
    if (raw == null) return CallRecordingMode.voice;
    return CallRecordingMode.fromWire(raw);
  }

  Future<void> setPreferredMode(CallRecordingMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefKeyPreferredMode, mode.wireValue);
  }

  Future<bool> getAutoRecordEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getBool(prefKeyAutoRecordEnabled);
    if (existing == null) {
      // Persist default true so native CallAutoRecordCoordinator sees the explicit key
      await prefs.setBool(prefKeyAutoRecordEnabled, true);
      return true;
    }
    return existing;
  }

  Future<void> setAutoRecordEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKeyAutoRecordEnabled, enabled);
  }

  Future<bool> isAccessibilityServiceEnabled() {
    return _platform.isAccessibilityServiceEnabled();
  }

  Future<bool> openAccessibilitySettings() {
    return _platform.openAccessibilitySettings();
  }

  // ── Reused OEM Battery Optimization Helpers ──────────────────────────

  Future<bool> isBatteryOptimizationExempt() {
    return _notificationService.isBatteryOptimizationExempt();
  }

  Future<void> requestBatteryOptimizationExemption() {
    return _notificationService.requestBatteryOptimizationExemption();
  }

  Future<String> getManufacturer() {
    return _notificationService.getManufacturer();
  }

  Future<void> openOemBatterySettings(String packageName) {
    return _notificationService.openOemBatterySettings(packageName);
  }

  // ── Recording Commands & MediaStore-Synced CRUD ──────────────────────

  Future<bool> startRecording({
    required CallRecordingMode mode,
    required CallAudioSource audioSource,
  }) {
    return _platform.startRecording(mode: mode, audioSource: audioSource);
  }

  Future<bool> stopRecording() {
    return _platform.stopRecording();
  }

  Future<CallRecorderEvent> getRecordingState() {
    return _platform.getRecordingState();
  }

  /// Returns SQLite cached rows quickly when [syncWithMediaStore] is false, or performs
  /// full two-way MediaStore (`Movies/CallRecordings` + `Music/CallRecordings`) <-> SQLite
  /// reconciliation when [syncWithMediaStore] is true.
  Future<List<CallRecording>> getRecordings({
    bool syncWithMediaStore = true,
  }) async {
    if (!syncWithMediaStore) {
      try {
        final rows = await _dbHelper.getCallRecordings();
        return rows.map(CallRecording.fromMap).toList(growable: false);
      } catch (e) {
        debugPrint('[CallRecordingRepository] Local SQLite read fallback: $e');
      }
    }
    return _platform.listRecordings(syncWithMediaStore: syncWithMediaStore);
  }

  Future<CallRecording> renameRecording({
    required int id,
    required String newDisplayName,
  }) {
    return _platform.renameRecording(id: id, newDisplayName: newDisplayName);
  }

  Future<bool> deleteRecording(int id) {
    return _platform.deleteRecording(id);
  }

  Future<String> getReadableFilePath(int id) {
    return _platform.getReadablePath(id);
  }

  /// Exposes unsynced recordings from SQLite for future Google Drive / SAF cloud backup.
  Future<List<CallRecording>> getUnsyncedForBackup() async {
    final rows = await _dbHelper.getUnsyncedCallRecordings();
    return rows.map(CallRecording.fromMap).toList(growable: false);
  }
}


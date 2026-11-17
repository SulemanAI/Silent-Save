import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/call_recording.dart';
import '../repositories/call_recording_repository.dart';

/// State controller (ChangeNotifier / Provider layer) for the Call Recorder UI.
///
/// Decouples widgets from platform channels, permissions, and SQLite/MediaStore sync.
class CallRecorderController extends ChangeNotifier {
  final CallRecordingRepository _repository;

  StreamSubscription<CallRecorderEvent>? _eventSubscription;

  CallRecordingMode _selectedMode = CallRecordingMode.voice;
  CallAudioSource _audioSource = CallAudioSource.mic;
  CallRecorderStatus _status = CallRecorderStatus.idle;
  int _elapsedMs = 0;
  String? _activeFileName;
  String? _errorCode;
  String? _errorMessage;
  String? _warningMessage;

  bool _consentAccepted = false;
  bool _batteryExempt = true;
  bool _autoRecordEnabled = true;
  bool _accessibilityEnabled = false;
  bool _micPermissionGranted = false;
  bool _isLoadingRecordings = true;
  List<CallRecording> _recordings = const [];

  CallRecorderController({CallRecordingRepository? repository})
    : _repository = repository ?? CallRecordingRepository.instance;

  // ── Getters ──────────────────────────────────────────────────────────

  CallRecordingMode get selectedMode => _selectedMode;
  CallAudioSource get audioSource => _audioSource;
  CallRecorderStatus get status => _status;
  bool get isRecording => _status == CallRecorderStatus.recording;
  bool get isBusy =>
      _status == CallRecorderStatus.preparing ||
      _status == CallRecorderStatus.stopping;
  int get elapsedMs => _elapsedMs;
  Duration get elapsedDuration => Duration(milliseconds: _elapsedMs);
  String? get activeFileName => _activeFileName;
  String? get errorCode => _errorCode;
  String? get errorMessage => _errorMessage;
  String? get warningMessage => _warningMessage;
  bool get consentAccepted => _consentAccepted;
  bool get batteryExempt => _batteryExempt;
  bool get autoRecordEnabled => _autoRecordEnabled;
  bool get accessibilityEnabled => _accessibilityEnabled;
  bool get micPermissionGranted => _micPermissionGranted;
  bool get isLoadingRecordings => _isLoadingRecordings;
  List<CallRecording> get recordings => _recordings;

  // ── Initialization & Lifecycle ───────────────────────────────────────

  Future<void> initialize() async {
    _consentAccepted = await _repository.hasAcceptedConsent();
    _audioSource = await _repository.getPreferredAudioSource();
    _selectedMode = await _repository.getPreferredMode();
    _autoRecordEnabled = await _repository.getAutoRecordEnabled();
    _batteryExempt = await _repository.isBatteryOptimizationExempt();
    _accessibilityEnabled = await _repository.isAccessibilityServiceEnabled();
    try {
      _micPermissionGranted = await Permission.microphone.isGranted;
    } catch (_) {}

    // Load cached SQLite rows immediately for instant UI, then reconcile MediaStore
    await _loadRecordingsInternal(syncWithMediaStore: false);
    await refreshStateAndSync();

    _eventSubscription?.cancel();
    _eventSubscription = _repository.events.listen(
      _onNativeEvent,
      onError: (Object err) {
        debugPrint('[CallRecorderController] EventChannel error: $err');
      },
    );
  }

  /// Syncs state after app resume or settings return.
  Future<void> refreshStateAndSync() async {
    try {
      _audioSource = await _repository.getPreferredAudioSource();
      _autoRecordEnabled = await _repository.getAutoRecordEnabled();
      _batteryExempt = await _repository.isBatteryOptimizationExempt();
      _accessibilityEnabled = await _repository.isAccessibilityServiceEnabled();
      try {
        _micPermissionGranted = await Permission.microphone.isGranted;
      } catch (_) {}

      final snapshot = await _repository.getRecordingState();
      if (snapshot.status == CallRecorderStatus.recording) {
        _status = CallRecorderStatus.recording;
        if (snapshot.mode != null) _selectedMode = snapshot.mode!;
        if (snapshot.audioSource != null) _audioSource = snapshot.audioSource!;
        _elapsedMs = snapshot.elapsedMs;
        _activeFileName = snapshot.fileName;
      } else if (_status.isActive) {
        _status = CallRecorderStatus.idle;
        _elapsedMs = 0;
        _activeFileName = null;
      }
      notifyListeners();
    } catch (e) {
      debugPrint('[CallRecorderController] refreshState error: $e');
    }

    await _loadRecordingsInternal(syncWithMediaStore: true);
  }

  Future<void> reloadRecordings() async {
    await _loadRecordingsInternal(syncWithMediaStore: true);
  }

  Future<void> _loadRecordingsInternal({required bool syncWithMediaStore}) async {
    if (_recordings.isEmpty) {
      _isLoadingRecordings = true;
      notifyListeners();
    }
    try {
      final list = await _repository.getRecordings(
        syncWithMediaStore: syncWithMediaStore,
      );
      _recordings = list;
    } catch (e) {
      debugPrint('[CallRecorderController] loadRecordings error: $e');
    } finally {
      _isLoadingRecordings = false;
      notifyListeners();
    }
  }

  void _onNativeEvent(CallRecorderEvent event) {
    _status = event.status;
    if (event.mode != null && event.status.isActive) {
      _selectedMode = event.mode!;
    }
    _elapsedMs = event.elapsedMs;
    _activeFileName = event.fileName;
    _warningMessage = event.warningMessage;

    if (event.status == CallRecorderStatus.error) {
      _errorCode = event.errorCode;
      _errorMessage = event.errorMessage ?? 'Recording failed.';
      // If a partial recording was salvaged (e.g. MediaProjection revoked / low storage), reload list
      if (event.recording != null) {
        unawaited(_loadRecordingsInternal(syncWithMediaStore: true));
      }
    } else if (event.status == CallRecorderStatus.completed) {
      _errorCode = null;
      _errorMessage = null;
      _warningMessage = null;
      _status = CallRecorderStatus.idle;
      _elapsedMs = 0;
      _activeFileName = null;
      unawaited(_loadRecordingsInternal(syncWithMediaStore: true));
    } else if (event.status == CallRecorderStatus.recording) {
      _errorCode = null;
      _errorMessage = null;
    }

    notifyListeners();
  }

  // ── User Actions ─────────────────────────────────────────────────────

  Future<void> selectMode(CallRecordingMode mode) async {
    if (_status.isActive) return; // Cannot switch mode mid-recording
    _selectedMode = mode;
    _errorMessage = null;
    notifyListeners();
    await _repository.setPreferredMode(mode);
  }

  Future<void> selectAudioSource(CallAudioSource source) async {
    if (_status.isActive) return;
    _audioSource = source;
    notifyListeners();
    await _repository.setPreferredAudioSource(source);
  }

  Future<void> acceptConsent() async {
    _consentAccepted = true;
    await _repository.setConsentAccepted(true);
    notifyListeners();
  }

  void clearError() {
    _errorCode = null;
    _errorMessage = null;
    notifyListeners();
  }

  Future<void> requestBatteryExemption() async {
    await _repository.requestBatteryOptimizationExemption();
    await Future.delayed(const Duration(seconds: 1));
    _batteryExempt = await _repository.isBatteryOptimizationExempt();
    notifyListeners();
  }

  Future<void> setAutoRecordEnabled(bool enabled) async {
    _autoRecordEnabled = enabled;
    notifyListeners();
    await _repository.setAutoRecordEnabled(enabled);
    if (enabled && !_micPermissionGranted) {
      await ensureMicrophonePermission();
    }
  }

  Future<bool> ensureMicrophonePermission() async {
    try {
      final micStatus = await Permission.microphone.request();
      _micPermissionGranted = micStatus.isGranted;
      final notifStatus = await Permission.notification.status;
      if (notifStatus.isDenied) {
        await Permission.notification.request();
      }
      notifyListeners();
      return _micPermissionGranted;
    } catch (_) {
      return false;
    }
  }

  Future<void> openAccessibilitySettings() async {
    if (!_micPermissionGranted) {
      await ensureMicrophonePermission();
    }
    await _repository.openAccessibilitySettings();
  }

  /// Checks runtime permissions (`RECORD_AUDIO`, `POST_NOTIFICATIONS`) and starts recording.
  /// Returns `true` if started, `false` if blocked by permissions or cancelled.
  Future<bool> startRecording() async {
    if (_status.isActive) return false;
    _errorCode = null;
    _errorMessage = null;
    _warningMessage = null;

    // 1. Microphone permission (mandatory for both voice and video call modes)
    final micStatus = await Permission.microphone.request();
    _micPermissionGranted = micStatus.isGranted;
    if (!micStatus.isGranted) {
      _status = CallRecorderStatus.error;
      _errorCode = 'PERMISSION_DENIED';
      _errorMessage = micStatus.isPermanentlyDenied
          ? 'Microphone permission is permanently denied. Enable it in App Settings to record calls.'
          : 'Microphone permission is required to record calls.';
      notifyListeners();
      return false;
    }

    // 2. Notification permission on Android 13+ so the persistent Stop button is visible
    try {
      final notifStatus = await Permission.notification.status;
      if (notifStatus.isDenied) {
        await Permission.notification.request();
      }
    } catch (_) {}

    _status = CallRecorderStatus.preparing;
    notifyListeners();

    try {
      final ok = await _repository.startRecording(
        mode: _selectedMode,
        audioSource: _audioSource,
      );
      if (!ok && _status == CallRecorderStatus.preparing) {
        _status = CallRecorderStatus.idle;
        notifyListeners();
      }
      return ok;
    } on PlatformException catch (e) {
      _status = CallRecorderStatus.error;
      _errorCode = e.code;
      _errorMessage = e.message ?? 'Could not start call recording.';
      notifyListeners();
      return false;
    } catch (e) {
      _status = CallRecorderStatus.error;
      _errorCode = 'RECORDER_ERROR';
      _errorMessage = 'Unexpected error starting recorder: $e';
      notifyListeners();
      return false;
    }
  }

  Future<void> stopRecording() async {
    if (!_status.isActive) return;
    _status = CallRecorderStatus.stopping;
    notifyListeners();
    try {
      await _repository.stopRecording();
    } catch (e) {
      _status = CallRecorderStatus.error;
      _errorMessage = 'Failed to stop recording: $e';
      notifyListeners();
    }
  }

  Future<CallRecording?> renameRecording(int id, String newName) async {
    final updated = await _repository.renameRecording(
      id: id,
      newDisplayName: newName,
    );
    _recordings = _recordings
        .map((r) => r.id == id ? updated : r)
        .toList(growable: false);
    notifyListeners();
    return updated;
  }

  Future<bool> deleteRecording(int id) async {
    final ok = await _repository.deleteRecording(id);
    if (ok) {
      _recordings = _recordings.where((r) => r.id != id).toList(growable: false);
      notifyListeners();
    }
    return ok;
  }

  Future<String> getReadableFilePath(int id) {
    return _repository.getReadableFilePath(id);
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    super.dispose();
  }
}


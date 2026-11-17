import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../controller/call_recorder_controller.dart';
import '../models/call_recording.dart';
import 'call_recordings_list_screen.dart';

/// Main Call Recorder tab / screen.
///
/// Features:
/// 1. Video Call (`MediaProjection` screen + mic -> MP4) & Voice Call (mic -> M4A/AAC) modes
/// 2. Prominent Speakerphone reminder when in Voice Call mode
/// 3. Audio source selector (`MIC`, `VOICE_RECOGNITION`, `VOICE_COMMUNICATION`)
/// 4. First-use consent dialog ("Make sure everyone on the call agrees to be recorded where required by law.")
/// 5. Big animated Start/Stop button with live elapsed timer & foreground status
/// 6. Reuses SilentSave's battery-optimization check & links to the full Recordings list screen
class CallRecorderScreen extends StatefulWidget {
  const CallRecorderScreen({super.key});

  @override
  State<CallRecorderScreen> createState() => _CallRecorderScreenState();
}

class _CallRecorderScreenState extends State<CallRecorderScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final CallRecorderController _controller;
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = CallRecorderController();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
    _controller.initialize();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulseController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _controller.refreshStateAndSync();
    }
  }

  Future<bool> _ensureConsentDialog({bool forceShow = false}) async {
    if (_controller.consentAccepted && !forceShow) return true;

    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: forceShow,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.gavel_rounded, color: Colors.amberAccent),
            SizedBox(width: 10),
            Expanded(child: Text('Call Recording Consent')),
          ],
        ),
        content: const Text(
          'Make sure everyone on the call agrees to be recorded where required by law.',
          style: TextStyle(fontSize: 15, height: 1.4),
        ),
        actions: [
          if (!forceShow)
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(forceShow ? 'Got It' : 'I Agree'),
          ),
        ],
      ),
    );

    if (accepted == true && !_controller.consentAccepted) {
      await _controller.acceptConsent();
    }
    return accepted == true || _controller.consentAccepted;
  }

  Future<void> _onStartStopPressed() async {
    if (_controller.isBusy) return;

    if (_controller.isRecording) {
      await _controller.stopRecording();
      return;
    }

    final consented = await _ensureConsentDialog();
    if (!consented || !mounted) return;

    await _controller.startRecording();
  }

  void _openRecordingsScreen() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CallRecordingsListScreen(controller: _controller),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.grey.shade900, Colors.black],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
            children: [
              _buildHeaderRow(),
              const SizedBox(height: 12),
              _buildAutoRecordCard(),
              const SizedBox(height: 12),
              if (!_controller.batteryExempt) ...[
                _buildBatteryBanner(),
                const SizedBox(height: 12),
              ],
              _buildModeSelector(),
              const SizedBox(height: 12),
              if (_controller.selectedMode == CallRecordingMode.voice) ...[
                _buildSpeakerphoneReminder(),
                const SizedBox(height: 12),
              ],
              _buildAudioSourceSelector(),
              if (_controller.warningMessage != null) ...[
                const SizedBox(height: 12),
                _buildWarningBanner(_controller.warningMessage!),
              ],
              if (_controller.errorMessage != null) ...[
                const SizedBox(height: 12),
                _buildErrorBanner(),
              ],
              const SizedBox(height: 22),
              _buildBigStartStopSection(),
              const SizedBox(height: 24),
              _buildRecentRecordingsSection(),
            ],
          );
        },
      ),
    );
  }

  Widget _buildHeaderRow() {
    return Row(
      children: [
        const Icon(Icons.phone_in_talk, color: Colors.tealAccent, size: 22),
        const SizedBox(width: 8),
        const Expanded(
          child: Text(
            'WhatsApp Call Recorder',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ),
        IconButton(
          tooltip: 'Consent Notice',
          icon: const Icon(Icons.info_outline, size: 20, color: Colors.white70),
          onPressed: () => _ensureConsentDialog(forceShow: true),
        ),
        FilledButton.tonalIcon(
          onPressed: _openRecordingsScreen,
          icon: const Icon(Icons.folder_special_outlined, size: 18),
          label: Text('Recordings (${_controller.recordings.length})'),
        ),
      ],
    );
  }

  Widget _buildAutoRecordCard() {
    final autoOn = _controller.autoRecordEnabled;
    final a11yReady = _controller.accessibilityEnabled;
    final micReady = _controller.micPermissionGranted;
    final fullyReady = autoOn && a11yReady && micReady;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.grey.shade800.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: fullyReady
              ? Colors.greenAccent.withValues(alpha: 0.45)
              : autoOn
              ? Colors.amberAccent.withValues(alpha: 0.45)
              : Colors.white12,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.autorenew_rounded,
                color: autoOn ? Colors.tealAccent : Colors.grey,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Auto-Record WhatsApp Calls',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14.5,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Voice calls start & stop with 0 taps. Video calls pop up a 1-tap prompt & auto-stop when you hang up.',
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.3,
                        color: Colors.grey.shade400,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: autoOn,
                activeThumbColor: Colors.tealAccent,
                onChanged: (enabled) async {
                  if (enabled) {
                    final consented = await _ensureConsentDialog();
                    if (!consented || !mounted) return;
                  }
                  await _controller.setAutoRecordEnabled(enabled);
                },
              ),
            ],
          ),
          if (autoOn) ...[
            const SizedBox(height: 10),
            if (!micReady)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.mic_off, size: 18, color: Colors.redAccent),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Grant Microphone permission so background auto-record can capture audio.',
                        style: TextStyle(fontSize: 12, color: Colors.white),
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        final consented = await _ensureConsentDialog();
                        if (!consented || !mounted) return;
                        await _controller.ensureMicrophonePermission();
                      },
                      child: const Text('Grant'),
                    ),
                  ],
                ),
              ),
            if (!a11yReady)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.accessibility_new_rounded,
                      size: 18,
                      color: Colors.amberAccent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Enable "SilentSave Auto Call Recorder" in Accessibility Settings for 0-tap background voice recording.',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.3,
                          color: Colors.grey.shade200,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    FilledButton.tonal(
                      onPressed: () async {
                        final consented = await _ensureConsentDialog();
                        if (!consented || !mounted) return;
                        await _controller.openAccessibilitySettings();
                      },
                      child: const Text('Enable'),
                    ),
                  ],
                ),
              )
            else if (micReady)
              Row(
                children: [
                  const Icon(
                    Icons.verified_rounded,
                    size: 16,
                    color: Colors.greenAccent,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Zero-Tap Auto-Record Ready (Accessibility Active)',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.greenAccent.shade200,
                    ),
                  ),
                ],
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildBatteryBanner() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.battery_alert, color: Colors.orangeAccent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Disable battery optimization so Android does not stop long call recordings in the background.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade200),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: _controller.requestBatteryExemption,
            child: const Text('Exempt'),
          ),
        ],
      ),
    );
  }

  Widget _buildModeSelector() {
    final locked = _controller.status.isActive;
    return Opacity(
      opacity: locked ? 0.65 : 1.0,
      child: Row(
        children: [
          Expanded(
            child: _ModeOptionCard(
              title: 'Voice Call',
              subtitle: 'Mic -> M4A/AAC',
              icon: Icons.mic_rounded,
              accent: Colors.tealAccent,
              selected: _controller.selectedMode == CallRecordingMode.voice,
              onTap: locked
                  ? null
                  : () => _controller.selectMode(CallRecordingMode.voice),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _ModeOptionCard(
              title: 'Video Call',
              subtitle: 'Screen + Mic -> MP4',
              icon: Icons.videocam_rounded,
              accent: Colors.lightBlueAccent,
              selected: _controller.selectedMode == CallRecordingMode.video,
              onTap: locked
                  ? null
                  : () => _controller.selectMode(CallRecordingMode.video),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSpeakerphoneReminder() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: Colors.teal.shade900.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.tealAccent.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          const Icon(Icons.volume_up_rounded, color: Colors.tealAccent),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Tip: Enable Speaker mode during your WhatsApp voice call so the other person\'s voice clearly reaches your microphone.',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.35,
                color: Colors.grey.shade200,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAudioSourceSelector() {
    final locked = _controller.status.isActive;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.grey.shade800.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.settings_voice_rounded,
                size: 20,
                color: Colors.deepPurpleAccent,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Audio Source',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
              DropdownButton<CallAudioSource>(
                value: _controller.audioSource,
                dropdownColor: Colors.grey.shade900,
                underline: const SizedBox.shrink(),
                onChanged: locked
                    ? null
                    : (val) {
                        if (val != null) _controller.selectAudioSource(val);
                      },
                items: CallAudioSource.values.map((src) {
                  return DropdownMenuItem(
                    value: src,
                    child: Text(
                      src.wireValue,
                      style: const TextStyle(fontSize: 13),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
          Text(
            _controller.audioSource.description,
            style: TextStyle(fontSize: 11.5, color: Colors.grey.shade400),
          ),
        ],
      ),
    );
  }

  Widget _buildWarningBanner(String warning) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.amber.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.amberAccent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              warning,
              style: const TextStyle(fontSize: 12.5, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner() {
    final isPermDenied = _controller.errorCode == 'PERMISSION_DENIED';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.65)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.redAccent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _controller.errorMessage ?? 'Recording error',
              style: const TextStyle(fontSize: 12.5, color: Colors.white),
            ),
          ),
          if (isPermDenied)
            TextButton(
              onPressed: openAppSettings,
              child: const Text('Settings'),
            )
          else
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: _controller.clearError,
            ),
        ],
      ),
    );
  }

  Widget _buildBigStartStopSection() {
    final isRec = _controller.isRecording;
    final isBusy = _controller.isBusy;
    final accentColor = isRec
        ? Colors.redAccent
        : (_controller.selectedMode == CallRecordingMode.video
              ? Colors.lightBlueAccent
              : Colors.tealAccent);

    return Column(
      children: [
        // Timer & status pill
        Text(
          formatRecordingDuration(_controller.elapsedDuration),
          style: TextStyle(
            fontSize: 40,
            fontWeight: FontWeight.w700,
            letterSpacing: 2,
            fontFeatures: const [FontFeature.tabularFigures()],
            color: isRec ? Colors.redAccent : Colors.white70,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          isRec
              ? 'Recording -> ${_controller.activeFileName ?? _controller.selectedMode.mediaStoreFolder}'
              : isBusy
              ? (_controller.status == CallRecorderStatus.preparing
                    ? 'Preparing recorder...'
                    : 'Saving to MediaStore...')
              : 'Saves to ${_controller.selectedMode.mediaStoreFolder}',
          style: TextStyle(fontSize: 12.5, color: Colors.grey.shade400),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 22),

        // Big Start / Stop button
        Center(
          child: AnimatedBuilder(
            animation: _pulseController,
            builder: (context, child) {
              final glowSpread = isRec ? 6.0 + (_pulseController.value * 14.0) : 2.0;
              return GestureDetector(
                onTap: isBusy ? null : _onStartStopPressed,
                child: Container(
                  width: 148,
                  height: 148,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: isRec
                          ? [Colors.red.shade600, Colors.red.shade900]
                          : [
                              accentColor.withValues(alpha: 0.85),
                              Colors.deepPurple.shade800,
                            ],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: accentColor.withValues(alpha: isRec ? 0.5 : 0.25),
                        blurRadius: 24,
                        spreadRadius: glowSpread,
                      ),
                    ],
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.25),
                      width: 2.5,
                    ),
                  ),
                  child: child,
                ),
              );
            },
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (isBusy)
                  const SizedBox(
                    width: 34,
                    height: 34,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 3,
                    ),
                  )
                else
                  Icon(
                    isRec
                        ? Icons.stop_rounded
                        : (_controller.selectedMode == CallRecordingMode.video
                              ? Icons.videocam_rounded
                              : Icons.mic_rounded),
                    size: 52,
                    color: Colors.white,
                  ),
                const SizedBox(height: 6),
                Text(
                  isRec
                      ? 'STOP'
                      : (isBusy ? 'WAIT' : 'START'),
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRecentRecordingsSection() {
    final recent = _controller.recordings.take(3).toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'Recent Recordings',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            TextButton(
              onPressed: _openRecordingsScreen,
              child: const Text('See All'),
            ),
          ],
        ),
        if (recent.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.grey.shade900.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade800),
            ),
            child: Text(
              'No recordings saved yet. Tap START before or during a WhatsApp call.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: Colors.grey.shade500),
            ),
          )
        else
          ...recent.map(
            (rec) => Card(
              margin: const EdgeInsets.only(bottom: 6),
              color: Colors.grey.shade900.withValues(alpha: 0.8),
              child: ListTile(
                dense: true,
                leading: Icon(
                  rec.mode == CallRecordingMode.video
                      ? Icons.videocam
                      : Icons.mic,
                  color: rec.mode == CallRecordingMode.video
                      ? Colors.lightBlueAccent
                      : Colors.tealAccent,
                ),
                title: Text(
                  rec.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${formatRecordingDate(rec.createdAt)} • ${formatRecordingDuration(rec.duration)} • ${formatRecordingBytes(rec.sizeBytes)}',
                  style: TextStyle(fontSize: 11.5, color: Colors.grey.shade400),
                ),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: _openRecordingsScreen,
              ),
            ),
          ),
      ],
    );
  }
}

class _ModeOptionCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color accent;
  final bool selected;
  final VoidCallback? onTap;

  const _ModeOptionCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accent,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          color: selected
              ? accent.withValues(alpha: 0.16)
              : Colors.grey.shade800.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? accent : Colors.grey.shade700,
            width: selected ? 1.8 : 1.0,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: selected ? accent : Colors.grey.shade400),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: selected ? Colors.white : Colors.grey.shade300,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}


import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';
import '../controller/call_recorder_controller.dart';
import '../models/call_recording.dart';

/// Full Call Recordings list screen:
/// - Lists recordings synced between `silentsave.db` (`call_recordings`) and `MediaStore`
/// - Shows date, duration, and file size
/// - Supports Play (inline M4A audio bar + full-screen MP4 video player), Share, Rename, and Delete
class CallRecordingsListScreen extends StatefulWidget {
  final CallRecorderController controller;

  const CallRecordingsListScreen({super.key, required this.controller});

  @override
  State<CallRecordingsListScreen> createState() =>
      _CallRecordingsListScreenState();
}

class _CallRecordingsListScreenState extends State<CallRecordingsListScreen> {
  final TextEditingController _searchController = TextEditingController();
  final AudioPlayer _audioPlayer = AudioPlayer();

  CallRecordingMode? _modeFilter; // null = All
  String _searchQuery = '';

  // Inline voice playback state
  int? _playingRecordingId;
  String? _playingTitle;
  bool _isAudioPlaying = false;
  Duration _audioPosition = Duration.zero;
  Duration _audioDuration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _audioPlayer.onDurationChanged.listen((d) {
      if (mounted) setState(() => _audioDuration = d);
    });
    _audioPlayer.onPositionChanged.listen((p) {
      if (mounted) setState(() => _audioPosition = p);
    });
    _audioPlayer.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _isAudioPlaying = s == PlayerState.playing);
    });
    _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _isAudioPlaying = false;
          _audioPosition = Duration.zero;
        });
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  List<CallRecording> _filtered(List<CallRecording> all) {
    return all.where((rec) {
      if (_modeFilter != null && rec.mode != _modeFilter) return false;
      if (_searchQuery.isNotEmpty &&
          !rec.displayName.toLowerCase().contains(_searchQuery.toLowerCase())) {
        return false;
      }
      return true;
    }).toList(growable: false);
  }

  Future<void> _playRecording(CallRecording rec) async {
    try {
      final path = await widget.controller.getReadableFilePath(rec.id);
      if (!mounted) return;

      if (rec.mode == CallRecordingMode.video) {
        await _audioPlayer.pause();
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => CallVideoPlayerScreen(
              videoPath: path,
              title: rec.displayName,
            ),
          ),
        );
      } else {
        if (_playingRecordingId == rec.id) {
          if (_isAudioPlaying) {
            await _audioPlayer.pause();
          } else {
            await _audioPlayer.resume();
          }
          return;
        }
        await _audioPlayer.stop();
        setState(() {
          _playingRecordingId = rec.id;
          _playingTitle = rec.displayName;
          _audioPosition = Duration.zero;
          _audioDuration = rec.duration;
        });
        await _audioPlayer.play(DeviceFileSource(path));
      }
    } catch (e) {
      _showSnack('Playback error: $e', isError: true);
    }
  }

  Future<void> _shareRecording(CallRecording rec) async {
    try {
      final path = await widget.controller.getReadableFilePath(rec.id);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(path, mimeType: rec.mimeType)],
          subject: rec.displayName,
        ),
      );
    } catch (e) {
      _showSnack('Unable to share recording: $e', isError: true);
    }
  }

  Future<void> _renameRecording(CallRecording rec) async {
    final extSuffix = '.${rec.mode == CallRecordingMode.video ? 'mp4' : 'm4a'}';
    final stem = rec.displayName.toLowerCase().endsWith(extSuffix)
        ? rec.displayName.substring(0, rec.displayName.length - extSuffix.length)
        : rec.displayName;

    final nameController = TextEditingController(text: stem);
    final submitted = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Recording'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'File name',
            suffixText: extSuffix,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, nameController.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );

    if (submitted == null || submitted.isEmpty || submitted == stem) return;

    try {
      final updated = await widget.controller.renameRecording(rec.id, submitted);
      if (updated != null && _playingRecordingId == rec.id) {
        setState(() => _playingTitle = updated.displayName);
      }
      _showSnack('Renamed to ${updated?.displayName ?? submitted}');
    } catch (e) {
      _showSnack('Rename failed: $e', isError: true);
    }
  }

  Future<void> _deleteRecording(CallRecording rec) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Recording?'),
        content: Text(
          'Permanently delete "${rec.displayName}" from your device and MediaStore?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      if (_playingRecordingId == rec.id) {
        await _audioPlayer.stop();
        setState(() {
          _playingRecordingId = null;
          _playingTitle = null;
          _isAudioPlaying = false;
        });
      }
      final ok = await widget.controller.deleteRecording(rec.id);
      if (ok) {
        _showSnack('Recording deleted');
      } else {
        _showSnack('Could not delete recording', isError: true);
      }
    } catch (e) {
      _showSnack('Delete failed: $e', isError: true);
    }
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.red.shade800 : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Call Recordings',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.deepPurple.shade800,
        actions: [
          IconButton(
            tooltip: 'Sync with MediaStore',
            icon: const Icon(Icons.sync),
            onPressed: () => widget.controller.reloadRecordings(),
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.grey.shade900, Colors.black],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) {
            final items = _filtered(widget.controller.recordings);
            return Column(
              children: [
                _buildSearchAndFilters(),
                Expanded(
                  child: widget.controller.isLoadingRecordings
                      ? const Center(child: CircularProgressIndicator())
                      : items.isEmpty
                      ? _buildEmptyState()
                      : RefreshIndicator(
                          onRefresh: widget.controller.reloadRecordings,
                          child: ListView.builder(
                            padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                            itemCount: items.length,
                            itemBuilder: (ctx, idx) =>
                                _buildRecordingCard(items[idx]),
                          ),
                        ),
                ),
                if (_playingRecordingId != null) _buildInlineAudioBar(),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildSearchAndFilters() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Column(
        children: [
          TextField(
            controller: _searchController,
            onChanged: (v) => setState(() => _searchQuery = v.trim()),
            decoration: InputDecoration(
              hintText: 'Search call recordings...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              filled: true,
              fillColor: Colors.grey.shade800.withValues(alpha: 0.6),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 0),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              ChoiceChip(
                label: const Text('All'),
                selected: _modeFilter == null,
                onSelected: (_) => setState(() => _modeFilter = null),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                avatar: const Icon(Icons.videocam, size: 16),
                label: const Text('Video (MP4)'),
                selected: _modeFilter == CallRecordingMode.video,
                onSelected: (_) =>
                    setState(() => _modeFilter = CallRecordingMode.video),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                avatar: const Icon(Icons.mic, size: 16),
                label: const Text('Voice (M4A)'),
                selected: _modeFilter == CallRecordingMode.voice,
                onSelected: (_) =>
                    setState(() => _modeFilter = CallRecordingMode.voice),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRecordingCard(CallRecording rec) {
    final isVideo = rec.mode == CallRecordingMode.video;
    final isPlayingThis = _playingRecordingId == rec.id && _isAudioPlaying;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      color: Colors.grey.shade900.withValues(alpha: 0.85),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: isPlayingThis
              ? Colors.deepPurpleAccent
              : Colors.grey.shade800.withValues(alpha: 0.7),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _playRecording(rec),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: (isVideo ? Colors.blue : Colors.teal).withValues(
                    alpha: 0.18,
                  ),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isVideo
                      ? Icons.play_circle_fill
                      : (isPlayingThis ? Icons.pause_rounded : Icons.mic),
                  color: isVideo ? Colors.lightBlueAccent : Colors.tealAccent,
                  size: 26,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      rec.displayName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: Colors.white,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          formatRecordingDate(rec.createdAt),
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade400,
                          ),
                        ),
                        Text('•', style: TextStyle(color: Colors.grey.shade600)),
                        Text(
                          formatRecordingDuration(rec.duration),
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade300,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text('•', style: TextStyle(color: Colors.grey.shade600)),
                        Text(
                          formatRecordingBytes(rec.sizeBytes),
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade400,
                          ),
                        ),
                        if (rec.isPartial)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.orange.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: Colors.orange.withValues(alpha: 0.6),
                              ),
                            ),
                            child: const Text(
                              'Partial',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.orangeAccent,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Share',
                icon: const Icon(Icons.share_outlined, size: 20),
                onPressed: () => _shareRecording(rec),
              ),
              PopupMenuButton<String>(
                onSelected: (action) {
                  switch (action) {
                    case 'play':
                      _playRecording(rec);
                      break;
                    case 'share':
                      _shareRecording(rec);
                      break;
                    case 'rename':
                      _renameRecording(rec);
                      break;
                    case 'delete':
                      _deleteRecording(rec);
                      break;
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'play',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.play_arrow),
                      title: Text('Play'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'rename',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.drive_file_rename_outline),
                      title: Text('Rename'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'share',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.share),
                      title: Text('Share'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.delete_outline, color: Colors.red),
                      title: Text(
                        'Delete',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInlineAudioBar() {
    final maxMs = _audioDuration.inMilliseconds
        .toDouble()
        .clamp(1.0, double.infinity);
    final posMs = _audioPosition.inMilliseconds.toDouble().clamp(0.0, maxMs);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        border: Border(
          top: BorderSide(color: Colors.deepPurple.shade400, width: 1),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  icon: Icon(
                    _isAudioPlaying
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_fill,
                    size: 36,
                    color: Colors.tealAccent,
                  ),
                  onPressed: () {
                    if (_isAudioPlaying) {
                      _audioPlayer.pause();
                    } else {
                      _audioPlayer.resume();
                    }
                  },
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _playingTitle ?? 'Playing voice call',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () async {
                    await _audioPlayer.stop();
                    setState(() {
                      _playingRecordingId = null;
                      _playingTitle = null;
                      _isAudioPlaying = false;
                    });
                  },
                ),
              ],
            ),
            Row(
              children: [
                Text(
                  formatRecordingDuration(_audioPosition),
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                ),
                Expanded(
                  child: Slider(
                    value: posMs,
                    min: 0,
                    max: maxMs,
                    activeColor: Colors.tealAccent,
                    onChanged: (v) {
                      _audioPlayer.seek(Duration(milliseconds: v.toInt()));
                    },
                  ),
                ),
                Text(
                  formatRecordingDuration(_audioDuration),
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.voicemail_rounded,
              size: 64,
              color: Colors.grey.shade700,
            ),
            const SizedBox(height: 16),
            Text(
              'No call recordings found',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade400,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Video calls save to Movies/CallRecordings and voice calls save to Music/CallRecordings.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen MP4 player for recorded WhatsApp video calls.
class CallVideoPlayerScreen extends StatefulWidget {
  final String videoPath;
  final String title;

  const CallVideoPlayerScreen({
    super.key,
    required this.videoPath,
    required this.title,
  });

  @override
  State<CallVideoPlayerScreen> createState() => _CallVideoPlayerScreenState();
}

class _CallVideoPlayerScreenState extends State<CallVideoPlayerScreen> {
  late final VideoPlayerController _videoController;
  bool _initialized = false;
  String? _initError;

  @override
  void initState() {
    super.initState();
    _videoController = VideoPlayerController.file(File(widget.videoPath))
      ..initialize()
          .then((_) {
            if (!mounted) return;
            setState(() => _initialized = true);
            _videoController.play();
          })
          .catchError((Object e) {
            if (!mounted) return;
            setState(() => _initError = e.toString());
          });
    _videoController.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _videoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pos = _videoController.value.position;
    final dur = _videoController.value.duration;
    final maxMs = dur.inMilliseconds.toDouble().clamp(1.0, double.infinity);
    final posMs = pos.inMilliseconds.toDouble().clamp(0.0, maxMs);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black87,
        title: Text(widget.title, style: const TextStyle(fontSize: 14)),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: () {
              SharePlus.instance.share(
                ShareParams(files: [XFile(widget.videoPath)]),
              );
            },
          ),
        ],
      ),
      body: _initError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Failed to load video: $_initError',
                  style: const TextStyle(color: Colors.redAccent),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : !_initialized
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: _videoController.value.aspectRatio,
                      child: VideoPlayer(_videoController),
                    ),
                  ),
                ),
                Container(
                  color: Colors.grey.shade900,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                  child: SafeArea(
                    top: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Text(
                              formatRecordingDuration(pos),
                              style: const TextStyle(fontSize: 12),
                            ),
                            Expanded(
                              child: Slider(
                                value: posMs,
                                min: 0,
                                max: maxMs,
                                onChanged: (v) {
                                  _videoController.seekTo(
                                    Duration(milliseconds: v.toInt()),
                                  );
                                },
                              ),
                            ),
                            Text(
                              formatRecordingDuration(dur),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                        IconButton(
                          iconSize: 48,
                          icon: Icon(
                            _videoController.value.isPlaying
                                ? Icons.pause_circle_filled
                                : Icons.play_circle_fill,
                          ),
                          onPressed: () {
                            if (_videoController.value.isPlaying) {
                              _videoController.pause();
                            } else {
                              _videoController.play();
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

String formatRecordingDuration(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final hours = d.inHours;
  final minutes = two(d.inMinutes.remainder(60));
  final seconds = two(d.inSeconds.remainder(60));
  if (hours > 0) {
    return '${two(hours)}:$minutes:$seconds';
  }
  return '$minutes:$seconds';
}

String formatRecordingBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String formatRecordingDate(DateTime dt) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final recDay = DateTime(dt.year, dt.month, dt.day);
  final diffDays = today.difference(recDay).inDays;

  if (diffDays == 0) {
    return 'Today ${DateFormat('HH:mm').format(dt)}';
  } else if (diffDays == 1) {
    return 'Yesterday ${DateFormat('HH:mm').format(dt)}';
  }
  return DateFormat('yyyy-MM-dd HH:mm').format(dt);
}


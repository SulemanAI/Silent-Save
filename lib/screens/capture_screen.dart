import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';
import 'package:audioplayers/audioplayers.dart';
import '../services/notification_service.dart';
import 'trash_screen.dart';

/// Screen that displays all silently captured photos, videos, and audio recordings.
/// Provides playback, sharing, and deletion functionality.
class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> with SingleTickerProviderStateMixin {
  List<Map<String, dynamic>> _allMedia = [];
  bool _isLoading = true;
  bool _hasCameraPermission = false;
  bool _hasAudioPermission = false;
  bool _isRecordingVideo = false;
  bool _isRecordingAudio = false;
  late TabController _mediaTabController;

  // Audio player
  final AudioPlayer _audioPlayer = AudioPlayer();
  String? _currentlyPlayingAudioPath;
  bool _isAudioPlaying = false;

  final Set<String> _selectedMediaPaths = {};
  bool get _isSelectionMode => _selectedMediaPaths.isNotEmpty;

  void _toggleSelection(String path) {
    setState(() {
      if (_selectedMediaPaths.contains(path)) {
        _selectedMediaPaths.remove(path);
      } else {
        _selectedMediaPaths.add(path);
      }
    });
  }

  Future<void> _deleteSelected() async {
    final paths = _selectedMediaPaths.toList();
    if (paths.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Selected?'),
        content: Text('Are you sure you want to delete ${paths.length} items? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      for (final path in paths) {
        await NotificationService.instance.deleteCapturedMedia(path);
      }
      setState(() => _selectedMediaPaths.clear());
      _loadData();
    }
  }

  Future<void> _shareSelected() async {
    final paths = _selectedMediaPaths.toList();
    if (paths.isEmpty) return;

    try {
      final xFiles = paths.map((path) => XFile(path)).toList();
      await SharePlus.instance.share(ShareParams(files: xFiles));
      setState(() => _selectedMediaPaths.clear());
    } catch (e) {
      debugPrint('Share error: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    _mediaTabController = TabController(length: 3, vsync: this);
    _loadData();
    _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _isAudioPlaying = false;
          _currentlyPlayingAudioPath = null;
        });
      }
    });
  }

  @override
  void dispose() {
    _mediaTabController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    
    final results = await Future.wait([
      NotificationService.instance.getCapturedMedia(),
      NotificationService.instance.hasCameraPermission(),
      NotificationService.instance.hasAudioPermission(),
      NotificationService.instance.getCaptureStatus(),
    ]);

    if (mounted) {
      setState(() {
        _allMedia = results[0] as List<Map<String, dynamic>>;
        _hasCameraPermission = results[1] as bool;
        _hasAudioPermission = results[2] as bool;
        final status = results[3] as Map<String, dynamic>;
        _isRecordingVideo = status['isRecordingVideo'] == true;
        _isRecordingAudio = status['isRecordingAudio'] == true;
        _isLoading = false;
      });
    }
  }

  List<Map<String, dynamic>> _getFilteredMedia(String type) {
    return _allMedia.where((m) => m['type'] == type).toList();
  }

  Future<void> _requestCameraPermission() async {
    final status = await Permission.camera.request();
    if (status.isGranted) {
      setState(() => _hasCameraPermission = true);
    }
  }

  Future<void> _requestAudioPermission() async {
    final status = await Permission.microphone.request();
    if (status.isGranted) {
      setState(() => _hasAudioPermission = true);
    }
  }

  Future<void> _capturePhoto() async {
    if (!_hasCameraPermission) {
      await _requestCameraPermission();
      if (!_hasCameraPermission) return;
    }
    
    await NotificationService.instance.capturePhoto();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('📷 Capturing photo...'),
          duration: Duration(seconds: 2),
        ),
      );
    }
    
    // Reload after a delay to show the new capture
    Future.delayed(const Duration(seconds: 3), _loadData);
  }

  Future<void> _toggleVideoRecording() async {
    if (!_hasCameraPermission) {
      await _requestCameraPermission();
      if (!_hasCameraPermission) return;
    }
    if (!_hasAudioPermission) {
      await _requestAudioPermission();
      if (!_hasAudioPermission) return;
    }
    
    if (_isRecordingVideo) {
      await NotificationService.instance.stopVideoRecording();
      setState(() => _isRecordingVideo = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('⏹ Video recording stopped'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      Future.delayed(const Duration(seconds: 2), _loadData);
    } else {
      await NotificationService.instance.startVideoRecording();
      setState(() => _isRecordingVideo = true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🎥 Recording video (30s)...'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      // Auto refresh after recording completes
      Future.delayed(const Duration(seconds: 33), _loadData);
    }
  }

  Future<void> _toggleAudioRecording() async {
    if (!_hasAudioPermission) {
      await _requestAudioPermission();
      if (!_hasAudioPermission) return;
    }
    
    if (_isRecordingAudio) {
      await NotificationService.instance.stopAudioRecording();
      setState(() => _isRecordingAudio = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('⏹ Audio recording stopped'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      Future.delayed(const Duration(seconds: 2), _loadData);
    } else {
      await NotificationService.instance.startAudioRecording();
      setState(() => _isRecordingAudio = true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🎙 Recording audio (60s)...'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      Future.delayed(const Duration(seconds: 63), _loadData);
    }
  }

  Future<void> _deleteMedia(Map<String, dynamic> media) async {
    final path = media['path'] as String? ?? '';
    if (path.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Capture?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await NotificationService.instance.deleteCapturedMedia(path);
      _loadData();
    }
  }

  Future<void> _shareMedia(Map<String, dynamic> media) async {
    final path = media['path'] as String? ?? '';
    if (path.isEmpty) return;
    try {
      await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
    } catch (e) {
      debugPrint('Share error: $e');
    }
  }

  void _playAudio(String path) async {
    if (_currentlyPlayingAudioPath == path && _isAudioPlaying) {
      await _audioPlayer.pause();
      setState(() => _isAudioPlaying = false);
    } else {
      await _audioPlayer.stop();
      await _audioPlayer.play(DeviceFileSource(path));
      setState(() {
        _currentlyPlayingAudioPath = path;
        _isAudioPlaying = true;
      });
    }
  }

  String _formatFileSize(dynamic sizeBytes) {
    final size = (sizeBytes is int) ? sizeBytes : 0;
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _formatTimestamp(dynamic timestampMs) {
    final ts = (timestampMs is int) ? timestampMs : 0;
    if (ts == 0) return 'Unknown';
    final date = DateTime.fromMillisecondsSinceEpoch(ts);
    final now = DateTime.now();
    final diff = now.difference(date);
    if (diff.inDays == 0) return DateFormat('HH:mm').format(date);
    if (diff.inDays == 1) return 'Yesterday ${DateFormat('HH:mm').format(date)}';
    return DateFormat('MMM dd, HH:mm').format(date);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isSelectionMode ? '${_selectedMediaPaths.length} Selected' : 'Captures', 
            style: const TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
        backgroundColor: Colors.deepPurple.shade800,
        leading: _isSelectionMode 
            ? IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _selectedMediaPaths.clear())) 
            : null,
        actions: _isSelectionMode
            ? [
                IconButton(
                  icon: const Icon(Icons.share),
                  onPressed: _shareSelected,
                ),
                IconButton(
                  icon: const Icon(Icons.delete),
                  onPressed: _deleteSelected,
                ),
              ]
            : [
                InkWell(
                  onTap: _loadData,
                  onLongPress: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const TrashScreen()),
                    ).then((_) => _loadData());
                  },
                  borderRadius: BorderRadius.circular(50),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16.0),
                    child: Icon(Icons.refresh),
                  ),
                ),
              ],
        bottom: TabBar(
          controller: _mediaTabController,
          indicatorColor: Colors.deepPurpleAccent,
          tabs: [
            Tab(
              icon: const Icon(Icons.photo_camera, size: 20),
              text: 'Photos (${_getFilteredMedia("photo").length})',
            ),
            Tab(
              icon: const Icon(Icons.videocam, size: 20),
              text: 'Videos (${_getFilteredMedia("video").length})',
            ),
            Tab(
              icon: const Icon(Icons.mic, size: 20),
              text: 'Audio (${_getFilteredMedia("audio").length})',
            ),
          ],
        ),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.grey.shade900, Colors.black87],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: _isLoading
            ? const Center(child: CircularProgressIndicator(color: Colors.deepPurple))
            : Column(
                children: [
                  // Permission warnings
                  if (!_hasCameraPermission) _buildPermissionBanner(
                    'Camera permission required',
                    'Grant camera access to capture photos and videos',
                    Icons.camera_alt,
                    Colors.blue,
                    _requestCameraPermission,
                  ),
                  if (!_hasAudioPermission) _buildPermissionBanner(
                    'Microphone permission required',
                    'Grant mic access to record video with audio or audio-only',
                    Icons.mic,
                    Colors.orange,
                    _requestAudioPermission,
                  ),
                  // Recording status indicator
                  if (_isRecordingVideo)
                    _buildRecordingBanner('Recording video...', Colors.red, () => _toggleVideoRecording()),
                  if (_isRecordingAudio)
                    _buildRecordingBanner('Recording audio...', Colors.orange, () => _toggleAudioRecording()),
                  // Media tabs
                  Expanded(
                    child: TabBarView(
                      controller: _mediaTabController,
                      children: [
                        _buildPhotoGrid(),
                        _buildVideoList(),
                        _buildAudioList(),
                      ],
                    ),
                  ),
                ],
              ),
      ),
      // Floating action buttons for quick capture
      floatingActionButton: _buildCaptureButtons(),
    );
  }

  Widget _buildPermissionBanner(String title, String subtitle, IconData icon, Color color, VoidCallback onPressed) {
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 14)),
                Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
              ],
            ),
          ),
          FilledButton(
            onPressed: onPressed,
            style: FilledButton.styleFrom(backgroundColor: color),
            child: const Text('Grant'),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordingBanner(String text, Color color, VoidCallback onStop) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color),
      ),
      child: Row(
        children: [
          _PulsingDot(color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
          ),
          TextButton.icon(
            onPressed: onStop,
            icon: const Icon(Icons.stop, color: Colors.white),
            label: const Text('Stop', style: TextStyle(color: Colors.white)),
            style: TextButton.styleFrom(backgroundColor: color),
          ),
        ],
      ),
    );
  }

  Widget _buildPhotoGrid() {
    final photos = _getFilteredMedia('photo');
    if (photos.isEmpty) {
      return _buildEmptyState('No photos captured yet', Icons.photo_camera_outlined);
    }
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
      ),
      itemCount: photos.length,
      itemBuilder: (context, index) {
        final photo = photos[index];
        final path = photo['path'] as String? ?? '';
        final isSelected = _selectedMediaPaths.contains(path);
        return GestureDetector(
          onTap: () {
            if (_isSelectionMode) {
              _toggleSelection(path);
            } else {
              _openPhotoViewer(path);
            }
          },
          onLongPress: () {
            if (!_isSelectionMode) {
              _toggleSelection(path);
            } else {
              _showMediaOptions(photo);
            }
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.file(
                  File(path),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    color: Colors.grey.shade800,
                    child: const Icon(Icons.broken_image, color: Colors.grey),
                  ),
                ),
                if (isSelected)
                  Container(
                    color: Colors.black.withValues(alpha: 0.5),
                    child: const Center(
                      child: Icon(Icons.check_circle, color: Colors.deepPurpleAccent, size: 36),
                    ),
                  ),
                if (!isSelected)
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      color: Colors.black54,
                      child: Text(
                        _formatTimestamp(photo['timestampMs']),
                        style: const TextStyle(fontSize: 10, color: Colors.white70),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildVideoList() {
    final videos = _getFilteredMedia('video');
    if (videos.isEmpty) {
      return _buildEmptyState('No videos captured yet', Icons.videocam_outlined);
    }
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: videos.length,
      itemBuilder: (context, index) {
        final video = videos[index];
        return _buildMediaTile(
          video,
          icon: Icons.play_circle_fill,
          iconColor: Colors.blue,
          onTap: () => _openVideoPlayer(video['path'] as String? ?? ''),
        );
      },
    );
  }

  Widget _buildAudioList() {
    final audios = _getFilteredMedia('audio');
    if (audios.isEmpty) {
      return _buildEmptyState('No audio recordings yet', Icons.mic_none);
    }
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: audios.length,
      itemBuilder: (context, index) {
        final audio = audios[index];
        final path = audio['path'] as String? ?? '';
        final isPlaying = _currentlyPlayingAudioPath == path && _isAudioPlaying;
        return _buildMediaTile(
          audio,
          icon: isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill,
          iconColor: Colors.orange,
          onTap: () => _playAudio(path),
        );
      },
    );
  }

  Widget _buildMediaTile(Map<String, dynamic> media, {
    required IconData icon,
    required Color iconColor,
    required VoidCallback onTap,
  }) {
    final name = media['name'] as String? ?? 'Unknown';
    final size = _formatFileSize(media['sizeBytes']);
    final time = _formatTimestamp(media['timestampMs']);
    final path = media['path'] as String? ?? '';
    final isSelected = _selectedMediaPaths.contains(path);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: isSelected ? Colors.deepPurple.withValues(alpha: 0.3) : Colors.grey.shade800.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isSelected ? const BorderSide(color: Colors.deepPurpleAccent, width: 1.5) : BorderSide.none,
      ),
      child: ListTile(
        leading: _isSelectionMode
            ? Icon(isSelected ? Icons.check_circle : Icons.circle_outlined, 
                color: isSelected ? Colors.deepPurpleAccent : Colors.grey)
            : IconButton(
                icon: Icon(icon, color: iconColor, size: 36),
                onPressed: onTap,
              ),
        title: Text(name, style: const TextStyle(color: Colors.white, fontSize: 14)),
        subtitle: Text('$size • $time', style: TextStyle(color: Colors.grey.shade400, fontSize: 12)),
        trailing: _isSelectionMode ? null : PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, color: Colors.grey),
          onSelected: (value) {
            if (value == 'share') _shareMedia(media);
            if (value == 'delete') _deleteMedia(media);
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'share', child: Row(children: [
              Icon(Icons.share, size: 20), SizedBox(width: 12), Text('Share'),
            ])),
            const PopupMenuItem(value: 'delete', child: Row(children: [
              Icon(Icons.delete, size: 20, color: Colors.red), SizedBox(width: 12),
              Text('Delete', style: TextStyle(color: Colors.red)),
            ])),
          ],
        ),
        onTap: () {
          if (_isSelectionMode) {
            _toggleSelection(path);
          } else {
            onTap();
          }
        },
        onLongPress: () {
          if (!_isSelectionMode) {
            _toggleSelection(path);
          }
        },
      ),
    );
  }

  Widget _buildEmptyState(String text, IconData icon) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 64, color: Colors.grey.shade600),
          const SizedBox(height: 16),
          Text(text, style: TextStyle(fontSize: 16, color: Colors.grey.shade500)),
          const SizedBox(height: 8),
          Text(
            'Use the buttons below or notification\nactions to capture media',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }

  Widget _buildCaptureButtons() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Audio button
        FloatingActionButton.small(
          heroTag: 'audio_fab',
          onPressed: _toggleAudioRecording,
          backgroundColor: _isRecordingAudio ? Colors.red : Colors.orange.shade700,
          child: Icon(_isRecordingAudio ? Icons.stop : Icons.mic, size: 20),
        ),
        const SizedBox(height: 8),
        // Video button
        FloatingActionButton.small(
          heroTag: 'video_fab',
          onPressed: _toggleVideoRecording,
          backgroundColor: _isRecordingVideo ? Colors.red : Colors.blue.shade700,
          child: Icon(_isRecordingVideo ? Icons.stop : Icons.videocam, size: 20),
        ),
        const SizedBox(height: 8),
        // Photo button (primary)
        FloatingActionButton(
          heroTag: 'photo_fab',
          onPressed: _capturePhoto,
          backgroundColor: Colors.deepPurple,
          child: const Icon(Icons.camera_alt, size: 28),
        ),
      ],
    );
  }

  void _openPhotoViewer(String path) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _FullScreenPhotoViewer(imagePath: path),
      ),
    );
  }

  void _openVideoPlayer(String path) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _FullScreenVideoPlayer(videoPath: path),
      ),
    );
  }

  void _showMediaOptions(Map<String, dynamic> media) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.share),
              title: const Text('Share'),
              onTap: () { Navigator.pop(ctx); _shareMedia(media); },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('Delete', style: TextStyle(color: Colors.red)),
              onTap: () { Navigator.pop(ctx); _deleteMedia(media); },
            ),
          ],
        ),
      ),
    );
  }
}

/// Pulsing red dot indicator for recording state
class _PulsingDot extends StatefulWidget {
  final Color color;
  const _PulsingDot({required this.color});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, __) => Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.color.withValues(alpha: 0.5 + _controller.value * 0.5),
        ),
      ),
    );
  }
}

/// Full screen photo viewer
class _FullScreenPhotoViewer extends StatelessWidget {
  final String imagePath;
  const _FullScreenPhotoViewer({required this.imagePath});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: () async {
              try {
                await SharePlus.instance.share(ShareParams(files: [XFile(imagePath)]));
              } catch (e) {
                debugPrint('Share error: $e');
              }
            },
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          child: Image.file(
            File(imagePath),
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, color: Colors.grey, size: 64),
          ),
        ),
      ),
    );
  }
}

/// Full screen video player
class _FullScreenVideoPlayer extends StatefulWidget {
  final String videoPath;
  const _FullScreenVideoPlayer({required this.videoPath});

  @override
  State<_FullScreenVideoPlayer> createState() => _FullScreenVideoPlayerState();
}

class _FullScreenVideoPlayerState extends State<_FullScreenVideoPlayer> {
  late VideoPlayerController _controller;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.videoPath))
      ..initialize().then((_) {
        if (mounted) {
          setState(() => _isInitialized = true);
          _controller.play();
        }
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: () async {
              try {
                await SharePlus.instance.share(ShareParams(files: [XFile(widget.videoPath)]));
              } catch (e) {
                debugPrint('Share error: $e');
              }
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: _isInitialized
                    ? AspectRatio(
                        aspectRatio: _controller.value.aspectRatio,
                        child: VideoPlayer(_controller),
                      )
                    : const CircularProgressIndicator(color: Colors.deepPurple),
              ),
            ),
            if (_isInitialized)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        _controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
                        color: Colors.white,
                      ),
                      onPressed: () {
                        setState(() {
                          _controller.value.isPlaying ? _controller.pause() : _controller.play();
                        });
                      },
                    ),
                    const SizedBox(width: 8),
                    ValueListenableBuilder(
                      valueListenable: _controller,
                      builder: (context, VideoPlayerValue value, child) {
                        return Text(
                          '${_formatDuration(value.position)} / ${_formatDuration(value.duration)}',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        );
                      },
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: VideoProgressIndicator(
                        _controller,
                        allowScrubbing: true,
                        colors: const VideoProgressColors(
                          playedColor: Colors.deepPurpleAccent,
                          bufferedColor: Colors.white38,
                          backgroundColor: Colors.white24,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    if (duration.inHours > 0) {
      final hours = duration.inHours;
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }
}

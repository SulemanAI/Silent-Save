import 'dart:io';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:video_player/video_player.dart';
import 'package:audioplayers/audioplayers.dart';

class FullScreenMediaViewer extends StatefulWidget {
  final String path;
  final String heroTag;
  final String? type; // 'image', 'video', 'audio', etc.

  const FullScreenMediaViewer({
    super.key,
    required this.path,
    required this.heroTag,
    this.type,
  });

  @override
  State<FullScreenMediaViewer> createState() => _FullScreenMediaViewerState();
}

class _FullScreenMediaViewerState extends State<FullScreenMediaViewer> {
  final TransformationController _transformController = TransformationController();
  bool _isSaving = false;

  VideoPlayerController? _videoController;
  AudioPlayer? _audioPlayer;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isAudio = false;
  bool _isVideo = false;

  @override
  void initState() {
    super.initState();
    final ext = widget.path.toLowerCase().split('.').last;
    _isAudio = ['mp3', 'm4a', 'wav', 'ogg', 'opus', 'aac'].contains(ext) || widget.type == 'audio';
    _isVideo = ['mp4', 'mov', 'avi', 'mkv'].contains(ext) || widget.type == 'video';

    if (_isVideo) {
      _videoController = VideoPlayerController.file(File(widget.path))
        ..initialize().then((_) {
          if (mounted) {
            setState(() {
              _duration = _videoController!.value.duration;
            });
            _videoController!.play();
          }
        });
      _videoController!.addListener(() {
        if (mounted) {
          setState(() {
            _position = _videoController!.value.position;
            _isPlaying = _videoController!.value.isPlaying;
          });
        }
      });
    } else if (_isAudio) {
      _audioPlayer = AudioPlayer();
      _audioPlayer!.setSourceDeviceFile(widget.path);
      _audioPlayer!.onDurationChanged.listen((d) {
        if (mounted) setState(() => _duration = d);
      });
      _audioPlayer!.onPositionChanged.listen((p) {
        if (mounted) setState(() => _position = p);
      });
      _audioPlayer!.onPlayerStateChanged.listen((state) {
        if (mounted) setState(() => _isPlaying = state == PlayerState.playing);
      });
      _audioPlayer!.play(DeviceFileSource(widget.path));
    }
  }

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(d.inMinutes.remainder(60));
    final seconds = twoDigits(d.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  @override
  void dispose() {
    _transformController.dispose();
    _videoController?.dispose();
    _audioPlayer?.dispose();
    super.dispose();
  }

  Future<void> _saveMedia() async {
    setState(() => _isSaving = true);
    try {
      final ext = widget.path.toLowerCase().split('.').last;
      bool isVideo = ['mp4', 'mov', 'avi', 'mkv'].contains(ext) || widget.type == 'video';
      bool isAudio = ['mp3', 'm4a', 'wav', 'ogg', 'opus', 'aac'].contains(ext) || widget.type == 'audio';

      // Request permission
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        await Gal.requestAccess();
      }

      if (isVideo) {
        await Gal.putVideo(widget.path);
        _showSnack('Video saved to Gallery');
      } else if (isAudio) {
        // Fallback for audio: copy to public downloads folder
        final downloads = Directory('/storage/emulated/0/Download/SilentSave');
        if (!await downloads.exists()) {
          await downloads.create(recursive: true);
        }
        final fileName = widget.path.split(Platform.pathSeparator).last;
        await File(widget.path).copy('${downloads.path}/$fileName');
        _showSnack('Audio saved to Downloads/SilentSave');
      } else {
        // Default treat as image
        await Gal.putImage(widget.path);
        _showSnack('Image saved to Gallery');
      }
    } catch (e) {
      _showSnack('Error saving file: $e');
    } finally {
      setState(() => _isSaving = false);
    }
  }

  void _showSnack(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            message,
            style: const TextStyle(color: Colors.white),
          ),
          backgroundColor: Colors.grey.shade800,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ext = widget.path.toLowerCase().split('.').last;
    final isAudio = ['mp3', 'm4a', 'wav', 'ogg', 'opus', 'aac'].contains(ext) || widget.type == 'audio';
    final isVideo = ['mp4', 'mov', 'avi', 'mkv'].contains(ext) || widget.type == 'video';
    
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: 0.92),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black.withValues(alpha: 0.45),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          if (!isAudio && !isVideo)
            IconButton(
              icon: const Icon(Icons.zoom_out_map, color: Colors.white),
              tooltip: 'Reset zoom',
              onPressed: () {
                _transformController.value = Matrix4.identity();
              },
            ),
          IconButton(
            icon: _isSaving 
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.download, color: Colors.white),
            tooltip: 'Download',
            onPressed: _isSaving ? null : _saveMedia,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Center(
          child: Hero(
            tag: widget.heroTag,
            child: InteractiveViewer(
              transformationController: _transformController,
              minScale: 0.5,
              maxScale: 6.0,
              panEnabled: !isAudio && !isVideo,
              child: _isVideo && _videoController != null && _videoController!.value.isInitialized
                ? Stack(
                    alignment: Alignment.center,
                    children: [
                      AspectRatio(
                        aspectRatio: _videoController!.value.aspectRatio,
                        child: VideoPlayer(_videoController!),
                      ),
                      Positioned.fill(
                        child: GestureDetector(
                          onTap: () {
                            if (_isPlaying) {
                              _videoController!.pause();
                            } else {
                              _videoController!.play();
                            }
                          },
                          child: Container(
                            color: Colors.transparent,
                            child: !_isPlaying
                              ? Center(
                                  child: Container(
                                    padding: const EdgeInsets.all(16),
                                    decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                                    child: const Icon(Icons.play_arrow, size: 60, color: Colors.white),
                                  ),
                                )
                              : null,
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 20,
                        left: 20,
                        right: 20,
                        child: _buildScrubberBar(
                          onSeek: (v) => _videoController!.seekTo(Duration(milliseconds: v.toInt())),
                        ),
                      ),
                    ],
                  )
                : _isAudio
                    ? _buildAudioPlayer()
                    : _isVideo
                        ? const Center(child: CircularProgressIndicator(color: Colors.white))
                        : Image.file(
                            File(widget.path),
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) => const Icon(
                              Icons.broken_image,
                              color: Colors.white54,
                              size: 64,
                            ),
                          ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildScrubberBar({required Function(double) onSeek}) {
    return Row(
      children: [
        Text(_formatDuration(_position), style: const TextStyle(color: Colors.white, decoration: TextDecoration.none, fontSize: 12)),
        Expanded(
          child: Material(
            color: Colors.transparent,
            child: Slider(
              value: _position.inMilliseconds.toDouble().clamp(0, _duration.inMilliseconds.toDouble()),
              min: 0,
              max: _duration.inMilliseconds.toDouble().clamp(1, double.infinity),
              onChanged: onSeek,
              activeColor: Colors.deepPurpleAccent,
              inactiveColor: Colors.white30,
            ),
          ),
        ),
        Text(_formatDuration(_duration), style: const TextStyle(color: Colors.white, decoration: TextDecoration.none, fontSize: 12)),
      ],
    );
  }

  Widget _buildAudioPlayer() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.audiotrack, color: Colors.white70, size: 80),
        const SizedBox(height: 16),
        const Text('Voice Note', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold, decoration: TextDecoration.none)),
        const SizedBox(height: 32),
        Material(
          color: Colors.transparent,
          child: IconButton(
            iconSize: 64,
            color: Colors.white,
            icon: Icon(_isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled),
            onPressed: () {
              if (_isPlaying) {
                _audioPlayer?.pause();
              } else {
                _audioPlayer?.resume();
              }
            },
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32.0),
          child: _buildScrubberBar(
            onSeek: (v) => _audioPlayer?.seek(Duration(milliseconds: v.toInt())),
          ),
        ),
      ],
    );
  }
}

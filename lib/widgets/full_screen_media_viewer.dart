import 'dart:io';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';
import 'package:audioplayers/audioplayers.dart';
import '../services/notification_service.dart';


class FullScreenMediaViewer extends StatefulWidget {
  final List<String> paths;
  final List<String> heroTags;
  final int initialIndex;
  final String? type; // 'image', 'video', 'audio', etc. (fallback)
  final bool reverseOrder;

  const FullScreenMediaViewer({
    super.key,
    required this.paths,
    required this.heroTags,
    this.initialIndex = 0,
    this.type,
    this.reverseOrder = false,
  });

  @override
  State<FullScreenMediaViewer> createState() => _FullScreenMediaViewerState();
}

class _FullScreenMediaViewerState extends State<FullScreenMediaViewer> {
  late PageController _pageController;
  late int _currentIndex;
  late List<String> _paths;
  late List<String> _heroTags;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    if (widget.reverseOrder) {
      // Reverse the lists so that chronological order is Oldest -> Newest.
      // This way, swiping left goes to Newer items, and swiping right goes to Older.
      _paths = widget.paths.reversed.toList();
      _heroTags = widget.heroTags.reversed.toList();
      
      // Convert initialIndex from the descending array to the ascending array
      _currentIndex = (widget.paths.length - 1) - widget.initialIndex;
    } else {
      _paths = widget.paths;
      _heroTags = widget.heroTags;
      _currentIndex = widget.initialIndex;
    }
    
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _saveMedia(String path) async {
    setState(() => _isSaving = true);
    try {
      final ext = path.toLowerCase().split('.').last;
      bool isVideo = ['mp4', 'mov', 'avi', 'mkv'].contains(ext) || widget.type == 'video';
      bool isAudio = ['mp3', 'm4a', 'wav', 'ogg', 'opus', 'aac'].contains(ext) || widget.type == 'audio';

      // Request permission
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        await Gal.requestAccess();
      }

      if (isVideo) {
        await Gal.putVideo(path);
        _showSnack('Video saved to Gallery');
      } else if (isAudio) {
        // Fallback for audio: copy to public downloads folder
        final downloads = Directory('/storage/emulated/0/Download/SilentSave');
        if (!await downloads.exists()) {
          await downloads.create(recursive: true);
        }
        final fileName = path.split(Platform.pathSeparator).last;
        await File(path).copy('${downloads.path}/$fileName');
        _showSnack('Audio saved to Downloads/SilentSave');
      } else {
        // Default treat as image
        await Gal.putImage(path);
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
        title: _paths.length > 1
            ? Text(
                widget.reverseOrder 
                  ? '${_currentIndex + 1} of ${_paths.length}'
                  : '${_paths.length - _currentIndex} of ${_paths.length}',
                style: const TextStyle(color: Colors.white, fontSize: 16),
              )
            : null,
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.copy, color: Colors.white),
            tooltip: 'Copy to clipboard',
            onPressed: () async {
              final ok = await NotificationService.instance.copyMediaToClipboard(
                filePath: _paths[_currentIndex],
              );
              _showSnack(ok ? 'Media copied to clipboard' : 'Failed to copy to clipboard');
            },
          ),
          IconButton(
            icon: const Icon(Icons.share, color: Colors.white),
            tooltip: 'Share',
            onPressed: () {
              SharePlus.instance.share(ShareParams(files: [XFile(_paths[_currentIndex])]));
            },
          ),
          IconButton(
            icon: _isSaving 
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.download, color: Colors.white),
            tooltip: 'Download',
            onPressed: _isSaving ? null : () => _saveMedia(_paths[_currentIndex]),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: _paths.length,
        onPageChanged: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        itemBuilder: (context, index) {
          return _SingleMediaViewer(
            path: _paths[index],
            heroTag: _heroTags[index],
            type: widget.type,
            isActive: _currentIndex == index,
          );
        },
      ),
    );
  }
}

class _SingleMediaViewer extends StatefulWidget {
  final String path;
  final String heroTag;
  final String? type;
  final bool isActive;

  const _SingleMediaViewer({
    required this.path,
    required this.heroTag,
    required this.isActive,
    this.type,
  });

  @override
  State<_SingleMediaViewer> createState() => _SingleMediaViewerState();
}

class _SingleMediaViewerState extends State<_SingleMediaViewer> {
  final TransformationController _transformController = TransformationController();
  
  VideoPlayerController? _videoController;
  AudioPlayer? _audioPlayer;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isAudio = false;
  bool _isVideo = false;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    final ext = widget.path.toLowerCase().split('.').last;
    _isAudio = ['mp3', 'm4a', 'wav', 'ogg', 'opus', 'aac'].contains(ext) || widget.type == 'audio';
    _isVideo = ['mp4', 'mov', 'avi', 'mkv'].contains(ext) || widget.type == 'video';

    if (widget.isActive) {
      _initMedia();
    }
  }

  @override
  void didUpdateWidget(covariant _SingleMediaViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      if (!_initialized) {
        _initMedia();
      } else {
        _videoController?.play();
      }
    } else if (!widget.isActive && oldWidget.isActive) {
      _videoController?.pause();
      _audioPlayer?.pause();
    }
  }

  void _initMedia() {
    _initialized = true;
    if (_isVideo) {
      _videoController = VideoPlayerController.file(File(widget.path))
        ..initialize().then((_) {
          if (mounted) {
            setState(() {
              _duration = _videoController!.value.duration;
            });
            if (widget.isActive) {
              _videoController!.play();
            }
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
      if (widget.isActive) {
        // don't auto play audio
      }
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

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: Center(
        child: Hero(
          tag: widget.heroTag,
          child: InteractiveViewer(
            transformationController: _transformController,
            minScale: 0.5,
            maxScale: 6.0,
            panEnabled: !_isAudio && !_isVideo,
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
            onPressed: () async {
              if (_isPlaying) {
                await _audioPlayer?.pause();
              } else {
                await _audioPlayer?.resume();
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


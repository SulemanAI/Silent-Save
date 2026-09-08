import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:get_thumbnail_video/index.dart';
import 'package:get_thumbnail_video/video_thumbnail.dart';

class VideoThumbnailWidget extends StatefulWidget {
  final String videoPath;
  final BoxFit fit;

  const VideoThumbnailWidget({
    super.key,
    required this.videoPath,
    this.fit = BoxFit.cover,
  });

  @override
  State<VideoThumbnailWidget> createState() => _VideoThumbnailWidgetState();
}

class _VideoThumbnailWidgetState extends State<VideoThumbnailWidget> {
  Uint8List? _thumbnailBytes;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _generateThumbnail();
  }

  Future<void> _generateThumbnail() async {
    try {
      final uint8list = await VideoThumbnail.thumbnailData(
        video: widget.videoPath,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 400, // Reasonable max width for chat thumb
        quality: 50,
      );
      if (mounted) {
        setState(() {
          _thumbnailBytes = uint8list;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        color: Colors.blue.withValues(alpha: 0.2),
        child: const Center(
          child: CircularProgressIndicator(color: Colors.blue),
        ),
      );
    }

    if (_thumbnailBytes != null) {
      return Image.memory(
        _thumbnailBytes!,
        fit: widget.fit,
        width: double.infinity,
        height: double.infinity,
      );
    }

    // Fallback if extraction failed
    return Container(
      color: Colors.blue.withValues(alpha: 0.15),
      child: const Center(
        child: Icon(Icons.videocam, color: Colors.blue, size: 32),
      ),
    );
  }
}

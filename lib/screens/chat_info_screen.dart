import 'dart:io';
import 'package:flutter/material.dart';
import '../models/message_model.dart';
import '../services/database_helper.dart';
import '../widgets/full_screen_media_viewer.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

class ChatInfoScreen extends StatefulWidget {
  final String sender;
  final String app;

  const ChatInfoScreen({
    super.key,
    required this.sender,
    required this.app,
  });

  @override
  State<ChatInfoScreen> createState() => _ChatInfoScreenState();
}

class _ChatInfoScreenState extends State<ChatInfoScreen> {
  bool _isLoading = true;
  int _totalMessages = 0;
  int _totalMedia = 0;
  String _mostUsedWord = "N/A";
  String? _topWordRaw;
  List<Map<String, dynamic>> _dailyCounts = [];
  List<MessageModel> _mediaMessages = [];

  // Basic stop words to filter out common english words
  final Set<String> _stopWords = {
    'the', 'be', 'to', 'of', 'and', 'a', 'in', 'that', 'have', 'i', 'it', 'for', 'not', 'on', 'with', 'he', 'as', 'you', 'do', 'at', 'this', 'but', 'his', 'by', 'from', 'they', 'we', 'say', 'her', 'she', 'or', 'an', 'will', 'my', 'one', 'all', 'would', 'there', 'their', 'what', 'so', 'up', 'out', 'if', 'about', 'who', 'get', 'which', 'go', 'me', 'when', 'make', 'can', 'like', 'time', 'no', 'just', 'him', 'know', 'take', 'people', 'into', 'year', 'your', 'good', 'some', 'could', 'them', 'see', 'other', 'than', 'then', 'now', 'look', 'only', 'come', 'its', 'over', 'think', 'also', 'back', 'after', 'use', 'two', 'how', 'our', 'work', 'first', 'well', 'way', 'even', 'new', 'want', 'because', 'any', 'these', 'give', 'day', 'most', 'us', 'are', 'is', 'was', 'am', 'did', 'done', 'has', 'had', 'does', 'were', 'been', 'being', 'having'
  };

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    final stats = await DatabaseHelper.instance.getChatStatsSummary(widget.sender);
    final daily = await DatabaseHelper.instance.getDailyMessageCounts(widget.sender);
    final texts = await DatabaseHelper.instance.getAllTextMessages(widget.sender);
    final media = await DatabaseHelper.instance.getMediaMessagesBySender(widget.sender);

    // Compute most used word
    final wordCounts = <String, int>{};
    for (var text in texts) {
      final words = text.toLowerCase().replaceAll(RegExp(r'[^\w\s]+'), '').split(RegExp(r'\s+'));
      for (var word in words) {
        if (word.isNotEmpty && word.length > 2 && !_stopWords.contains(word)) {
          wordCounts[word] = (wordCounts[word] ?? 0) + 1;
        }
      }
    }

    String topWord = "N/A";
    String? topWordRaw;
    if (wordCounts.isNotEmpty) {
      final entries = wordCounts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      topWordRaw = entries.first.key;
      topWord = '"${entries.first.key}" (${entries.first.value})';
    }

    if (mounted) {
      setState(() {
        _totalMessages = stats['total'] ?? 0;
        _totalMedia = stats['media'] ?? 0;
        _mostUsedWord = topWord;
        _topWordRaw = topWordRaw;
        _dailyCounts = daily;
        _mediaMessages = media;
        _isLoading = false;
      });
    }
  }

  Widget _getAppIcon(String packageName, {double size = 16, Color? color}) {
    if (packageName.contains('whatsapp')) {
      return FaIcon(FontAwesomeIcons.whatsapp, size: size, color: color ?? Colors.green);
    } else if (packageName.contains('instagram')) {
      return FaIcon(FontAwesomeIcons.instagram, size: size, color: color ?? Colors.pinkAccent);
    }
    return Icon(Icons.notifications, size: size, color: color ?? Colors.grey);
  }

  void _openFullScreenMedia(int index) {
    List<String> paths = _mediaMessages.map((m) => m.mediaPath!).toList();
    List<String> heroTags = _mediaMessages.map((m) => 'gallery_${m.id ?? m.timestamp}').toList();

    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black.withValues(alpha: 0.92),
        pageBuilder: (ctx, animation, _) {
          return FadeTransition(
            opacity: animation,
            child: FullScreenMediaViewer(paths: paths, heroTags: heroTags, initialIndex: index, reverseOrder: true),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black87,
      appBar: AppBar(
        title: const Text('Chat Info'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.deepPurple.shade900, Colors.black],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.deepPurpleAccent))
          : SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Profile Section
                  Center(
                    child: Column(
                      children: [
                        Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              colors: [Colors.deepPurple.shade400, Colors.purple.shade600],
                            ),
                          ),
                          child: Center(
                            child: Text(
                              widget.sender.isNotEmpty ? widget.sender.characters.first.toUpperCase() : '?',
                              style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          widget.sender,
                          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _getAppIcon(widget.app),
                            const SizedBox(width: 8),
                            Text(
                              widget.app,
                              style: TextStyle(color: Colors.grey.shade400, fontSize: 14),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Quick Stats
                  Row(
                    children: [
                      _buildStatCard('Messages', _totalMessages.toString(), Icons.chat_bubble_outline),
                      const SizedBox(width: 16),
                      _buildStatCard('Media', _totalMedia.toString(), Icons.perm_media_outlined),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _buildStatCard(
                    'Most Used Word', 
                    _mostUsedWord, 
                    Icons.text_snippet_outlined, 
                    fullWidth: true,
                    onTap: () {
                      if (_topWordRaw != null) {
                        Navigator.pop(context, _topWordRaw);
                      }
                    },
                  ),
                  const SizedBox(height: 32),

                  // Activity Chart
                  if (_dailyCounts.isNotEmpty) ...[
                    const Text(
                      'Message Activity',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade900,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: _buildChart(),
                    ),
                    const SizedBox(height: 32),
                  ],

                  // Media Gallery
                  if (_mediaMessages.isNotEmpty) ...[
                    const Text(
                      'Media Gallery',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    const SizedBox(height: 16),
                    GridView.builder(
                      physics: const NeverScrollableScrollPhysics(),
                      shrinkWrap: true,
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                      ),
                      itemCount: _mediaMessages.length,
                      itemBuilder: (context, index) {
                        final msg = _mediaMessages[index];
                        final ext = msg.mediaPath!.toLowerCase().split('.').last;
                        final isVideo = ['mp4', 'mov', 'avi', 'mkv'].contains(ext);
                        final isAudio = ['mp3', 'm4a', 'wav', 'ogg', 'opus', 'aac'].contains(ext);

                        return GestureDetector(
                          onTap: () => _openFullScreenMedia(index),
                          child: Hero(
                            tag: 'gallery_${msg.id ?? msg.timestamp}',
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: isAudio
                                  ? Container(
                                      color: Colors.deepPurple.shade900.withValues(alpha: 0.5),
                                      child: const Icon(Icons.audiotrack, color: Colors.white54, size: 32),
                                    )
                                  : isVideo
                                      ? Container(
                                          color: Colors.black87,
                                          child: const Center(
                                            child: Icon(Icons.play_circle_outline, color: Colors.white, size: 32),
                                          ),
                                        )
                                      : Image.file(
                                          File(msg.mediaPath!),
                                          fit: BoxFit.cover,
                                          errorBuilder: (c, e, s) => Container(
                                            color: Colors.grey.shade900,
                                            child: const Icon(Icons.broken_image, color: Colors.white54),
                                          ),
                                        ),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _buildStatCard(String title, String value, IconData icon, {bool fullWidth = false, VoidCallback? onTap}) {
    final content = GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade800),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Colors.deepPurpleAccent, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 14),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    ));

    return fullWidth ? content : Expanded(child: content);
  }

  Widget _buildChart() {
    // Show up to the last 14 days
    final displayData = _dailyCounts.length > 14 ? _dailyCounts.sublist(_dailyCounts.length - 14) : _dailyCounts;
    
    double maxCount = 0;
    for (var d in displayData) {
      final count = d['count'] as int;
      if (count > maxCount) maxCount = count.toDouble();
    }
    
    const monthNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    
    final isWhatsApp = widget.app.toLowerCase().contains('whatsapp');
    final chartGradient = isWhatsApp 
        ? [Colors.teal.shade400, Colors.green.shade600] 
        : [Colors.purpleAccent, Colors.pinkAccent];
    
    return Column(
      children: displayData.map((d) {
        final dayStr = d['day'] as String;
        final parts = dayStr.split('-');
        String dateLabel = dayStr;
        if (parts.length == 3) {
          final month = int.tryParse(parts[1]) ?? 1;
          final monthName = month >= 1 && month <= 12 ? monthNames[month - 1] : parts[1];
          // Remove leading zero from day if present
          final day = int.tryParse(parts[2])?.toString() ?? parts[2];
          dateLabel = '$monthName $day';
        }
        
        final count = d['count'] as int;
        
        // Calculate the relative width of the bar
        final widthFactor = maxCount > 0 ? (count / maxCount) : 0.0;

        return Padding(
          padding: const EdgeInsets.only(bottom: 12.0),
          child: Row(
            children: [
              // Date Label
              SizedBox(
                width: 48,
                child: Text(
                  dateLabel,
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              
              // Bar and Count
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Maximum width available for the bar itself
                    // We leave some space for the count text
                    final maxBarWidth = constraints.maxWidth - 40; 
                    final barWidth = maxBarWidth * widthFactor;

                    return Row(
                      children: [
                        Container(
                          height: 24,
                          width: barWidth > 0 ? barWidth : 2, // minimum width of 2 to be visible
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: chartGradient,
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                            ),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          count.toString(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

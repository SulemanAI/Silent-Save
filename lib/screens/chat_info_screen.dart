import 'dart:io';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import '../models/message_model.dart';
import '../services/database_helper.dart';
import '../widgets/full_screen_media_viewer.dart';

class ChatInfoScreen extends StatefulWidget {
  final String sender;
  final String app;
  final String? avatarPath;
  final bool? isGroupChat;
  final String? initialSenderFilter;

  const ChatInfoScreen({
    super.key,
    required this.sender,
    required this.app,
    this.avatarPath,
    this.isGroupChat,
    this.initialSenderFilter,
  });

  @override
  State<ChatInfoScreen> createState() => _ChatInfoScreenState();
}

class _ChatInfoScreenState extends State<ChatInfoScreen> {
  bool _isLoading = true;
  bool _isSwitchingSender = false;
  bool _isGroup = false;

  int _totalMessages = 0;
  int _totalMedia = 0;
  int _totalGroupMessages = 0;

  String _mostUsedWord = "N/A";
  String? _topWordRaw;
  List<Map<String, dynamic>> _dailyCounts = [];
  List<MessageModel> _mediaMessages = [];
  List<Map<String, dynamic>> _groupMembersWithStats = [];

  String? _selectedSender;
  String? _avatarsDir;
  String _memberSearchQuery = '';
  bool _sortByMostMessages = true;

  final ScrollController _scrollController = ScrollController();

  // Basic stop words to filter out common english words
  final Set<String> _stopWords = {
    'the', 'be', 'to', 'of', 'and', 'a', 'in', 'that', 'have', 'i', 'it', 'for', 'not',
    'on', 'with', 'he', 'as', 'you', 'do', 'at', 'this', 'but', 'his', 'by', 'from',
    'they', 'we', 'say', 'her', 'she', 'or', 'an', 'will', 'my', 'one', 'all', 'would',
    'there', 'their', 'what', 'so', 'up', 'out', 'if', 'about', 'who', 'get', 'which',
    'go', 'me', 'when', 'make', 'can', 'like', 'time', 'no', 'just', 'him', 'know',
    'take', 'people', 'into', 'year', 'your', 'good', 'some', 'could', 'them', 'see',
    'other', 'than', 'then', 'now', 'look', 'only', 'come', 'its', 'over', 'think',
    'also', 'back', 'after', 'use', 'two', 'how', 'our', 'work', 'first', 'well',
    'way', 'even', 'new', 'want', 'because', 'any', 'these', 'give', 'day', 'most',
    'us', 'are', 'is', 'was', 'am', 'did', 'done', 'has', 'had', 'does', 'were',
    'been', 'being', 'having'
  };

  @override
  void initState() {
    super.initState();
    _initAvatarsDir();
    _loadStats(initialSender: widget.initialSenderFilter);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _initAvatarsDir() async {
    try {
      final supportDir = await getApplicationSupportDirectory();
      if (mounted) {
        setState(() {
          _avatarsDir = '${supportDir.path}/avatars';
        });
      }
    } catch (_) {}
  }

  Future<void> _loadStats({String? initialSender}) async {
    setState(() => _isLoading = true);

    bool isGroup = widget.isGroupChat ?? await DatabaseHelper.instance.isGroupChat(widget.sender);
    List<Map<String, dynamic>> members = [];
    int totalGroupMsgs = 0;

    // Load group members stats
    final fetchedMembers = await DatabaseHelper.instance.getGroupMembersWithStats(widget.sender);
    if (fetchedMembers.length > 1) {
      isGroup = true;
      members = fetchedMembers;
      for (final m in members) {
        totalGroupMsgs += (m['messageCount'] as int? ?? 0);
      }
    } else if (isGroup) {
      members = fetchedMembers;
      for (final m in members) {
        totalGroupMsgs += (m['messageCount'] as int? ?? 0);
      }
    }

    _isGroup = isGroup;
    _groupMembersWithStats = members;
    _totalGroupMessages = totalGroupMsgs;
    _selectedSender = initialSender;

    await _fetchStatsForSender(_selectedSender);
  }

  Future<void> _fetchStatsForSender(String? senderFilter) async {
    final stats = await DatabaseHelper.instance.getChatStatsSummary(
      widget.sender,
      senderName: senderFilter,
    );
    final daily = await DatabaseHelper.instance.getDailyMessageCounts(
      widget.sender,
      senderName: senderFilter,
    );
    final texts = await DatabaseHelper.instance.getAllTextMessages(
      widget.sender,
      senderName: senderFilter,
    );
    final media = await DatabaseHelper.instance.getMediaMessagesBySender(
      widget.sender,
      senderName: senderFilter,
    );

    // Compute most used word
    final wordCounts = <String, int>{};
    for (var text in texts) {
      final words = text
          .toLowerCase()
          .replaceAll(RegExp(r'[^\w\s]+'), '')
          .split(RegExp(r'\s+'));
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
        if (!_isGroup || senderFilter == null) {
          _totalGroupMessages = stats['total'] ?? 0;
        }
        _mostUsedWord = topWord;
        _topWordRaw = topWordRaw;
        _dailyCounts = daily;
        _mediaMessages = media;
        _selectedSender = senderFilter;
        _isLoading = false;
        _isSwitchingSender = false;
      });
    }
  }

  Future<void> _selectSender(String? senderName) async {
    if (_selectedSender == senderName) return;
    setState(() {
      _isSwitchingSender = true;
      _selectedSender = senderName;
    });
    await _fetchStatsForSender(senderName);
  }

  Color _getSenderColor(String senderName) {
    final colors = [
      Colors.blue.shade300,
      Colors.green.shade300,
      Colors.orange.shade300,
      Colors.pink.shade300,
      Colors.teal.shade300,
      Colors.amber.shade300,
      Colors.indigo.shade300,
      Colors.cyan.shade300,
      Colors.lime.shade300,
      Colors.red.shade300,
    ];
    final hash = senderName.hashCode.abs();
    return colors[hash % colors.length];
  }

  Widget _buildMemberAvatar(String senderName, {double size = 32}) {
    final color = _getSenderColor(senderName);

    if (_avatarsDir != null) {
      final appPrefix = widget.app.contains('whatsapp')
          ? 'wa'
          : widget.app.contains('instagram')
          ? 'ig'
          : 'other';
      final safeName = senderName.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final truncatedName =
          safeName.length > 50 ? safeName.substring(0, 50) : safeName;
      final avatarFile = File('$_avatarsDir/${appPrefix}_sender_$truncatedName.png');

      if (avatarFile.existsSync()) {
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            image: DecorationImage(
              image: FileImage(avatarFile),
              fit: BoxFit.cover,
            ),
            border: Border.all(color: color.withValues(alpha: 0.6), width: 1.5),
          ),
        );
      }
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.25),
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: 0.6), width: 1.5),
      ),
      child: Center(
        child: Text(
          senderName.isNotEmpty ? senderName.characters.first.toUpperCase() : '?',
          style: TextStyle(
            fontSize: size * 0.45,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  String _formatLastActive(int timestampMs) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final messageDate = DateTime(date.year, date.month, date.day);

    if (messageDate == today) {
      return 'Today ${DateFormat('h:mm a').format(date)}';
    } else if (messageDate == yesterday) {
      return 'Yesterday ${DateFormat('h:mm a').format(date)}';
    } else if (now.year == date.year) {
      return DateFormat('MMM d, h:mm a').format(date);
    } else {
      return DateFormat('MMM d, yyyy').format(date);
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

  void _showAllMembersPickerModal() {
    String query = '';
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.grey.shade900,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final filtered = _groupMembersWithStats.where((m) {
              final name = m['name'] as String;
              return name.toLowerCase().contains(query.toLowerCase());
            }).toList();

            return Container(
              padding: EdgeInsets.only(
                top: 20,
                left: 16,
                right: 16,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
              ),
              height: MediaQuery.of(ctx).size.height * 0.75,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Select Sender to Filter',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white70),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Search group members...',
                      hintStyle: TextStyle(color: Colors.grey.shade500),
                      prefixIcon: const Icon(Icons.search, color: Colors.grey),
                      filled: true,
                      fillColor: Colors.grey.shade800,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onChanged: (val) {
                      setModalState(() => query = val);
                    },
                  ),
                  const SizedBox(height: 12),
                  // All Members Option
                  ListTile(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    tileColor: _selectedSender == null ? Colors.deepPurple.shade900.withValues(alpha: 0.6) : null,
                    leading: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: Colors.deepPurpleAccent.withValues(alpha: 0.3),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.group, color: Colors.white, size: 20),
                    ),
                    title: const Text('All Members', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    subtitle: Text('$_totalGroupMessages total messages', style: TextStyle(color: Colors.grey.shade400, fontSize: 12)),
                    trailing: _selectedSender == null
                        ? const Icon(Icons.check_circle, color: Colors.deepPurpleAccent)
                        : null,
                    onTap: () {
                      Navigator.pop(ctx);
                      _selectSender(null);
                    },
                  ),
                  const Divider(color: Colors.white12),
                  Expanded(
                    child: filtered.isEmpty
                        ? Center(
                            child: Text('No members found', style: TextStyle(color: Colors.grey.shade500)),
                          )
                        : ListView.builder(
                            itemCount: filtered.length,
                            itemBuilder: (context, index) {
                              final member = filtered[index];
                              final name = member['name'] as String;
                              final count = member['messageCount'] as int;
                              final isSelected = _selectedSender == name;
                              final percent = _totalGroupMessages > 0
                                  ? (count / _totalGroupMessages * 100).toStringAsFixed(1)
                                  : '0';

                              return ListTile(
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                tileColor: isSelected ? Colors.deepPurple.shade900.withValues(alpha: 0.6) : null,
                                leading: _buildMemberAvatar(name, size: 36),
                                title: Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                                subtitle: Text('$count messages ($percent%)', style: TextStyle(color: Colors.grey.shade400, fontSize: 12)),
                                trailing: isSelected
                                    ? const Icon(Icons.check_circle, color: Colors.deepPurpleAccent)
                                    : const Icon(Icons.chevron_right, color: Colors.grey),
                                onTap: () {
                                  Navigator.pop(ctx);
                                  _selectSender(name);
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasAvatar = widget.avatarPath != null &&
        widget.avatarPath!.isNotEmpty &&
        File(widget.avatarPath!).existsSync();

    final isWhatsApp = widget.app.toLowerCase().contains('whatsapp');
    final gradientColors = isWhatsApp
        ? [Colors.teal.shade900, Colors.black]
        : [Colors.deepPurple.shade900, Colors.black];

    return Scaffold(
      backgroundColor: Colors.black87,
      appBar: AppBar(
        title: Text(_isGroup ? 'Group Info' : 'Chat Info'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: gradientColors,
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
        ),
        actions: [
          if (_isGroup && _selectedSender != null)
            IconButton(
              icon: const Icon(Icons.clear_all_rounded, color: Colors.orangeAccent),
              tooltip: 'Reset to All Members',
              onPressed: () => _selectSender(null),
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.deepPurpleAccent))
          : SingleChildScrollView(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Profile Section
                  Center(
                    child: Column(
                      children: [
                        Container(
                          width: 84,
                          height: 84,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: hasAvatar
                                ? null
                                : LinearGradient(
                                    colors: _isGroup
                                        ? [Colors.teal.shade500, Colors.cyan.shade600]
                                        : [Colors.deepPurple.shade400, Colors.purple.shade600],
                                  ),
                            image: hasAvatar
                                ? DecorationImage(
                                    image: FileImage(File(widget.avatarPath!)),
                                    fit: BoxFit.cover,
                                  )
                                : null,
                          ),
                          child: hasAvatar
                              ? null
                              : Center(
                                  child: _isGroup
                                      ? const Icon(Icons.group, size: 40, color: Colors.white)
                                      : Text(
                                          widget.sender.isNotEmpty
                                              ? widget.sender.characters.first.toUpperCase()
                                              : '?',
                                          style: const TextStyle(
                                            fontSize: 34,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white,
                                          ),
                                        ),
                                ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          widget.sender,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _getAppIcon(widget.app, size: 14),
                            const SizedBox(width: 6),
                            Text(
                              widget.app,
                              style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                            ),
                            if (_isGroup) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.teal.shade900.withValues(alpha: 0.6),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: Colors.teal.shade600.withValues(alpha: 0.5)),
                                ),
                                child: Text(
                                  '${_groupMembersWithStats.length} members',
                                  style: TextStyle(
                                    color: Colors.teal.shade200,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),

                  // Sender Filter Section (for Group Chats)
                  if (_isGroup && _groupMembersWithStats.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    _buildSenderFilterBar(),
                  ],

                  // Active Filter Banner
                  if (_isGroup && _selectedSender != null) ...[
                    const SizedBox(height: 14),
                    _buildActiveSenderBanner(),
                  ],

                  const SizedBox(height: 24),

                  if (_isSwitchingSender)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: const Center(
                        child: CircularProgressIndicator(color: Colors.deepPurpleAccent),
                      ),
                    )
                  else ...[
                    // Quick Stats Cards
                    Row(
                      children: [
                        _buildStatCard(
                          _selectedSender != null ? 'Sender Messages' : 'Messages',
                          _totalMessages.toString(),
                          Icons.chat_bubble_outline,
                          subtitle: _isGroup && _selectedSender != null && _totalGroupMessages > 0
                              ? '${((_totalMessages / _totalGroupMessages) * 100).toStringAsFixed(1)}% of group'
                              : null,
                        ),
                        const SizedBox(width: 14),
                        _buildStatCard(
                          _selectedSender != null ? 'Sender Media' : 'Media',
                          _totalMedia.toString(),
                          Icons.perm_media_outlined,
                          subtitle: _selectedSender != null ? 'By $_selectedSender' : null,
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    _buildStatCard(
                      'Most Used Word',
                      _mostUsedWord,
                      Icons.text_snippet_outlined,
                      fullWidth: true,
                      subtitle: 'Tap to search in chat',
                      onTap: () {
                        if (_topWordRaw != null) {
                          Navigator.pop(context, _topWordRaw);
                        }
                      },
                    ),

                    const SizedBox(height: 28),

                    // Activity Chart ("and when")
                    _buildActivitySection(),

                    // Members Activity Breakdown ("how much messages are sent by whom")
                    if (_isGroup && _groupMembersWithStats.isNotEmpty) ...[
                      const SizedBox(height: 28),
                      _buildMembersBreakdownSection(),
                    ],

                    // Media Gallery
                    if (_mediaMessages.isNotEmpty) ...[
                      const SizedBox(height: 28),
                      _buildMediaGallerySection(),
                    ],
                  ],
                ],
              ),
            ),
    );
  }

  Widget _buildSenderFilterBar() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade800),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.filter_list_rounded, color: Colors.deepPurpleAccent, size: 18),
                  const SizedBox(width: 8),
                  const Text(
                    'Filter by Sender',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
              if (_groupMembersWithStats.length > 4)
                TextButton.icon(
                  onPressed: _showAllMembersPickerModal,
                  icon: const Icon(Icons.search, size: 16, color: Colors.deepPurpleAccent),
                  label: Text(
                    'All (${_groupMembersWithStats.length})',
                    style: const TextStyle(color: Colors.deepPurpleAccent, fontSize: 13),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                // "All Members" chip
                _buildFilterChip(
                  label: 'All Members',
                  count: _totalGroupMessages,
                  isSelected: _selectedSender == null,
                  avatarWidget: const Icon(Icons.group, size: 16, color: Colors.white),
                  onTap: () => _selectSender(null),
                ),
                // Top member chips
                ..._groupMembersWithStats.take(6).map((member) {
                  final name = member['name'] as String;
                  final count = member['messageCount'] as int;
                  final isSelected = _selectedSender == name;
                  return _buildFilterChip(
                    label: name,
                    count: count,
                    isSelected: isSelected,
                    avatarWidget: _buildMemberAvatar(name, size: 20),
                    onTap: () => _selectSender(isSelected ? null : name),
                  );
                }),
                if (_groupMembersWithStats.length > 6)
                  ActionChip(
                    backgroundColor: Colors.grey.shade800,
                    side: BorderSide(color: Colors.grey.shade700),
                    label: Text(
                      '+${_groupMembersWithStats.length - 6} more',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    onPressed: _showAllMembersPickerModal,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip({
    required String label,
    required int count,
    required bool isSelected,
    required Widget avatarWidget,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8.0),
      child: FilterChip(
        selected: isSelected,
        showCheckmark: false,
        avatar: avatarWidget,
        label: Text.rich(
          TextSpan(
            text: label,
            style: TextStyle(
              color: isSelected ? Colors.white : Colors.grey.shade300,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              fontSize: 13,
            ),
            children: [
              TextSpan(
                text: ' ($count)',
                style: TextStyle(
                  color: isSelected ? Colors.white70 : Colors.grey.shade500,
                  fontSize: 11,
                  fontWeight: FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
        backgroundColor: Colors.grey.shade800,
        selectedColor: Colors.deepPurple,
        side: BorderSide(
          color: isSelected ? Colors.deepPurpleAccent : Colors.grey.shade700,
          width: isSelected ? 1.5 : 1,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        onSelected: (_) => onTap(),
      ),
    );
  }

  Widget _buildActiveSenderBanner() {
    final senderName = _selectedSender!;
    final percentage = _totalGroupMessages > 0
        ? ((_totalMessages / _totalGroupMessages) * 100).toStringAsFixed(1)
        : '0';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.deepPurple.shade900.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.deepPurpleAccent.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          _buildMemberAvatar(senderName, size: 38),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Filtered by: ',
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                    ),
                    Flexible(
                      child: Text(
                        senderName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '$_totalMessages messages ($percentage% of group)',
                  style: const TextStyle(color: Colors.deepPurpleAccent, fontSize: 12),
                ),
              ],
            ),
          ),
          // "Filter in Chat" Button
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(context, {
                'action': 'filter_sender',
                'sender': senderName,
              });
            },
            icon: const Icon(Icons.chat_outlined, size: 14),
            label: const Text('In Chat', style: TextStyle(fontSize: 12)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.deepPurple,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: const Size(0, 32),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white70, size: 18),
            tooltip: 'Clear sender filter',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: () => _selectSender(null),
          ),
        ],
      ),
    );
  }

  Widget _buildActivitySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Message Activity',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                ),
                const SizedBox(height: 2),
                Text(
                  _selectedSender != null
                      ? 'Activity by $_selectedSender'
                      : 'Activity across all members',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                ),
              ],
            ),
            if (_dailyCounts.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.grey.shade800,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${_dailyCounts.length} active days',
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ),
          ],
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.grey.shade900,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey.shade800),
          ),
          child: _dailyCounts.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24.0),
                  child: Center(
                    child: Column(
                      children: [
                        Icon(Icons.calendar_today_outlined, size: 36, color: Colors.grey.shade600),
                        const SizedBox(height: 8),
                        Text(
                          _selectedSender != null
                              ? 'No messages recorded for $_selectedSender'
                              : 'No message activity recorded',
                          style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                )
              : _buildChart(),
        ),
      ],
    );
  }

  Widget _buildMembersBreakdownSection() {
    // Sort members
    final sortedMembers = List<Map<String, dynamic>>.from(_groupMembersWithStats);
    sortedMembers.sort((a, b) {
      if (_sortByMostMessages) {
        final countA = a['messageCount'] as int;
        final countB = b['messageCount'] as int;
        if (countA != countB) return countB.compareTo(countA);
      }
      final nameA = (a['name'] as String).toLowerCase();
      final nameB = (b['name'] as String).toLowerCase();
      return nameA.compareTo(nameB);
    });

    final filteredMembers = sortedMembers.where((m) {
      if (_memberSearchQuery.isEmpty) return true;
      return (m['name'] as String).toLowerCase().contains(_memberSearchQuery.toLowerCase());
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Members Breakdown',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                ),
                const SizedBox(height: 2),
                Text(
                  'Tap any member to view their individual activity & stats',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                ),
              ],
            ),
            PopupMenuButton<bool>(
              icon: const Icon(Icons.sort, color: Colors.white70, size: 20),
              tooltip: 'Sort members',
              onSelected: (most) => setState(() => _sortByMostMessages = most),
              itemBuilder: (c) => [
                PopupMenuItem(
                  value: true,
                  child: Row(
                    children: [
                      Icon(
                        _sortByMostMessages ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                        size: 18,
                        color: Colors.deepPurpleAccent,
                      ),
                      const SizedBox(width: 8),
                      const Text('Most messages first'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: false,
                  child: Row(
                    children: [
                      Icon(
                        !_sortByMostMessages ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                        size: 18,
                        color: Colors.deepPurpleAccent,
                      ),
                      const SizedBox(width: 8),
                      const Text('Alphabetical order'),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
        if (_groupMembersWithStats.length > 5) ...[
          const SizedBox(height: 10),
          TextField(
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Search members...',
              hintStyle: TextStyle(color: Colors.grey.shade500),
              prefixIcon: const Icon(Icons.search, size: 18, color: Colors.grey),
              filled: true,
              fillColor: Colors.grey.shade900,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey.shade800),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey.shade800),
              ),
            ),
            onChanged: (val) => setState(() => _memberSearchQuery = val),
          ),
        ],
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: Colors.grey.shade900,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey.shade800),
          ),
          child: ListView.separated(
            physics: const NeverScrollableScrollPhysics(),
            shrinkWrap: true,
            itemCount: filteredMembers.length,
            separatorBuilder: (_, __) => Divider(color: Colors.grey.shade800, height: 1),
            itemBuilder: (context, index) {
              final member = filteredMembers[index];
              final name = member['name'] as String;
              final count = member['messageCount'] as int;
              final mediaCount = member['mediaCount'] as int;
              final lastTs = member['lastTimestamp'] as int?;
              final isSelected = _selectedSender == name;

              final percent = _totalGroupMessages > 0 ? (count / _totalGroupMessages) : 0.0;
              final percentStr = (percent * 100).toStringAsFixed(1);

              // Ranking badge
              Widget rankWidget;
              if (index == 0 && _sortByMostMessages) {
                rankWidget = const Text('🥇', style: TextStyle(fontSize: 16));
              } else if (index == 1 && _sortByMostMessages) {
                rankWidget = const Text('🥈', style: TextStyle(fontSize: 16));
              } else if (index == 2 && _sortByMostMessages) {
                rankWidget = const Text('🥉', style: TextStyle(fontSize: 16));
              } else {
                rankWidget = Text(
                  '#${index + 1}',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12, fontWeight: FontWeight.bold),
                );
              }

              return InkWell(
                onTap: () {
                  _selectSender(isSelected ? null : name);
                  _scrollController.animateTo(
                    0,
                    duration: const Duration(milliseconds: 350),
                    curve: Curves.easeOut,
                  );
                },
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  color: isSelected ? Colors.deepPurple.shade900.withValues(alpha: 0.35) : null,
                  child: Row(
                    children: [
                      SizedBox(width: 24, child: Center(child: rankWidget)),
                      const SizedBox(width: 8),
                      _buildMemberAvatar(name, size: 38),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    name,
                                    style: TextStyle(
                                      color: isSelected ? Colors.deepPurpleAccent : Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Text(
                                  '$count msgs',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            // Progress bar
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: percent,
                                minHeight: 6,
                                backgroundColor: Colors.grey.shade800,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  isSelected ? Colors.deepPurpleAccent : _getSenderColor(name),
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  '$percentStr% of group • $mediaCount media',
                                  style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                                ),
                                if (lastTs != null)
                                  Text(
                                    _formatLastActive(lastTs),
                                    style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        isSelected ? Icons.check_circle_rounded : Icons.bar_chart_rounded,
                        color: isSelected ? Colors.deepPurpleAccent : Colors.grey.shade600,
                        size: 20,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildMediaGallerySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _selectedSender != null ? 'Media by $_selectedSender' : 'Media Gallery',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            Text(
              '${_mediaMessages.length} items',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
            ),
          ],
        ),
        const SizedBox(height: 14),
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
    );
  }

  Widget _buildStatCard(
    String title,
    String value,
    IconData icon, {
    bool fullWidth = false,
    String? subtitle,
    VoidCallback? onTap,
  }) {
    final content = GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(18),
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
                Icon(icon, color: Colors.deepPurpleAccent, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
              overflow: TextOverflow.ellipsis,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );

    return fullWidth ? content : Expanded(child: content);
  }

  Widget _buildChart() {
    // Show up to the last 14 days
    final displayData =
        _dailyCounts.length > 14 ? _dailyCounts.sublist(_dailyCounts.length - 14) : _dailyCounts;

    double maxCount = 0;
    for (var d in displayData) {
      final count = d['count'] as int;
      if (count > maxCount) maxCount = count.toDouble();
    }

    const monthNames = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];

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
          final day = int.tryParse(parts[2])?.toString() ?? parts[2];
          dateLabel = '$monthName $day';
        }

        final count = d['count'] as int;
        final widthFactor = maxCount > 0 ? (count / maxCount) : 0.0;

        return Padding(
          padding: const EdgeInsets.only(bottom: 12.0),
          child: Row(
            children: [
              SizedBox(
                width: 52,
                child: Text(
                  dateLabel,
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final maxBarWidth = constraints.maxWidth - 44;
                    final barWidth = maxBarWidth * widthFactor;

                    return Row(
                      children: [
                        Container(
                          height: 24,
                          width: barWidth > 0 ? barWidth : 2,
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

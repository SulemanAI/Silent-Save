import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../widgets/video_thumbnail_widget.dart';
import 'package:intl/intl.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../models/message_model.dart';
import '../services/database_helper.dart';
import '../services/notification_service.dart';
import '../widgets/full_screen_media_viewer.dart';

class ConversationScreen extends StatefulWidget {
  final String sender;
  final String app;
  final String? initialAvatarPath;

  const ConversationScreen({
    super.key,
    required this.sender,
    required this.app,
    this.initialAvatarPath,
  });

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> with WidgetsBindingObserver {
  List<MessageModel> _messages = [];
  bool _isLoading = true;
  bool _isGroupChat = false;
  String? _avatarPath;
  String? _avatarsDir; // For looking up sender-specific avatars in groups

  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  
  List<String> _groupMembers = [];
  final Set<String> _selectedSenders = {};
  
  // Highlighting and scrolling
  String _searchQuery = '';
  final List<int> _matchIndices = [];
  int _currentMatchIndex = -1;
  final ItemScrollController _itemScrollController = ItemScrollController();
  final List<_ListItem> _displayItems = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NotificationService.instance.newMessageNotifier.addListener(_onNewMessageReceived);
    _avatarPath = widget.initialAvatarPath;
    _loadMessages();
  }

  @override
  void dispose() {
    NotificationService.instance.newMessageNotifier.removeListener(_onNewMessageReceived);
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  void _onNewMessageReceived() {
    if (mounted) {
      _loadMessages(isSilent: true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadMessages();
    }
  }

  Future<void> _loadMessages({bool isSilent = false}) async {
    if (!isSilent) {
      setState(() {
        _isLoading = true;
      });
    }

    // Mark all messages as read when opening the conversation
    await DatabaseHelper.instance.markMessagesAsRead(widget.sender);
    
    final messages = await DatabaseHelper.instance.getMessagesBySender(widget.sender);
    
    // Determine if this is a group chat (any message has isGroupChat = true)
    final isGroup = messages.any((msg) => msg.isGroupChat == true);
    
    // Get the most recent avatarPath (from any message that has one)
    String? latestAvatarPath;
    for (final msg in messages) {
      if (msg.avatarPath != null && msg.avatarPath!.isNotEmpty) {
        latestAvatarPath = msg.avatarPath;
        break; // Messages are sorted by timestamp DESC, so first one is most recent
      }
    }
    
    // Initialize avatars directory for sender avatar lookup in group chats
    if (_avatarsDir == null) {
      try {
        final supportDir = await getApplicationSupportDirectory();
        _avatarsDir = '${supportDir.path}/avatars';
      } catch (e) {
        // Fallback: derive from existing avatar path
        if (latestAvatarPath != null && latestAvatarPath.isNotEmpty) {
          _avatarsDir = File(latestAvatarPath).parent.path;
        }
      }
    }
    
    final allGroupSenders = messages.map((m) => m.senderName ?? m.sender).toSet().toList();
    allGroupSenders.sort();

    if (mounted) {
      setState(() {
        _messages = messages;
        _isGroupChat = isGroup;
        _groupMembers = allGroupSenders;
        _avatarPath = latestAvatarPath;
        _isLoading = false;
        
        _updateDisplayItems();
        
        if (_isSearching && _searchController.text.isNotEmpty) {
          _filterMessages(_searchController.text);
        }
      });
    }
  }

  void _updateDisplayItems() {
    _displayItems.clear();
    var activeMessages = _messages.where((msg) => msg.isDeleted != true).toList();
    
    if (_selectedSenders.isNotEmpty) {
      activeMessages = activeMessages.where((msg) => _selectedSenders.contains(msg.senderName ?? msg.sender)).toList();
    }
    
    // Deduplicate — include mediaPath in key so a "📷 Photo" message with a
    // captured image is not merged with one that has no image.
    final seen = <String>{};
    activeMessages = activeMessages.where((msg) {
      final key = '${msg.message}||${msg.timestamp.millisecondsSinceEpoch}||${msg.mediaPath ?? ''}';
      if (seen.contains(key)) return false;
      seen.add(key);
      return true;
    }).toList();

    if (activeMessages.isEmpty) return;
    
    // Build display items from Newest (index 0) to Oldest
    // activeMessages is descending (newest at index 0).
    for (int i = 0; i < activeMessages.length; i++) {
        final message = activeMessages[i];
        final messageDate = DateTime(message.timestamp.year, message.timestamp.month, message.timestamp.day);
        
        _displayItems.add(_ListItem(isHeader: false, message: message, messageIndex: i));
        
        // Add header after the last message of the day (which appears above it in UI)
        bool needsHeader = false;
        if (i == activeMessages.length - 1) {
            needsHeader = true;
        } else {
            final nextMessage = activeMessages[i + 1];
            final nextDate = DateTime(nextMessage.timestamp.year, nextMessage.timestamp.month, nextMessage.timestamp.day);
            if (!_isSameDay(messageDate, nextDate)) needsHeader = true;
        }
        
        if (needsHeader) {
            _displayItems.add(_ListItem(isHeader: true, date: messageDate));
        }
    }
  }

  void _filterMessages(String query) {
    setState(() {
      _searchQuery = query;
      _matchIndices.clear();
      
      if (query.isNotEmpty) {
        final queryLower = query.toLowerCase();
        
        // Find matches in display items
        for (int i = 0; i < _displayItems.length; i++) {
          final item = _displayItems[i];
          if (!item.isHeader && item.message != null) {
            final text = item.message!.message.toLowerCase();
            final sender = item.message!.senderName?.toLowerCase() ?? '';
            if (text.contains(queryLower) || sender.contains(queryLower)) {
              _matchIndices.add(i); // i is the index in _displayItems
            }
          }
        }
        
        if (_matchIndices.isNotEmpty) {
          _currentMatchIndex = 0; 
          _scrollToCurrentMatch();
        } else {
          _currentMatchIndex = -1;
        }
      } else {
        _currentMatchIndex = -1;
      }
    });
  }

  void _scrollToCurrentMatch() {
    if (_currentMatchIndex >= 0 && _currentMatchIndex < _matchIndices.length) {
      if (_itemScrollController.isAttached) {
        final index = _matchIndices[_currentMatchIndex];
        _itemScrollController.scrollTo(
          index: index,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          alignment: 0.5, 
        );
      }
    }
  }

  void _nextMatch() {
    if (_matchIndices.isEmpty) return;
    setState(() {
      if (_currentMatchIndex < _matchIndices.length - 1) {
        _currentMatchIndex++;
        _scrollToCurrentMatch();
      }
    });
  }

  void _previousMatch() {
    setState(() {
      if (_currentMatchIndex > 0) {
        _currentMatchIndex--;
        _scrollToCurrentMatch();
      }
    });
  }

  void _showFilterDialog() {
    String searchQuery = '';
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.grey.shade900,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final filteredMembers = _groupMembers
                .where((m) => m.toLowerCase().contains(searchQuery.toLowerCase()))
                .toList();

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                height: MediaQuery.of(context).size.height * 0.7,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Filter by Sender',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            setModalState(() {
                              _selectedSenders.clear();
                            });
                            setState(() {
                              _updateDisplayItems();
                            });
                          },
                          child: const Text('Clear All', style: TextStyle(color: Colors.orangeAccent)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'Search members...',
                        hintStyle: TextStyle(color: Colors.grey.shade500),
                        prefixIcon: Icon(Icons.search, color: Colors.grey.shade400),
                        filled: true,
                        fillColor: Colors.grey.shade800,
                        contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onChanged: (val) {
                        setModalState(() {
                          searchQuery = val;
                        });
                      },
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: filteredMembers.isEmpty
                          ? Center(
                              child: Text(
                                'No members found',
                                style: TextStyle(color: Colors.grey.shade500),
                              ),
                            )
                          : ListView.builder(
                              itemCount: filteredMembers.length,
                              itemBuilder: (context, index) {
                                final member = filteredMembers[index];
                                final isSelected = _selectedSenders.contains(member);
                                return CheckboxListTile(
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                                  secondary: _buildSenderAvatar(member, _getSenderColor(member)),
                                  title: Text(member, style: const TextStyle(color: Colors.white, fontSize: 16)),
                                  value: isSelected,
                                  activeColor: Colors.orangeAccent,
                                  checkColor: Colors.black,
                                  controlAffinity: ListTileControlAffinity.trailing,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  checkboxShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                                  onChanged: (val) {
                                    setModalState(() {
                                      if (val == true) {
                                        _selectedSenders.add(member);
                                      } else {
                                        _selectedSenders.remove(member);
                                      }
                                    });
                                    setState(() {
                                      _updateDisplayItems();
                                    });
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _getAppIcon(String packageName, {double size = 12, Color? color}) {
    if (packageName.contains('whatsapp')) {
      return FaIcon(FontAwesomeIcons.whatsapp, size: size, color: color ?? Colors.green);
    } else if (packageName.contains('instagram')) {
      return FaIcon(FontAwesomeIcons.instagram, size: size, color: color ?? Colors.pinkAccent);
    }
    return Icon(Icons.notifications, size: size, color: color ?? Colors.grey);
  }

  // Sanitize text to remove invalid UTF-16 characters that could crash the app
  String _sanitizeText(String? text) {
    if (text == null || text.isEmpty) return '';
    try {
      // Dart's Runes iterator naturally handles surrogate pairs correctly 
      // and replaces isolated surrogates with the replacement character U+FFFD.
      return String.fromCharCodes(text.runes);
    } catch (e) {
      // If anything fails, return a safe fallback
      return text.replaceAll(RegExp(r'[\uD800-\uDFFF]'), '\uFFFD');
    }
  }

  // Format time in AM/PM format for individual messages
  String _formatMessageTime(DateTime timestamp) {
    return DateFormat('h:mm a').format(timestamp); // e.g., "2:30 PM"
  }

  // Format date header WhatsApp-style
  String _formatDateHeader(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final messageDate = DateTime(date.year, date.month, date.day);

    if (messageDate == today) {
      return 'Today';
    } else if (messageDate == yesterday) {
      return 'Yesterday';
    } else if (now.year == date.year) {
      return DateFormat('MMMM dd').format(date); // e.g., "November 23"
    } else {
      return DateFormat('MMMM dd, yyyy').format(date); // e.g., "November 23, 2024"
    }
  }

  // Check if two dates are on the same day
  bool _isSameDay(DateTime date1, DateTime date2) {
    return date1.year == date2.year &&
           date1.month == date2.month &&
           date1.day == date2.day;
  }

  // Generate a consistent color for sender names in group chats
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

  // Build avatar widget with profile picture or fallback to letter/group icon
  Widget _buildAvatarWidget() {
    final bool hasAvatar = _avatarPath != null && 
                           _avatarPath!.isNotEmpty && 
                           File(_avatarPath!).existsSync();
    
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        gradient: hasAvatar ? null : LinearGradient(
          colors: _isGroupChat 
            ? [Colors.teal.shade400, Colors.cyan.shade500]
            : [Colors.deepPurple.shade400, Colors.purple.shade500],
        ),
        shape: BoxShape.circle,
        image: hasAvatar ? DecorationImage(
          image: FileImage(File(_avatarPath!)),
          fit: BoxFit.cover,
        ) : null,
      ),
      child: hasAvatar ? null : Center(
        child: _isGroupChat
          ? const Icon(Icons.group, color: Colors.white, size: 20)
          : Text(
              widget.sender.isNotEmpty ? widget.sender.characters.first.toUpperCase() : '?',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: _isGroupChat 
                ? [Colors.teal.shade800, Colors.cyan.shade900]
                : [Colors.deepPurple.shade800, Colors.purple.shade900],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Search messages...',
                  hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
                  border: InputBorder.none,
                ),
                onChanged: _filterMessages,
              )
            : Row(
                children: [
                  // Avatar
                  _buildAvatarWidget(),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _sanitizeText(widget.sender),
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Row(
                          children: [
                            _getAppIcon(widget.app, size: 12),
                            const SizedBox(width: 4),
                            Text(
                              _isGroupChat ? 'Group Chat' : 'Private Chat',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade300,
                              ),
                            ),
                            if (_messages.isNotEmpty) ...[
                              Flexible(
                                child: Text(
                                  ' • ${_displayItems.where((item) => !item.isHeader).length} messages',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade400,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
        actions: [
          if (_isSearching && _matchIndices.isNotEmpty) ...[
            Center(
              child: Text(
                '${_currentMatchIndex + 1}/${_matchIndices.length}',
                style: const TextStyle(fontSize: 14),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_up),
              onPressed: _currentMatchIndex < _matchIndices.length - 1 ? _nextMatch : null,
              tooltip: 'Older messages',
            ),
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_down),
              onPressed: _currentMatchIndex > 0 ? _previousMatch : null,
              tooltip: 'Newer messages',
            ),
          ],
          if (_isGroupChat)
            IconButton(
              icon: Icon(
                _selectedSenders.isNotEmpty ? Icons.filter_list_alt : Icons.filter_list,
                color: _selectedSenders.isNotEmpty ? Colors.orangeAccent : Colors.white,
              ),
              onPressed: _showFilterDialog,
              tooltip: 'Filter by sender',
            ),
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                if (_isSearching) {
                  _isSearching = false;
                  _searchController.clear();
                  _searchQuery = '';
                  _matchIndices.clear();
                  _currentMatchIndex = -1;
                  FocusScope.of(context).unfocus();
                } else {
                  _isSearching = true;
                }
              });
            },
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Colors.grey.shade900,
              Colors.black87,
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: _isLoading
            ? const Center(
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.deepPurple),
                ),
              )
            : _messages.isEmpty
                ? _buildEmptyState('No messages yet', 'Messages from ${_sanitizeText(widget.sender)} will appear here')
                : _buildMessageList(),
      ),
    );
  }

  Widget _buildEmptyState(String title, String subtitle) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.grey.shade800.withValues(alpha: 0.5),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.chat_bubble_outline,
              size: 60,
              color: Colors.grey.shade600,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            title,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade600,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList() {
    if (_displayItems.isEmpty) {
      if (_isSearching && _searchQuery.isNotEmpty) {
         return _buildEmptyState('No matches', 'Try searching with a different term');
      }
      return _buildEmptyState('No messages yet', 'Messages from ${_sanitizeText(widget.sender)} will appear here');
    }
    
    return ScrollablePositionedList.builder(
      padding: const EdgeInsets.all(16),
      reverse: true,
      itemCount: _displayItems.length,
      itemScrollController: _itemScrollController,
      itemBuilder: (context, index) {
        return _buildListItem(index);
      },
    );
  }

  // Build either a date header or message bubble
  Widget _buildListItem(int index) {
    if (index < 0 || index >= _displayItems.length) {
      return const SizedBox.shrink();
    }
    
    final item = _displayItems[index];

    if (item.isHeader) {
      return _buildDateHeader(item.date!);
    } else {
      // Get the previous message (visually above) for grouping logic.
      // Since index 0 is at bottom, visually above is index + 1
      String? previousSenderName;
      if (index + 1 < _displayItems.length) {
        final prevItem = _displayItems[index + 1];
        if (!prevItem.isHeader && prevItem.message != null) {
          previousSenderName = _sanitizeText(prevItem.message!.senderName ?? prevItem.message!.sender);
        }
      }
      
      final isMatched = _matchIndices.contains(index);
      final isCurrentMatch = _currentMatchIndex >= 0 && _matchIndices.isNotEmpty && _matchIndices[_currentMatchIndex] == index;
      
      return _buildMessageBubble(
        item.message!,
        previousSenderName,
        isMatched: isMatched,
        isCurrentMatch: isCurrentMatch,
      );
    }
  }

  // Build date header widget
  Widget _buildDateHeader(DateTime date) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.grey.shade800.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Text(
            _formatDateHeader(date),
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey.shade400,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ),
    );
  }

  // Build sender avatar widget — tries to load the sender's actual DP file,
  // falls back to letter initial if not available
  Widget _buildSenderAvatar(String senderName, Color senderColor) {
    // Try to find sender-specific avatar file saved by native code
    if (_avatarsDir != null) {
      final appPrefix = widget.app.contains('whatsapp') ? 'wa' :
                         widget.app.contains('instagram') ? 'ig' : 'other';
      final safeName = senderName.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final truncatedName = safeName.length > 50 ? safeName.substring(0, 50) : safeName;
      final avatarFile = File('$_avatarsDir/${appPrefix}_sender_$truncatedName.png');
      
      if (avatarFile.existsSync()) {
        return Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            image: DecorationImage(
              image: FileImage(avatarFile),
              fit: BoxFit.cover,
            ),
            border: Border.all(
              color: senderColor.withValues(alpha: 0.5),
              width: 1,
            ),
          ),
        );
      }
    }
    
    // Fallback: letter initial
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: senderColor.withValues(alpha: 0.2),
        shape: BoxShape.circle,
        border: Border.all(
          color: senderColor.withValues(alpha: 0.5),
          width: 1,
        ),
      ),
      child: Center(
        child: Text(
          senderName.isNotEmpty ? senderName.characters.first.toUpperCase() : '?',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: senderColor,
          ),
        ),
      ),
    );
  }

  /// Show options menu when long-pressing a message (copy, view full image, etc.)
  void _showMessageOptions(BuildContext context, MessageModel message) {
    final senderName = _sanitizeText(message.senderName ?? message.sender);
    final hasImage = message.mediaPath != null &&
        message.mediaPath!.isNotEmpty &&
        File(message.mediaPath!).existsSync();
    final isMedia = _isGenericMediaLabel(message.message);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey.shade900,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle bar
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade600,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Message preview — show icon for media messages
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: isMedia && !hasImage
                    ? Row(
                        children: [
                          Icon(_mediaTypeInfo(message.message).icon,
                              color: _mediaTypeInfo(message.message).color,
                              size: 16),
                          const SizedBox(width: 8),
                          Text(
                            _mediaTypeInfo(message.message).label,
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey.shade400,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                      )
                    : Text(
                        _sanitizeText(message.message).length > 100
                            ? '${_sanitizeText(message.message).substring(0, 100)}...'
                            : _sanitizeText(message.message),
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade400,
                          fontStyle: FontStyle.italic,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
              ),
              const Divider(height: 1, color: Colors.grey),

              // ── View full image (only when file exists) ────────────────
              if (hasImage)
                ListTile(
                  leading: const Icon(Icons.fullscreen, color: Colors.white70),
                  title: const Text('View full image',
                      style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(ctx);
                    final heroTag =
                        'media_${message.id ?? message.mediaPath.hashCode}';
                    _openFullScreenImage(message.mediaPath!, heroTag);
                  },
                ),

              // ── Copy message text ─────────────────────────────────────
              if (!isMedia || !hasImage)
                ListTile(
                  leading: const Icon(Icons.copy, color: Colors.white70),
                  title: const Text('Copy message',
                      style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Clipboard.setData(
                        ClipboardData(text: message.message));
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: const Text('Message copied to clipboard'),
                        backgroundColor:
                            Colors.white.withValues(alpha: 0.7),
                        behavior: SnackBarBehavior.floating,
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  },
                ),

              // ── Copy with sender info (group chats) ───────────────────
              if (_isGroupChat && (!isMedia || !hasImage))
                ListTile(
                  leading:
                      const Icon(Icons.content_copy, color: Colors.white70),
                  title: const Text('Copy with sender info',
                      style: TextStyle(color: Colors.white)),
                  onTap: () {
                    final formattedTime =
                        _formatMessageTime(message.timestamp);
                    final textToCopy =
                        '[$formattedTime] $senderName: ${message.message}';
                    Clipboard.setData(ClipboardData(text: textToCopy));
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content:
                            const Text('Message with sender info copied'),
                        backgroundColor: Colors.grey.shade800,
                        behavior: SnackBarBehavior.floating,
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  },
                ),

              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHighlightText(String text, bool isCurrentMatch) {
    if (_searchQuery.isEmpty) return Text(text, style: const TextStyle(fontSize: 15, color: Colors.white, height: 1.4));
    
    final queryStr = _searchQuery.toLowerCase();
    final lowerText = text.toLowerCase();
    final spans = <TextSpan>[];
    int start = 0;
    
    while (true) {
      final index = lowerText.indexOf(queryStr, start);
      if (index == -1) {
        spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      
      if (index > start) {
        spans.add(TextSpan(text: text.substring(start, index)));
      }
      
      spans.add(TextSpan(
        text: text.substring(index, index + queryStr.length),
        style: TextStyle(
          backgroundColor: isCurrentMatch ? Colors.orange : Colors.yellow.withValues(alpha: 0.5),
          color: isCurrentMatch ? Colors.black : Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ));
      
      start = index + queryStr.length;
    }
    
    return RichText(
      text: TextSpan(
        style: const TextStyle(fontSize: 15, color: Colors.white, height: 1.4),
        children: spans,
      ),
    );
  }

  Widget _buildMessageBubble(
    MessageModel message, 
    String? previousSenderName, {
    bool isMatched = false,
    bool isCurrentMatch = false,
  }) {
    final senderName = _sanitizeText(message.senderName ?? message.sender);

    // Determine if we should show the sender name header
    // Show it in group chats when the sender changes from the previous message
    bool showSenderHeader = _isGroupChat && senderName != previousSenderName;
    
    // Get sender color for group chats
    final senderColor = _getSenderColor(senderName);
    
    return Padding(
      padding: EdgeInsets.only(
        bottom: 4,
        top: showSenderHeader ? 12 : 0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Sender name header for group chats
          if (showSenderHeader)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 6),
              child: Row(
                children: [
                  _buildSenderAvatar(senderName, senderColor),
                  const SizedBox(width: 8),
                  Text(
                    senderName,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: senderColor,
                    ),
                  ),
                ],
              ),
            ),
          // Message bubble — long press to copy
          GestureDetector(
            onLongPress: () => _showMessageOptions(context, message),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                gradient: isCurrentMatch
                    ? LinearGradient(
                        colors: [Colors.orange.shade800.withValues(alpha: 0.9), Colors.deepOrange.shade900.withValues(alpha: 0.8)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      )
                    : LinearGradient(
                        colors: _isGroupChat
                            ? [senderColor.withValues(alpha: 0.15), senderColor.withValues(alpha: 0.08)]
                            : [Colors.deepPurple.shade800.withValues(alpha: 0.5), Colors.purple.shade900.withValues(alpha: 0.3)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isCurrentMatch
                      ? Colors.orangeAccent
                      : _isGroupChat 
                          ? senderColor.withValues(alpha: 0.3) 
                          : Colors.deepPurple.shade600.withValues(alpha: 0.3),
                  width: isCurrentMatch ? 2 : 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Media content: real image OR placeholder ──────────────
                  _buildMediaContent(message, isCurrentMatch),
                  // ── Timestamp + read tick ─────────────────────────────────
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _formatMessageTime(message.timestamp),
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade500,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        message.isRead == true ? Icons.done_all : Icons.done,
                        size: 14,
                        color: message.isRead == true
                            ? Colors.blue.shade300
                            : Colors.grey.shade600,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════
  // MEDIA RENDERING
  // ══════════════════════════════════════════════════════════════════════

  /// Decides what to render for a message's media content:
  ///
  /// Priority order (fallback chain):
  ///   1. Real image file exists at mediaPath  → show actual image
  ///   2. Message is a known media label       → show styled placeholder
  ///      (file not captured yet — hook for SAF path once Phase 2 ships)
  ///   3. Neither                              → show message text only
  Widget _buildMediaContent(MessageModel message, bool isCurrentMatch) {
    final isWhatsApp = message.app.toLowerCase().contains('whatsapp');
    final mediaPath = message.mediaPath;
    final hasFile = mediaPath != null &&
        mediaPath.isNotEmpty &&
        File(mediaPath).existsSync();
    final isMedia = isWhatsApp && _isGenericMediaLabel(message.message);

    if (hasFile) {
      // ── Case 1: We have the actual captured image ─────────────────────
      final isGeneric = _isGenericMediaLabel(message.message);
      final hasCaption = !isGeneric && message.message.trim().isNotEmpty;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildRealImage(message, mediaPath),
          if (hasCaption) ...[
            const SizedBox(height: 6),
            _buildHighlightText(_sanitizeText(message.message), isCurrentMatch),
          ],
          const SizedBox(height: 8),
        ],
      );
    }

    if (isMedia) {
      // ── Case 2: Media was sent but file wasn't captured ───────────────
      // Show an informative placeholder. When SAF captures the real file
      // and updates mediaPath, this branch will never be reached again.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildMediaPlaceholder(message.message),
          const SizedBox(height: 8),
        ],
      );
    }

    // ── Case 3: Plain text message ────────────────────────────────────
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHighlightText(_sanitizeText(message.message), isCurrentMatch),
        const SizedBox(height: 6),
      ],
    );
  }

  /// Renders the captured image or a video/audio placeholder with a tap-to-fullscreen hero.
  Widget _buildRealImage(MessageModel message, String path) {
    final heroTag = 'media_${message.id ?? path.hashCode}';
    final ext = path.toLowerCase().split('.').last;
    final isVideo = ['mp4', 'mov', 'avi', 'mkv'].contains(ext);
    final isAudio = ['mp3', 'm4a', 'wav', 'ogg', 'opus', 'aac'].contains(ext);
    final mediaType = isVideo ? 'video' : (isAudio ? 'audio' : 'image');

    return GestureDetector(
      onTap: () => _openFullScreenImage(path, heroTag, type: mediaType),
      child: Hero(
        tag: heroTag,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: (isVideo || isAudio)
            ? Stack(
                alignment: Alignment.center,
                children: [
                  if (isVideo)
                    SizedBox(
                      width: double.infinity,
                      height: 220,
                      child: VideoThumbnailWidget(videoPath: path),
                    )
                  else
                    Container(
                      width: double.infinity,
                      height: 220,
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.15),
                        border: Border.all(
                          color: Colors.orange.withValues(alpha: 0.3),
                        ),
                      ),
                      child: const Center(
                        child: Icon(Icons.mic, color: Colors.orange, size: 64),
                      ),
                    ),
                  
                  // Play overlay for both video and audio
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 38,
                    ),
                  ),

                  // Optional label for Audio
                  if (isAudio)
                    Positioned(
                      bottom: 24,
                      child: Text(
                        'Voice Note',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.white.withValues(alpha: 0.9),
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                ],
              )
            : Stack(
                children: [
                  Image.file(
                    File(path),
                    fit: BoxFit.cover,
                    width: double.infinity,
                    height: 220,
                    errorBuilder: (_, __, ___) => _buildImageError(),
                  ),
                  // Tap-to-expand affordance
                  Positioned(
                    bottom: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Icon(
                        Icons.fullscreen,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                  ),
                ],
              ),
        ),
      ),
    );
  }

  /// Styled placeholder for media messages where the file wasn't captured
  /// (e.g. the notification carried no BigPicture, or SAF is not yet set up).
  Widget _buildMediaPlaceholder(String rawLabel) {
    final info = _mediaTypeInfo(rawLabel);
    return GestureDetector(
      onTap: () async {
        final hasSaf = await NotificationService.instance.getSafPermissionStatus();
        final text = hasSaf 
            ? 'Media not found on device. It may have been deleted before downloading, or Auto-Download is disabled in WhatsApp.'
            : 'Full media capture coming — grant WhatsApp folder access in Settings.';
            
        if (!mounted) return;
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(info.icon, color: Colors.white70, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    style: const TextStyle(fontSize: 13, color: Colors.white),
                  ),
                ),
              ],
            ),
            backgroundColor: Colors.grey.shade800,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: LinearGradient(
            colors: [
              info.color.withValues(alpha: 0.18),
              info.color.withValues(alpha: 0.08),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(
            color: info.color.withValues(alpha: 0.35),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: info.color.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: Icon(info.icon, color: info.color, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    info.label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.white.withValues(alpha: 0.9),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Tap to learn more',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade500,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: info.color.withValues(alpha: 0.6),
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImageError() {
    return Container(
      height: 80,
      color: Colors.grey.shade900,
      child: Center(
        child: Icon(Icons.broken_image_outlined,
            color: Colors.grey.shade600, size: 32),
      ),
    );
  }

  void _openFullScreenImage(String path, String heroTag, {String? type}) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black.withValues(alpha: 0.92),
        pageBuilder: (ctx, animation, _) {
          return FadeTransition(
            opacity: animation,
            child: FullScreenMediaViewer(path: path, heroTag: heroTag, type: type),
          );
        },
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════
  // MEDIA TYPE HELPERS
  // ══════════════════════════════════════════════════════════════════════

  /// Returns true if [text] is a generic notification label that adds no
  /// meaningful information when a media image is already shown, OR when we
  /// want to show a media placeholder instead of raw text.
  bool _isGenericMediaLabel(String text) {
    final lower = text.trim().toLowerCase();
    // Exact label matches (WhatsApp notification text)
    const labels = {
      'photo', 'image', 'video', 'sticker', 'gif',
      'image omitted', 'video omitted', 'audio omitted', 'sticker omitted',
      'voice message', 'voice message omitted', 'audio',
      'contact card', 'location', 'live location',
    };
    if (labels.contains(lower)) return true;

    // Emoji-prefixed labels WhatsApp uses in BigText
    const emojiPrefixes = ['📷', '📹', '🎤', '🎵', '🎞',
                           '🗺', '📍', '👤', '🎥', '🖼', '🎙'];
    for (final p in emojiPrefixes) {
      if (lower.startsWith(p)) return true;
    }

    // WhatsApp business/group media patterns: "Name: 📷 Photo" or "Name: image"
    final colonIdx = lower.indexOf(':');
    if (colonIdx > 0 && colonIdx < lower.length - 1) {
      final afterColon = lower.substring(colonIdx + 1).trim();
      if (labels.contains(afterColon)) return true;
      for (final p in emojiPrefixes) {
        if (afterColon.startsWith(p)) return true;
      }
    }

    return false;
  }

  _MediaTypeInfo _mediaTypeInfo(String rawLabel) {
    final lower = rawLabel.trim().toLowerCase();
    if (lower.contains('voice') || lower.contains('audio') ||
        lower.contains('🎤') || lower.contains('🎵') || lower.contains('🎙')) {
      return _MediaTypeInfo(
        icon: Icons.mic_rounded,
        color: Colors.deepPurple.shade300,
        label: 'Voice Message',
      );
    }
    if (lower.contains('video') || lower.contains('📹') || lower.contains('🎥')) {
      return _MediaTypeInfo(
        icon: Icons.videocam_rounded,
        color: Colors.blue.shade300,
        label: 'Video',
      );
    }
    if (lower.contains('sticker') || lower.contains('gif')) {
      return _MediaTypeInfo(
        icon: Icons.emoji_emotions_rounded,
        color: Colors.amber.shade300,
        label: 'Sticker / GIF',
      );
    }
    if (lower.contains('document') || lower.contains('file') || lower.contains('📄') || lower.contains('📎')) {
      return _MediaTypeInfo(
        icon: Icons.insert_drive_file_rounded,
        color: Colors.teal.shade300,
        label: 'Document',
      );
    }
    if (lower.contains('location') || lower.contains('🗺') || lower.contains('📍')) {
      return _MediaTypeInfo(
        icon: Icons.location_on_rounded,
        color: Colors.red.shade300,
        label: 'Location',
      );
    }
    // Default: image / photo
    return _MediaTypeInfo(
      icon: Icons.image_rounded,
      color: Colors.green.shade300,
      label: 'Photo',
    );
  }
}
// ══════════════════════════════════════════════════════════════════════
// MODELS
// ══════════════════════════════════════════════════════════════════════

class _MediaTypeInfo {
  final IconData icon;
  final Color color;
  final String label;
  const _MediaTypeInfo({
    required this.icon,
    required this.color,
    required this.label,
  });
}

// Helper class for list items (either date header or message)
class _ListItem {
  final bool isHeader;
  final DateTime? date;
  final MessageModel? message;
  final int? messageIndex;

  _ListItem({
    required this.isHeader,
    this.date,
    this.message,
    this.messageIndex,
  });
}

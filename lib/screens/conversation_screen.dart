import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../models/message_model.dart';
import '../services/database_helper.dart';

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
    _avatarPath = widget.initialAvatarPath;
    _loadMessages();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadMessages();
    }
  }

  Future<void> _loadMessages() async {
    setState(() {
      _isLoading = true;
    });

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
    
    setState(() {
      _messages = messages;
      _isGroupChat = isGroup;
      _avatarPath = latestAvatarPath;
      _isLoading = false;
      
      _updateDisplayItems();
      
      if (_isSearching && _searchController.text.isNotEmpty) {
        _filterMessages(_searchController.text);
      }
    });
  }

  void _updateDisplayItems() {
    _displayItems.clear();
    var activeMessages = _messages.where((msg) => msg.isDeleted != true).toList();
    
    // Deduplicate
    final seen = <String>{};
    activeMessages = activeMessages.where((msg) {
      final key = '${msg.message}||${msg.timestamp.millisecondsSinceEpoch}';
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
    if (_matchIndices.isEmpty) return;
    setState(() {
      if (_currentMatchIndex > 0) {
        _currentMatchIndex--;
        _scrollToCurrentMatch();
      }
    });
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
      // Remove isolated surrogate code units which cause UTF-16 errors
      final buffer = StringBuffer();
      for (int i = 0; i < text.length; i++) {
        final codeUnit = text.codeUnitAt(i);
        // Check if it's a high surrogate (0xD800-0xDBFF)
        if (codeUnit >= 0xD800 && codeUnit <= 0xDBFF) {
          // Check if next character is a valid low surrogate
          if (i + 1 < text.length) {
            final nextCodeUnit = text.codeUnitAt(i + 1);
            if (nextCodeUnit >= 0xDC00 && nextCodeUnit <= 0xDFFF) {
              // Valid surrogate pair - keep both
              buffer.writeCharCode(codeUnit);
              buffer.writeCharCode(nextCodeUnit);
              i++; // Skip the low surrogate
              continue;
            }
          }
          // Isolated high surrogate - replace with replacement character
          buffer.write('\uFFFD');
        } else if (codeUnit >= 0xDC00 && codeUnit <= 0xDFFF) {
          // Isolated low surrogate - replace with replacement character
          buffer.write('\uFFFD');
        } else {
          buffer.writeCharCode(codeUnit);
        }
      }
      return buffer.toString();
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
              widget.sender.isNotEmpty ? widget.sender[0].toUpperCase() : '?',
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
                              Text(
                                ' • ${_messages.length} messages',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade400,
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
          senderName.isNotEmpty ? senderName[0].toUpperCase() : '?',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: senderColor,
          ),
        ),
      ),
    );
  }

  /// Show options menu when long-pressing a message (copy, etc.)
  void _showMessageOptions(BuildContext context, MessageModel message) {
    final senderName = _sanitizeText(message.senderName ?? message.sender);
    
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
              // Message preview
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
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
              // Copy message text
              ListTile(
                leading: const Icon(Icons.copy, color: Colors.white70),
                title: const Text('Copy message', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: message.message));
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text('Message copied to clipboard'),
                      backgroundColor: Colors.white.withValues(alpha: 0.7),
                      behavior: SnackBarBehavior.floating,
                      duration: const Duration(seconds: 2),
                    ),
                  );
                },
              ),
              // Copy with sender name and timestamp
              if (_isGroupChat)
                ListTile(
                  leading: const Icon(Icons.content_copy, color: Colors.white70),
                  title: const Text('Copy with sender info', style: TextStyle(color: Colors.white)),
                  onTap: () {
                    final formattedTime = _formatMessageTime(message.timestamp);
                    final textToCopy = '[$formattedTime] $senderName: ${message.message}';
                    Clipboard.setData(ClipboardData(text: textToCopy));
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: const Text('Message with sender info copied'),
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
                  // Media image preview (photo / sticker / video thumbnail)
                  if (message.mediaPath != null &&
                      message.mediaPath!.isNotEmpty &&
                      File(message.mediaPath!).existsSync()) ...[  
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(
                        File(message.mediaPath!),
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: 200,
                        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  // Message text — hide if it's just a generic media label and image is shown
                  if (!_isGenericMediaLabel(message.message) ||
                      message.mediaPath == null ||
                      message.mediaPath!.isEmpty ||
                      !File(message.mediaPath!).existsSync()) ...[  
                    _buildHighlightText(_sanitizeText(message.message), isCurrentMatch),
                    const SizedBox(height: 6),
                  ],
                  // Timestamp and read status
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
  /// Returns true if [text] is a generic notification label that adds no
  /// meaningful information when a media image is already shown.
  bool _isGenericMediaLabel(String text) {
    final lower = text.trim().toLowerCase();
    const labels = {
      'photo', 'image', 'video', 'sticker', 'gif', 'document',
      'image omitted', 'video omitted', 'audio omitted',
      'voice message', 'voice message omitted',
    };
    if (labels.contains(lower)) {
      return true;
    }
    if (lower.startsWith('📷') || lower.startsWith('📹') ||
        lower.startsWith('🎤') || lower.startsWith('🎵') ||
        lower.startsWith('🎞')) {
      return true;
    }
    return false;
  }
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

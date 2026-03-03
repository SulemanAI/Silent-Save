import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:path_provider/path_provider.dart';
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
        title: Row(
          children: [
            // Avatar
            _buildAvatarWidget(),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.sender,
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
                ? _buildEmptyState()
                : _buildMessageList(),
      ),
    );
  }

  Widget _buildEmptyState() {
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
            'No messages yet',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Messages from ${widget.sender} will appear here',
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
    // Filter out deleted messages
    var activeMessages = _messages
        .where((msg) => msg.isDeleted != true)
        .toList();
    
    // Deduplicate messages with identical content and timestamp
    final seen = <String>{};
    activeMessages = activeMessages.where((msg) {
      final key = '${msg.message}||${msg.timestamp.millisecondsSinceEpoch}';
      if (seen.contains(key)) return false;
      seen.add(key);
      return true;
    }).toList();
    
    if (activeMessages.isEmpty) {
      return _buildEmptyState();
    }
    
    // Messages come from DB in DESC order (newest first)
    // With reverse: true on ListView:
    //   - index 0 appears at the BOTTOM of the screen
    //   - last index appears at the TOP of the screen
    // So we need newest message at index 0 (bottom) and oldest at last index (top)
    // This means we keep the DESC order (newest first) - don't reverse!
    // 
    // WhatsApp behavior:
    //   - Open chat → see newest message at bottom
    //   - Scroll UP → older messages revealed at top
    
    // Build list with date headers
    // reverse: true makes the list start from the bottom (newest visible first)
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      reverse: true,
      itemCount: _getListItemCount(activeMessages),
      itemBuilder: (context, index) {
        return _buildListItem(activeMessages, index);
      },
    );
  }

  // Calculate total items including date headers
  // Messages are in DESC order (newest first), but we display bottom-to-top
  // so we iterate in reverse (oldest to newest in display order from top to bottom)
  int _getListItemCount(List<MessageModel> messages) {
    if (messages.isEmpty) return 0;
    
    int count = messages.length; // All messages
    DateTime? lastDate;
    
    // Iterate in reverse (oldest to newest) to count date headers
    for (int i = messages.length - 1; i >= 0; i--) {
      final message = messages[i];
      final messageDate = DateTime(
        message.timestamp.year,
        message.timestamp.month,
        message.timestamp.day,
      );
      
      if (lastDate == null || !_isSameDay(lastDate, messageDate)) {
        count++; // Add 1 for date header
        lastDate = messageDate;
      }
    }
    
    return count;
  }

  // Build either a date header or message bubble
  // With reverse:true, index 0 is at bottom, last index is at top
  // Messages are in DESC order (index 0 = newest, last = oldest)
  // We need to map display indices to actual messages and date headers
  Widget _buildListItem(List<MessageModel> messages, int index) {
    // Build a list of items (messages + headers) in display order
    // Display order for reverse:true: index 0 at bottom, so we want:
    //   index 0 = newest message
    //   Then going up (increasing index): older messages and date headers
    
    // We'll iterate through messages in ASC order (oldest first, for building top-to-bottom)
    // Then map the requested index to the correct item
    
    final items = <_ListItem>[];
    DateTime? lastDate;
    
    // Build items from oldest to newest (top to bottom in final display)
    for (int i = messages.length - 1; i >= 0; i--) {
      final message = messages[i];
      final messageDate = DateTime(
        message.timestamp.year,
        message.timestamp.month,
        message.timestamp.day,
      );
      
      // Check if we need a date header before this message
      if (lastDate == null || !_isSameDay(lastDate, messageDate)) {
        items.add(_ListItem(isHeader: true, date: messageDate));
        lastDate = messageDate;
      }
      
      items.add(_ListItem(isHeader: false, message: message, messageIndex: i));
    }
    
    // Since reverse:true, index 0 should be the last item (newest at bottom)
    // So we access items from the end
    final reversedIndex = items.length - 1 - index;
    
    if (reversedIndex < 0 || reversedIndex >= items.length) {
      return const SizedBox.shrink();
    }
    
    final item = items[reversedIndex];
    
    if (item.isHeader) {
      return _buildDateHeader(item.date!);
    } else {
      // Get the previous message (visually above) for grouping logic
      // In our items list (oldest=0, newest=end), reversedIndex - 1 is the item above in display
      String? previousSenderName;
      if (reversedIndex - 1 >= 0) {
        final prevItem = items[reversedIndex - 1];
        if (!prevItem.isHeader && prevItem.message != null) {
          previousSenderName = prevItem.message!.senderName ?? prevItem.message!.sender;
        }
      }
      return _buildMessageBubble(item.message!, previousSenderName);
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
            color: Colors.grey.shade800.withOpacity(0.8),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
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
              color: senderColor.withOpacity(0.5),
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
        color: senderColor.withOpacity(0.2),
        shape: BoxShape.circle,
        border: Border.all(
          color: senderColor.withOpacity(0.5),
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
    final senderName = message.senderName ?? message.sender;
    
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

  Widget _buildMessageBubble(MessageModel message, String? previousSenderName) {
    final senderName = message.senderName ?? message.sender;
    
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
                gradient: LinearGradient(
                  colors: _isGroupChat
                      ? [senderColor.withOpacity(0.15), senderColor.withOpacity(0.08)]
                      : [Colors.deepPurple.shade800.withOpacity(0.5), Colors.purple.shade900.withOpacity(0.3)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _isGroupChat 
                      ? senderColor.withOpacity(0.3) 
                      : Colors.deepPurple.shade600.withOpacity(0.3),
                  width: 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Message text
                  Text(
                    _sanitizeText(message.message),
                    style: const TextStyle(
                      fontSize: 15,
                      color: Colors.white,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 6),
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

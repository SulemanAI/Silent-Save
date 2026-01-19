import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/database_helper.dart';
import '../services/notification_service.dart';
import '../services/encryption_service.dart';
import 'conversation_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _conversations = [];
  List<Map<String, dynamic>> _filteredConversations = [];
  bool _isLoading = true;
  bool _hasPermission = false;
  bool _encryptionEnabled = false;
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 2, vsync: this);
    _checkPermission();
    _loadConversations();
    _checkEncryption();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // App resumed from background - refresh conversations (which includes refreshing notifications)
      _loadConversations();
      _checkPermission();
    }
  }

  Future<void> _checkPermission() async {
    final hasPermission = await NotificationService.instance.isNotificationPermissionGranted();
    debugPrint('[HomeScreen] Notification permission status: $hasPermission');
    setState(() {
      _hasPermission = hasPermission;
    });
  }

  Future<void> _checkEncryption() async {
    final enabled = await EncryptionService.instance.isEncryptionEnabled();
    setState(() {
      _encryptionEnabled = enabled;
    });
  }

  Future<void> _loadConversations() async {
    setState(() {
      _isLoading = true;
    });

    try {
      // First, refresh notifications to process any pending ones (with timeout)
      await NotificationService.instance.refreshNotifications();
    } catch (e) {
      debugPrint('[HomeScreen] Error refreshing notifications: $e');
    }

    try {
      final conversations = await DatabaseHelper.instance.getConversations()
          .timeout(const Duration(seconds: 10), onTimeout: () {
        debugPrint('[HomeScreen] getConversations timed out');
        return <Map<String, dynamic>>[];
      });
      setState(() {
        _conversations = conversations;
        _filteredConversations = conversations;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('[HomeScreen] Error loading conversations: $e');
      setState(() {
        _conversations = [];
        _filteredConversations = [];
        _isLoading = false;
      });
    }
  }

  void _filterConversations(String query) {
    setState(() {
      if (query.isEmpty) {
        _filteredConversations = _conversations;
      } else {
        _filteredConversations = _conversations
            .where((conv) =>
                conv['sender'].toString().toLowerCase().contains(query.toLowerCase()))
            .toList();
      }
    });
  }

  Widget _getAppIconWidget(String packageName, {double size = 24}) {
    if (packageName.contains('whatsapp')) {
      return Image.asset(
        'assets/whatsapp_logo.png',
        width: size,
        height: size,
      );
    } else if (packageName.contains('instagram')) {
      return Image.asset(
        'assets/instagram_logo.png',
        width: size,
        height: size,
      );
    }
    return Icon(Icons.message, size: size);
  }

  String _formatTimestamp(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inDays == 0) {
      return DateFormat('HH:mm').format(date);
    } else if (difference.inDays == 1) {
      return 'Yesterday';
    } else if (difference.inDays < 7) {
      return DateFormat('EEEE').format(date);
    } else {
      return DateFormat('MMM dd').format(date);
    }
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

  void _toggleEncryption() async {
    final newValue = !_encryptionEnabled;
    
    if (newValue) {
      // Show warning before enabling
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Enable Encryption?'),
          content: const Text(
            'This will encrypt all future messages. Existing messages will remain unencrypted. '
            'Make sure to remember this setting, as losing encryption keys will make messages unreadable.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Enable'),
            ),
          ],
        ),
      );

      if (confirm != true) return;
    }

    await EncryptionService.instance.enableEncryption(newValue);
    setState(() {
      _encryptionEnabled = newValue;
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            newValue 
              ? 'Encryption enabled for future messages' 
              : 'Encryption disabled',
          ),
        ),
      );
    }
  }

  void _showEncryptionOptions() {
    showModalBottomSheet(
      context: context,
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  _encryptionEnabled ? Icons.lock : Icons.lock_open,
                  color: _encryptionEnabled ? Colors.green : Colors.grey,
                  size: 32,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Message Encryption',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _encryptionEnabled 
                          ? 'Messages are encrypted' 
                          : 'Messages are not encrypted',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade400,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _encryptionEnabled,
                  onChanged: (value) {
                    Navigator.pop(context);
                    _toggleEncryption();
                  },
                  activeColor: Colors.green,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Long-press the refresh button to access encryption settings',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade600,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Silent Save',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          GestureDetector(
            onTap: _loadConversations,
            onLongPress: _showEncryptionOptions,
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: null, // Handled by GestureDetector
              ),
            ),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(
              icon: Image.asset('assets/whatsapp_logo.png', width: 28, height: 28),
              text: 'WhatsApp',
            ),
            Tab(
              icon: Image.asset('assets/instagram_logo.png', width: 28, height: 28),
              text: 'Instagram',
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          if (!_hasPermission) _buildPermissionWarning(),
          _buildSearchBar(),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(
                    controller: _tabController,
                    children: [
                      _buildConversationList('com.whatsapp'),
                      _buildConversationList('com.instagram.android'),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildPermissionWarning() {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.orange.shade900.withOpacity(0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange, width: 1),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning, color: Colors.orange),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Notification Access Required',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Enable notification access to capture messages',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          FilledButton(
            onPressed: () async {
              await NotificationService.instance.openNotificationSettings();
              // Recheck permission after a delay
              Future.delayed(const Duration(seconds: 2), _checkPermission);
            },
            style: FilledButton.styleFrom(
              backgroundColor: Colors.orange,
            ),
            child: const Text('Enable'),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: TextField(
        controller: _searchController,
        onChanged: _filterConversations,
        decoration: InputDecoration(
          hintText: 'Search conversations...',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searchController.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _searchController.clear();
                    _filterConversations('');
                  },
                )
              : null,
          filled: true,
          fillColor: Colors.grey.shade900,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(String appPackage) {
    final appName = appPackage.contains('whatsapp') ? 'WhatsApp' : 'Instagram';
    final isWhatsApp = appPackage.contains('whatsapp');
    
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 120,
            height: 120,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.grey.shade800.withOpacity(0.5),
              shape: BoxShape.circle,
            ),
            child: Image.asset(
              isWhatsApp ? 'assets/whatsapp_logo.png' : 'assets/instagram_logo.png',
              fit: BoxFit.contain,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            _hasPermission
                ? 'No $appName messages yet'
                : 'Enable notification access to start',
            style: TextStyle(
              fontSize: 18,
              color: Colors.grey.shade600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _hasPermission
                ? 'Messages from $appName will appear here'
                : 'Tap the button above to grant permission',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade700,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildConversationList(String appPackage) {
    // Filter conversations for this specific app
    final appConversations = _filteredConversations
        .where((conv) => conv['app'].toString().contains(appPackage))
        .toList();
    
    if (appConversations.isEmpty) {
      return _buildEmptyState(appPackage);
    }
    
    return RefreshIndicator(
      onRefresh: _loadConversations,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: appConversations.length,
        itemBuilder: (context, index) {
          final conversation = appConversations[index];
          return _buildConversationCard(conversation);
        },
      ),
    );
  }

  Widget _buildConversationCard(Map<String, dynamic> conversation) {
    final bool isGroupChat = conversation['isGroupChat'] == 1;
    final int unreadCount = (conversation['unreadCount'] as int?) ?? 0;
    final String lastMessage = conversation['lastMessage']?.toString() ?? '';
    final String lastSenderName = conversation['lastSenderName']?.toString() ?? '';
    final String sender = conversation['sender']?.toString() ?? 'Unknown';
    final String? avatarPath = conversation['avatarPath']?.toString();
    
    // Check if avatar file exists
    final bool hasAvatar = avatarPath != null && 
                           avatarPath.isNotEmpty && 
                           File(avatarPath).existsSync();
    
    // Build preview text with sender name for group chats
    String previewText = _sanitizeText(lastMessage);
    if (isGroupChat && lastSenderName.isNotEmpty && lastSenderName != sender) {
      previewText = '${_sanitizeText(lastSenderName)}: $previewText';
    }
    
    // Truncate preview to reasonable length
    if (previewText.length > 50) {
      previewText = '${previewText.substring(0, 47)}...';
    }
    
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: unreadCount > 0 
            ? [Colors.deepPurple.shade900.withOpacity(0.4), Colors.purple.shade900.withOpacity(0.2)]
            : [Colors.grey.shade900.withOpacity(0.5), Colors.grey.shade800.withOpacity(0.3)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: unreadCount > 0 
            ? Colors.deepPurple.shade400.withOpacity(0.5)
            : Colors.grey.shade700.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          splashColor: Colors.deepPurple.shade300.withOpacity(0.2),
          highlightColor: Colors.deepPurple.shade200.withOpacity(0.1),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => ConversationScreen(
                  sender: sender,
                  app: conversation['app']?.toString() ?? '',
                ),
              ),
            ).then((_) => _loadConversations());
          },
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                // Avatar with group indicator
                Stack(
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        gradient: hasAvatar ? null : LinearGradient(
                          colors: isGroupChat 
                            ? [Colors.teal.shade400, Colors.cyan.shade600]
                            : [Colors.deepPurple.shade400, Colors.purple.shade600],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: (isGroupChat ? Colors.teal : Colors.deepPurple).withOpacity(0.3),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                        image: hasAvatar ? DecorationImage(
                          image: FileImage(File(avatarPath!)),
                          fit: BoxFit.cover,
                        ) : null,
                      ),
                      child: hasAvatar ? null : Center(
                        child: isGroupChat
                          ? const Icon(Icons.group, color: Colors.white, size: 28)
                          : Text(
                              sender.isNotEmpty ? sender[0].toUpperCase() : '?',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                      ),
                    ),
                    // App badge (WhatsApp/Instagram)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.grey.shade800, width: 2),
                        ),
                        child: ClipOval(
                          child: _getAppIconWidget(
                            conversation['app']?.toString() ?? '',
                            size: 16,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 14),
                // Content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header row with name and timestamp
                      Row(
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    sender,
                                    style: TextStyle(
                                      fontWeight: unreadCount > 0 ? FontWeight.bold : FontWeight.w600,
                                      fontSize: 16,
                                      color: unreadCount > 0 ? Colors.white : Colors.grey.shade300,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (isGroupChat) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.teal.shade700.withOpacity(0.7),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Text(
                                      'GROUP',
                                      style: TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white70,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          Text(
                            _formatTimestamp(conversation['lastTimestamp'] as int? ?? 0),
                            style: TextStyle(
                              color: unreadCount > 0 
                                ? Colors.deepPurple.shade200 
                                : Colors.grey.shade500,
                              fontSize: 12,
                              fontWeight: unreadCount > 0 ? FontWeight.w600 : FontWeight.normal,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      // Message preview row
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              previewText.isEmpty ? 'No messages' : previewText,
                              style: TextStyle(
                                color: unreadCount > 0 
                                  ? Colors.grey.shade300 
                                  : Colors.grey.shade500,
                                fontSize: 14,
                                fontWeight: unreadCount > 0 ? FontWeight.w500 : FontWeight.normal,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (unreadCount > 0) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [Colors.deepPurple.shade400, Colors.purple.shade500],
                                ),
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.deepPurple.withValues(alpha: 0.4),
                                    blurRadius: 6,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Text(
                                unreadCount > 99 ? '99+' : unreadCount.toString(),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ] else ...[
                            const SizedBox(width: 8),
                            Text(
                              '${conversation['messageCount']}',
                              style: TextStyle(
                                color: Colors.grey.shade600,
                                fontSize: 11,
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
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    _tabController.dispose();
    super.dispose();
  }
}

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

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
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
    _tabController = TabController(length: 2, vsync: this);
    _checkPermission();
    _loadConversations();
    _checkEncryption();
  }

  Future<void> _checkPermission() async {
    final hasPermission = await NotificationService.instance.isNotificationPermissionGranted();
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

    final conversations = await DatabaseHelper.instance.getConversations();
    setState(() {
      _conversations = conversations;
      _filteredConversations = conversations;
      _isLoading = false;
    });
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

  String _getAppIcon(String packageName) {
    if (packageName.contains('whatsapp')) {
      return '💬';
    } else if (packageName.contains('instagram')) {
      return '📸';
    }
    return '📱';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'SilentSave',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: Icon(
              _encryptionEnabled ? Icons.lock : Icons.lock_open,
              color: _encryptionEnabled ? Colors.green : Colors.grey,
            ),
            onPressed: _toggleEncryption,
            tooltip: _encryptionEnabled ? 'Encryption enabled' : 'Enable encryption',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadConversations,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(
              icon: Text('💬', style: TextStyle(fontSize: 24)),
              text: 'WhatsApp',
            ),
            Tab(
              icon: Text('📸', style: TextStyle(fontSize: 24)),
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
        color: Colors.orange.shade900.withValues(alpha: 0.3),
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
    final emoji = appPackage.contains('whatsapp') ? '💬' : '📸';
    
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            emoji,
            style: const TextStyle(fontSize: 80),
          ),
          const SizedBox(height: 16),
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
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: Colors.deepPurple.shade700,
          child: Text(
            _getAppIcon(conversation['app']),
            style: const TextStyle(fontSize: 24),
          ),
        ),
        title: Text(
          conversation['sender'],
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        subtitle: Text(
          '${conversation['messageCount']} messages',
          style: TextStyle(
            color: Colors.grey.shade400,
            fontSize: 14,
          ),
        ),
        trailing: Text(
          _formatTimestamp(conversation['lastTimestamp']),
          style: TextStyle(
            color: Colors.grey.shade500,
            fontSize: 12,
          ),
        ),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ConversationScreen(
                sender: conversation['sender'],
                app: conversation['app'],
              ),
            ),
          ).then((_) => _loadConversations());
        },
      ),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    _tabController.dispose();
    super.dispose();
  }
}

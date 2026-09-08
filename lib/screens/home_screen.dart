import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/database_helper.dart';
import '../services/notification_service.dart';
import '../services/encryption_service.dart';
import '../models/message_model.dart';
import '../widgets/full_screen_media_viewer.dart';
import 'conversation_screen.dart';
import 'capture_screen.dart';
import 'settings_screen.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:local_auth/local_auth.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

enum SortOption { recent, mostMessages, leastMessages }

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  List<Map<String, dynamic>> _conversations = [];
  List<Map<String, dynamic>> _filteredConversations = [];
  List<MessageModel> _searchResults = [];
  bool _isLoading = true;
  bool _hasPermission = false;
  bool _hasSafPermission = true; // Default true to avoid flash before check
  bool _encryptionEnabled = false;
  SortOption _sortOption = SortOption.recent;
  String? _highlightedConversationKey;
  late TabController _tabController;
  
  // Variables for custom swipe-to-switch tabs gesture detection
  double _horizontalDragTotal = 0;
  bool _isDraggingVertically = false;

  final LocalAuthentication _localAuth = LocalAuthentication();
  bool _isCapturesAuthenticated = false;
  int _previousTabIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(_handleTabSelection);
    _checkPermission();
    _checkSafPermission();
    _loadConversations();
    _checkEncryption();
    _checkOemBatterySettings();

    // Listen for new messages from NotificationService and auto-refresh
    NotificationService.instance.newMessageNotifier.addListener(_onNewMessage);
  }

  @override
  void dispose() {
    NotificationService.instance.newMessageNotifier.removeListener(_onNewMessage);
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _tabController.removeListener(_handleTabSelection);
    _tabController.dispose();
    super.dispose();
  }

  void _handleTabSelection() async {
    if (_tabController.indexIsChanging) return; // Wait for animation to finish or only trigger on definitive changes
    
    if (_tabController.index == 2) {
      if (!_isCapturesAuthenticated) {
        bool authenticated = false;
        try {
          final isAvailable = await _localAuth.canCheckBiometrics || await _localAuth.isDeviceSupported();
          if (isAvailable) {
            authenticated = await _localAuth.authenticate(
              localizedReason: 'Please authenticate to view your captures',
              persistAcrossBackgrounding: true,
              biometricOnly: false,
            );
          } else {
            // If device doesn't support biometrics, allow access (or show a password prompt)
            authenticated = true; 
          }
        } catch (e) {
          debugPrint('Authentication error: \$e');
        }

        if (authenticated) {
          setState(() {
            _isCapturesAuthenticated = true;
          });
        } else {
          // Revert back to the previous tab
          _tabController.animateTo(_previousTabIndex);
        }
      }
    } else {
      _previousTabIndex = _tabController.index;
      // Optional: reset authentication when navigating away from Captures tab
      // _isCapturesAuthenticated = false; 
    }
  }

  /// Called by the newMessageNotifier whenever a message is saved.
  /// Reloads conversations directly from DB without re-triggering notification polling.
  void _onNewMessage() {
    _reloadConversationsFromDB();
  }

  Future<void> _performSearch(String query) async {
    if (query.isEmpty) {
      if (!mounted) return;
      setState(() {
        _searchResults = [];
        _filteredConversations = List.from(_conversations);
      });
      _applySortAndFilter();
    } else {
      // 1. Search all messages in DB for this query
      final allMatchingMessages = await DatabaseHelper.instance.searchMessages(query);

      if (!mounted) return;
      setState(() {
        _searchResults = allMatchingMessages;
      });
    }
  }

  void _applySortAndFilter() {
    if (_searchController.text.isNotEmpty) {
      // We don't apply conversation sorting logic to the purely query-based search results list in this version
      return; 
    }
    
    // When no search is active, we filter from the base conversations list
    List<Map<String, dynamic>> filtered = List.from(_conversations);

    if (_sortOption == SortOption.mostMessages) {
      filtered.sort((a, b) => (b['messageCount'] as int).compareTo(a['messageCount'] as int));
    } else if (_sortOption == SortOption.leastMessages) {
      filtered.sort((a, b) => (a['messageCount'] as int).compareTo(b['messageCount'] as int));
    } else {
      filtered.sort((a, b) => (b['lastTimestamp'] as int).compareTo(a['lastTimestamp'] as int));
    }

    if (mounted) {
      setState(() {
        _filteredConversations = filtered;
      });
    }
  }

  /// Reload conversations from DB only (no notification refresh), to avoid loops.
  Future<void> _reloadConversationsFromDB() async {
    try {
      final conversations = await DatabaseHelper.instance.getConversations()
          .timeout(const Duration(seconds: 10), onTimeout: () {
        return <Map<String, dynamic>>[];
      });
      if (mounted) {
        setState(() {
          _conversations = conversations.toList();
          _isLoading = false;
        });
        _applySortAndFilter();
      }
    } catch (e) {
      debugPrint('[HomeScreen] Error reloading conversations: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _searchFocusNode.unfocus();
      // App resumed from background - refresh conversations (which includes refreshing notifications)
      _loadConversations();
      _checkPermission();
      _checkSafPermission();
    }
  }

  Future<void> _checkOemBatterySettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final alreadyShown = prefs.getBool('oem_battery_guide_shown') ?? false;
      if (alreadyShown) return;

      final manufacturer =
          await NotificationService.instance.getManufacturer();
      final lower = manufacturer.toLowerCase();

      String? package;
      if (lower.contains('xiaomi') || lower.contains('redmi')) {
        package = 'com.miui.securitycenter';
      } else if (lower.contains('huawei') || lower.contains('honor')) {
        package = 'com.huawei.systemmanager';
      } else if (lower.contains('oppo') || lower.contains('realme')) {
        package = 'com.coloros.safecenter';
      } else if (lower.contains('vivo')) {
        package = 'com.vivo.permissionmanagement';
      }

      if (package == null) return;
      
      await prefs.setBool('oem_battery_guide_shown', true);

      if (!mounted) return;
      final oemPackage = package;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Battery Optimisation'),
          content: const Text(
            'Your device manufacturer applies extra battery restrictions. '
            'To keep SilentSave running in the background, please set it to '
            '"No restrictions" or "Unrestricted" in Battery settings.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Later'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                NotificationService.instance
                    .openOemBatterySettings(oemPackage);
              },
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );
    } catch (e) {
      debugPrint('[HomeScreen] OEM battery check error: $e');
    }
  }

  Future<void> _checkPermission() async {
    final hasPermission = await NotificationService.instance.isNotificationPermissionGranted();
    debugPrint('[HomeScreen] Notification permission status: $hasPermission');
    setState(() {
      _hasPermission = hasPermission;
    });
  }

  Future<void> _checkSafPermission() async {
    final hasSaf = await NotificationService.instance.getSafPermissionStatus();
    setState(() {
      _hasSafPermission = hasSaf;
    });
  }



  Future<void> _checkEncryption() async {
    final enabled = await EncryptionService.instance.isEncryptionEnabled();
    setState(() {
      _encryptionEnabled = enabled;
    });
  }

  Future<void> _loadConversations() async {
    _searchFocusNode.unfocus();
    if (_conversations.isEmpty) {
      setState(() {
        _isLoading = true;
      });
    }

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
        _conversations = conversations.toList();
        _isLoading = false;
      });
      _applySortAndFilter();
    } catch (e) {
      debugPrint('[HomeScreen] Error loading conversations: $e');
      setState(() {
        _conversations = [];
        _filteredConversations = [];
        _isLoading = false;
      });
    }
  }

  Future<void> _handleDeleteConversation(String sender, String appPackage) async {
    // Save the conversation locally before removing
    final deletedIndex = _conversations.indexWhere((c) => c['sender'] == sender && c['app'] == appPackage);
    Map<String, dynamic>? deletedConversation;
    if (deletedIndex != -1) {
      deletedConversation = _conversations[deletedIndex];
    }

    // Delete from DB immediately
    await DatabaseHelper.instance.deleteConversation(sender, appPackage);
    
    // Remove from list locally for immediate feedback without full reload
    setState(() {
      if (deletedIndex != -1) {
        _conversations.removeAt(deletedIndex);
        _applySortAndFilter();
      }
    });

    if (mounted) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Conversation deleted'),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'UNDO',
            onPressed: () async {
              await DatabaseHelper.instance.undoDeleteConversation(sender, appPackage);
              if (deletedConversation != null && mounted) {
                setState(() {
                  _conversations.add(deletedConversation!);
                  _applySortAndFilter();
                  _highlightedConversationKey = 'conv_${sender}_$appPackage';
                });
                
                Future.delayed(const Duration(seconds: 2), () {
                  if (mounted) {
                    setState(() {
                      if (_highlightedConversationKey == 'conv_${sender}_$appPackage') {
                        _highlightedConversationKey = null;
                      }
                    });
                  }
                });
              }
            },
          ),
        ),
      );
    }
  }

  void _filterConversations(String _) {
    _performSearch(_searchController.text);
  }

  Widget _getAppIcon(String packageName, {double size = 12, Color? color}) {
    if (packageName.contains('whatsapp')) {
      return FaIcon(FontAwesomeIcons.whatsapp, size: size, color: color ?? Colors.green);
    } else if (packageName.contains('instagram')) {
      return FaIcon(FontAwesomeIcons.instagram, size: size, color: color ?? Colors.pinkAccent);
    }
    return Icon(Icons.notifications, size: size, color: color ?? Colors.grey);
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
      // Dart's Runes iterator naturally handles surrogate pairs correctly 
      // and replaces isolated surrogates with the replacement character U+FFFD.
      return String.fromCharCodes(text.runes);
    } catch (e) {
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
                  activeThumbColor: Colors.green,
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

  Future<void> _markAllAsRead() async {
    final count = await DatabaseHelper.instance.markAllMessagesAsRead();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Marked $count messages as read'),
          duration: const Duration(seconds: 2),
        ),
      );
      _loadConversations();
    }
  }

  Future<void> _markCurrentTabAsRead() async {
    final app = _tabController.index == 0 ? 'com.whatsapp' : 'com.instagram.android';
    final count = await DatabaseHelper.instance.markAllMessagesAsReadByApp(app);
    final appName = _tabController.index == 0 ? 'WhatsApp' : 'Instagram';
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Marked $count $appName messages as read'),
          duration: const Duration(seconds: 2),
        ),
      );
      _loadConversations();
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
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const SettingsScreen()),
              );
            },
          ),
          // Mark all read menu
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) async {
              if (value == 'mark_all_read') {
                await _markAllAsRead();
              } else if (value == 'mark_tab_read') {
                await _markCurrentTabAsRead();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'mark_tab_read',
                child: Row(
                  children: [
                    Icon(Icons.done, size: 20),
                    SizedBox(width: 12),
                    Text('Mark tab as read'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'mark_all_read',
                child: Row(
                  children: [
                    Icon(Icons.done_all, size: 20),
                    SizedBox(width: 12),
                    Text('Mark all as read'),
                  ],
                ),
              ),
            ],
          ),
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
          tabs: const [
            Tab(
              icon: FaIcon(FontAwesomeIcons.whatsapp, size: 24, color: Colors.green),
              text: 'WhatsApp',
            ),
            Tab(
              icon: FaIcon(FontAwesomeIcons.instagram, size: 24, color: Colors.pinkAccent),
              text: 'Instagram',
            ),
            Tab(
              icon: Icon(Icons.camera_alt, size: 24, color: Colors.deepPurpleAccent),
              text: 'Captures',
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          if (!_hasPermission) _buildPermissionWarning(),
          if (_hasPermission && !_hasSafPermission && _tabController.index == 0) _buildSafPermissionWarning(),
          _buildSearchBar(),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _searchController.text.isNotEmpty
                    ? _buildSearchResultsList()
                    : Listener(
                        onPointerDown: (_) {
                          _horizontalDragTotal = 0;
                          _isDraggingVertically = false;
                        },
                        onPointerMove: (event) {
                          if (_isDraggingVertically) return;
                          
                          // If moving vertically, ignore horizontal swipe
                          if (event.delta.dy.abs() > 5 && _horizontalDragTotal.abs() < 10) {
                            _isDraggingVertically = true;
                            return;
                          }
                          
                          _horizontalDragTotal += event.delta.dx;
                          
                          // Custom threshold to switch tabs
                          if (_tabController.index == 0 && _horizontalDragTotal < -60) {
                            _tabController.animateTo(1);
                            _horizontalDragTotal = 0;
                          } else if (_tabController.index == 1 && _horizontalDragTotal > 60) {
                            _tabController.animateTo(0);
                            _horizontalDragTotal = 0;
                          }
                        },
                        child: TabBarView(
                          controller: _tabController,
                          children: [
                            _buildConversationList('com.whatsapp'),
                            _buildConversationList('com.instagram.android'),
                            const CaptureScreen(),
                          ],
                        ),
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



  Widget _buildSafPermissionWarning() {
    return Container(
      margin: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.green.shade900.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.green.shade600, width: 1),
      ),
      child: Row(
        children: [
          Icon(Icons.photo_library, color: Colors.green.shade400),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Media Capture setup',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Grant access to WhatsApp folder to save photos and videos.',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade300),
                ),
              ],
            ),
          ),
          FilledButton(
            onPressed: () async {
              final granted = await NotificationService.instance.requestWhatsAppSafPermission();
              if (granted) {
                _checkSafPermission();
              }
            },
            style: FilledButton.styleFrom(
              backgroundColor: Colors.green.shade600,
            ),
            child: const Text('Setup'),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _searchController,
            focusNode: _searchFocusNode,
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
                        _searchFocusNode.unfocus();
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
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('Most Recent'),
                  selected: _sortOption == SortOption.recent,

                  shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20), 
                  ),

                  visualDensity: VisualDensity.compact, 
                  // Reduces the padding around the text inside the chip
                  labelPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0), 
                  // Reduces the internal padding of the chip itself
                  padding: EdgeInsets.zero, 

                  onSelected: (selected) {
                    if (selected) {
                      setState(() {
                        _sortOption = SortOption.recent;
                        _applySortAndFilter();
                      });
                    }
                  },
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Most Messages'),
                  selected: _sortOption == SortOption.mostMessages,

                  shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20), 
                  ),

                  visualDensity: VisualDensity.compact, 
                  // Reduces the padding around the text inside the chip
                  labelPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0), 
                  // Reduces the internal padding of the chip itself
                  padding: EdgeInsets.zero,

                  onSelected: (selected) {
                    if (selected) {
                      setState(() {
                        _sortOption = SortOption.mostMessages;
                        _applySortAndFilter();
                      });
                    }
                  },
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Least Messages'),
                  selected: _sortOption == SortOption.leastMessages,

                  shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20), 
                  ),

                  visualDensity: VisualDensity.compact, 
                  // Reduces the padding around the text inside the chip
                  labelPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0), 
                  // Reduces the internal padding of the chip itself
                  padding: EdgeInsets.zero,

                  onSelected: (selected) {
                    if (selected) {
                      setState(() {
                        _sortOption = SortOption.leastMessages;
                        _applySortAndFilter();
                      });
                    }
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(String appPackage) {
    final appName = appPackage.contains('whatsapp') ? 'WhatsApp' : 'Instagram';
    
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _getAppIcon(appPackage, size: 80),
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

  Widget _buildSearchResultsList() {
    if (_searchResults.isEmpty) {
      if (_searchController.text.isNotEmpty) {
        return Center(
          child: Text(
            'No matches found for "${_searchController.text}"',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 16),
          ),
        );
      }
      return const SizedBox.shrink();
    }
    
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _searchResults.length,
      itemBuilder: (context, index) {
        final message = _searchResults[index];
        final String rawSender = _sanitizeText(message.sender);
        final String sender = rawSender.isNotEmpty ? rawSender : 'Unknown';
        final String displaySenderName = _sanitizeText(message.senderName ?? message.sender);
        final String appPackage = message.app;
        
        // Find avatar from active conversation base if possible
        String? avatarPath;
        try {
          final convBase = _conversations.firstWhere(
            (c) => c['sender'] == message.sender && c['app'] == message.app,
          );
          avatarPath = convBase['latestAvatarPath']?.toString();
        } catch (_) {}
        
        final bool hasAvatar = avatarPath != null && avatarPath.isNotEmpty && File(avatarPath).existsSync();

        return _buildSearchResultCard(
          message: message,
          senderText: displaySenderName,
          actualSender: sender,
          appPackage: appPackage,
          avatarPath: hasAvatar ? avatarPath : null,
        );
      },
    );
  }

  Widget _buildSearchResultCard({
    required MessageModel message,
    required String senderText,
    required String actualSender,
    required String appPackage,
    String? avatarPath,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.grey.shade900.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.grey.shade800.withValues(alpha: 0.5),
          width: 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          splashColor: Colors.deepPurple.shade300.withValues(alpha: 0.2),
          highlightColor: Colors.deepPurple.shade200.withValues(alpha: 0.1),
          onTap: () {
            _searchFocusNode.unfocus();
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => ConversationScreen(
                  sender: actualSender,
                  app: appPackage,
                  initialAvatarPath: avatarPath,
                ),
              ),
            ).then((_) {
              _searchFocusNode.unfocus();
              _loadConversations();
            });
          },
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: Colors.deepPurple.shade800,
                  backgroundImage: avatarPath != null ? FileImage(File(avatarPath)) : null,
                  child: avatarPath == null
                      ? Text(
                          senderText.isNotEmpty ? senderText.characters.first.toUpperCase() : '?',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        )
                      : null,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    senderText,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                      color: Colors.white,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                _getAppIcon(appPackage, size: 12),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _formatTimestamp(message.timestamp.millisecondsSinceEpoch),
                            style: TextStyle(
                              color: Colors.grey.shade500,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      // Provide highlight logic
                      _buildHighlightText(message.message, _searchController.text),
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

  Widget _buildHighlightText(String text, String query) {
    if (query.isEmpty) {
      return Text(
        text,
        style: TextStyle(color: Colors.grey.shade400, fontSize: 14),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }

    final String lowerText = text.toLowerCase();
    final String lowerQuery = query.toLowerCase();

    final List<TextSpan> spans = [];
    int start = 0;
    int indexOfMatch = lowerText.indexOf(lowerQuery, start);

    while (indexOfMatch != -1) {
      if (indexOfMatch > start) {
        spans.add(TextSpan(
          text: text.substring(start, indexOfMatch),
          style: TextStyle(color: Colors.grey.shade400, fontSize: 14),
        ));
      }

      spans.add(TextSpan(
        text: text.substring(indexOfMatch, indexOfMatch + query.length),
        style: TextStyle(
          color: Colors.black,
          backgroundColor: Colors.orange.shade300,
          fontWeight: FontWeight.bold,
          fontSize: 14,
        ),
      ));

      start = indexOfMatch + query.length;
      indexOfMatch = lowerText.indexOf(lowerQuery, start);
    }

    if (start < text.length) {
      spans.add(TextSpan(
        text: text.substring(start),
        style: TextStyle(color: Colors.grey.shade400, fontSize: 14),
      ));
    }

    return RichText(
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(children: spans),
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
    final String lastMessage = _sanitizeText(conversation['lastMessage']?.toString());
    final String lastSenderName = _sanitizeText(conversation['lastSenderName']?.toString());
    final String rawSender = _sanitizeText(conversation['sender']?.toString());
    final String sender = rawSender.isNotEmpty ? rawSender : 'Unknown';
    final String? avatarPath = conversation['latestAvatarPath']?.toString();
    final bool hasAvatar = avatarPath != null &&
                           avatarPath.isNotEmpty &&
                           File(avatarPath).existsSync();

    // Build preview text with sender name for group chats
    String previewText = lastMessage;
    if (isGroupChat && lastSenderName.isNotEmpty && lastSenderName != sender) {
      previewText = '$lastSenderName: $lastMessage';
    }

    // Truncate preview to reasonable length
    if (previewText.length > 50) {
      previewText = '${previewText.substring(0, 47)}...';
    }
    
    final String? lastMediaPath = conversation['lastMediaPath']?.toString();
    final bool hasMediaFile = lastMediaPath != null && lastMediaPath.isNotEmpty && File(lastMediaPath).existsSync();
    
    bool isAudio = false;
    bool isVideo = false;
    if (hasMediaFile) {
      final ext = lastMediaPath.toLowerCase().split('.').last;
      isAudio = ['mp3', 'm4a', 'wav', 'ogg', 'opus', 'aac'].contains(ext);
      isVideo = ['mp4', 'mov', 'avi', 'mkv'].contains(ext);
    }
    
    final String appPackage = conversation['app']?.toString() ?? '';
    final bool isWhatsApp = appPackage.contains('whatsapp');
    
    return Slidable(
      key: Key('conv_${sender}_$appPackage'),
      startActionPane: isWhatsApp ? ActionPane(
        motion: const ScrollMotion(),
        dismissible: DismissiblePane(onDismissed: () => _handleDeleteConversation(sender, appPackage)),
        children: [
          SlidableAction(
            onPressed: (context) => _handleDeleteConversation(sender, appPackage),
            backgroundColor: Colors.red.shade800,
            foregroundColor: Colors.white,
            icon: Icons.delete,
            borderRadius: BorderRadius.circular(16),
          ),
        ],
      ) : null,
      endActionPane: !isWhatsApp ? ActionPane(
        motion: const ScrollMotion(),
        dismissible: DismissiblePane(onDismissed: () => _handleDeleteConversation(sender, appPackage)),
        children: [
          SlidableAction(
            onPressed: (context) => _handleDeleteConversation(sender, appPackage),
            backgroundColor: Colors.red.shade800,
            foregroundColor: Colors.white,
            icon: Icons.delete,
            borderRadius: BorderRadius.circular(16),
          ),
        ],
      ) : null,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: _highlightedConversationKey == 'conv_${sender}_$appPackage' ? 1.0 : 0.0, end: 0.0),
        duration: const Duration(milliseconds: 1500),
        curve: Curves.easeOut,
        builder: (context, value, child) {
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Color.lerp(
                    unreadCount > 0 
                      ? Colors.deepPurple.shade900.withValues(alpha: 0.4) 
                      : Colors.grey.shade900.withValues(alpha: 0.5),
                    Colors.green.shade800.withValues(alpha: 0.6),
                    value,
                  )!,
                  Color.lerp(
                    unreadCount > 0 
                      ? Colors.purple.shade900.withValues(alpha: 0.2) 
                      : Colors.grey.shade800.withValues(alpha: 0.3),
                    Colors.green.shade900.withValues(alpha: 0.3),
                    value,
                  )!,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: Color.lerp(
                  unreadCount > 0 
                    ? Colors.deepPurple.shade400.withValues(alpha: 0.5) 
                    : Colors.grey.shade700.withValues(alpha: 0.3),
                  Colors.greenAccent.withValues(alpha: 0.8),
                  value,
                )!,
                width: 1 + (value * 1.5),
              ),
            ),
            child: child,
          );
        },
        child: Material(
          color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          splashColor: Colors.deepPurple.shade300.withValues(alpha: 0.2),
          highlightColor: Colors.deepPurple.shade200.withValues(alpha: 0.1),
          onTap: () {
            _searchFocusNode.unfocus();
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => ConversationScreen(
                  sender: sender,
                  app: conversation['app']?.toString() ?? '',
                  initialAvatarPath: hasAvatar ? avatarPath : null,
                ),
              ),
            ).then((_) {
              _searchFocusNode.unfocus();
              _loadConversations();
            });
          },
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                // Avatar with group indicator
                GestureDetector(
                  onTap: () {
                    if (hasAvatar) {
                      _searchFocusNode.unfocus();
                      Navigator.push(
                        context,
                        PageRouteBuilder(
                          opaque: false,
                          barrierColor: Colors.black.withValues(alpha: 0.92),
                          pageBuilder: (ctx, animation, _) {
                            return FadeTransition(
                              opacity: animation,
                              child: FullScreenMediaViewer(
                                paths: [avatarPath],
                                heroTags: ['avatar_${sender}_$appPackage'],
                                type: 'image',
                                reverseOrder: true,
                              ),
                            );
                          },
                        ),
                      );
                    }
                  },
                  child: Hero(
                    tag: 'avatar_${sender}_$appPackage',
                    child: Stack(
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
                            image: hasAvatar ? DecorationImage(
                              image: FileImage(File(avatarPath)),
                              fit: BoxFit.cover,
                            ) : null,
                            boxShadow: [
                              BoxShadow(
                                color: (isGroupChat ? Colors.teal : Colors.deepPurple).withValues(alpha: 0.3),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: hasAvatar ? null : Center(
                            child: isGroupChat
                              ? const Icon(Icons.group, color: Colors.white, size: 28)
                              : Text(
                                  sender.isNotEmpty ? sender.characters.first.toUpperCase() : '?',
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
                            child: Center(
                              child: _getAppIcon(conversation['app']?.toString() ?? '', size: 10),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
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
                                      color: Colors.teal.shade700.withValues(alpha: 0.7),
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
                            child: Row(
                              children: [
                                if (hasMediaFile)
                                  Container(
                                    margin: const EdgeInsets.only(right: 6),
                                    width: 20,
                                    height: 20,
                                    decoration: isAudio || isVideo ? null : BoxDecoration(
                                      borderRadius: BorderRadius.circular(4),
                                      image: DecorationImage(
                                        image: FileImage(File(lastMediaPath)),
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                    child: isVideo 
                                      ? Icon(Icons.videocam, size: 18, color: Colors.grey.shade400)
                                      : isAudio
                                        ? Icon(Icons.mic, size: 18, color: Colors.grey.shade400)
                                        : null,
                                  ),
                                Expanded(
                                  child: Text(
                                    previewText.isEmpty && hasMediaFile 
                                      ? (isVideo ? 'Video' : isAudio ? 'Voice Note' : 'Photo') 
                                      : (previewText.isEmpty ? 'No messages' : previewText),
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
                              ],
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
      ),
    );
  }

}

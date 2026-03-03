import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'database_helper.dart';
import '../models/message_model.dart';
import 'dart:async';
import 'dart:collection';

/// Regex to strip WhatsApp's dynamic unread count suffix from group titles.
/// Matches patterns like: " (5 messages)", " (2 new messages)", " (12 messages)"
/// This is the Dart-side fallback to ensure clean group names even if the
/// native side somehow passes a dirty title.
final RegExp _groupNameCountSuffix = RegExp(
  r'\s*\(\d+\s+(?:new\s+)?messages?\)\s*$',
  caseSensitive: false,
);

/// Clean the group/conversation name by stripping WhatsApp's dynamic
/// " (X messages)" suffix. Prevents fragmented conversations.
String cleanGroupName(String rawTitle) {
  final cleaned = rawTitle.replaceAll(_groupNameCountSuffix, '').trim();
  return cleaned.isNotEmpty ? cleaned : rawTitle.trim();
}

/// NotificationService — the Flutter-side bridge to the native NotificationListener.
/// 
/// Polls the native side every 2 seconds for queued notifications, deduplicates them
/// in-memory (as a fast path), then writes to the database (which has its own dedup
/// as the final safety net).
/// 
/// Lifecycle-aware: automatically restarts polling if the app returns from background,
/// and includes a watchdog timer that detects and recovers from silent polling failures.
class NotificationService with WidgetsBindingObserver {
  static final NotificationService instance = NotificationService._init();
  static const platform = MethodChannel('com.silentsave/notifications');
  
  Timer? _pollTimer;
  Timer? _watchdogTimer;
  int _totalProcessed = 0;
  int _consecutiveErrors = 0;
  static const int _maxConsecutiveErrors = 5;
  
  // Last successful poll timestamp for watchdog
  DateTime _lastSuccessfulPoll = DateTime.now();
  static const Duration _watchdogInterval = Duration(seconds: 30);
  static const Duration _watchdogStaleThreshold = Duration(seconds: 20);
  
  // In-memory dedup: LinkedHashSet preserves insertion order for FIFO eviction.
  // This is a fast path — the database has its own dedup as the final safety net.
  final LinkedHashSet<String> _processedNotificationIds = LinkedHashSet<String>();
  static const int _maxProcessedIds = 1000;
  
  // Track whether we're currently checking, to prevent overlapping calls
  bool _isChecking = false;

  /// Notifier that increments whenever new messages are saved to the database.
  /// UI widgets can listen to this to auto-refresh.
  final ValueNotifier<int> newMessageNotifier = ValueNotifier<int>(0);

  NotificationService._init() {
    debugPrint('[NotificationService] Initializing...');
    
    // Register lifecycle observer to restart polling when app resumes
    WidgetsBinding.instance.addObserver(this);
    
    // Initial check + start polling
    _checkForNewNotifications();
    _startPolling();
    _startWatchdog();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      debugPrint('[NotificationService] App resumed — triggering immediate check');
      // Immediate check when app comes to foreground
      _checkForNewNotifications();
      // Ensure polling timer is alive
      _ensurePollingActive();
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    debugPrint('[NotificationService] Starting 2s polling');
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      _checkForNewNotifications();
      _checkForCleanup();
    });
  }
  
  /// Watchdog: detect if polling has silently stopped and restart it.
  /// This handles edge cases like timers being garbage-collected or
  /// Dart isolate quirks after prolonged background periods.
  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(_watchdogInterval, (timer) {
      final timeSinceLastPoll = DateTime.now().difference(_lastSuccessfulPoll);
      if (timeSinceLastPoll > _watchdogStaleThreshold) {
        debugPrint('[NotificationService] Watchdog: polling appears stale '
            '(${timeSinceLastPoll.inSeconds}s since last success). Restarting...');
        _startPolling();
      }
    });
  }
  
  /// Ensure the poll timer is running. Safe to call multiple times.
  void _ensurePollingActive() {
    if (_pollTimer == null || !_pollTimer!.isActive) {
      debugPrint('[NotificationService] Poll timer was dead, restarting');
      _startPolling();
    }
  }

  Future<void> _checkForNewNotifications() async {
    // Prevent overlapping calls (e.g. manual refresh + poll timer firing together)
    if (_isChecking) return;
    _isChecking = true;
    
    try {
      final List<dynamic>? results = await platform
          .invokeListMethod('getPendingNotifications')
          .timeout(const Duration(seconds: 8), onTimeout: () {
        debugPrint('[NotificationService] getPendingNotifications timed out');
        return null;
      });
      
      _consecutiveErrors = 0;
      _lastSuccessfulPoll = DateTime.now();
      
      if (results == null || results.isEmpty) return;
      
      debugPrint('[NotificationService] Received ${results.length} pending notifications');
      
      // Collect all valid messages first, then batch-insert into DB
      final messagesToInsert = <MessageModel>[];
      final removedSenders = <String>[];
      
      for (final result in results) {
        try {
          if (result is! Map) continue;
          
          final String method = (result['method'] as String?) ?? '';
          final String? rawTitle = result['title'] as String?;
          String? text = result['text'] as String?;
          final String? packageName = result['packageName'] as String?;
          
          // Validate required fields
          if (method.isEmpty || rawTitle == null || rawTitle.trim().isEmpty) continue;
          
          // Clean group name: strip dynamic " (X messages)" suffix
          final String title = cleanGroupName(rawTitle);
          
          // Normalize text
          if (text != null) {
            text = text.trim();
            if (text.isEmpty) continue;
          } else {
            continue;
          }
          
          // Truncate extremely long messages to prevent memory issues
          if (text.length > 10000) {
            text = '${text.substring(0, 10000)}... [truncated]';
          }
          
          // Parse timestamp robustly
          int timestamp;
          final rawTs = result['timestamp'];
          if (rawTs is int) {
            timestamp = rawTs;
          } else if (rawTs is String) {
            timestamp = int.tryParse(rawTs) ?? DateTime.now().millisecondsSinceEpoch;
          } else {
            timestamp = DateTime.now().millisecondsSinceEpoch;
          }
          
          // Dedup fast path — uses same key format as the native side
          final notificationId = '$title|$text|$timestamp';
          if (method == 'onNotificationReceived') {
            if (_processedNotificationIds.contains(notificationId)) continue;
          }
          
          final String senderName = (result['senderName'] as String?) ?? title;
          final bool isGroupChat = result['isGroupChat'] == true;
          final String? avatarPath = (result['avatarPath'] as String?);
          final validAvatarPath = (avatarPath != null && avatarPath.isNotEmpty) ? avatarPath : null;
          
          if (method == 'onNotificationReceived') {
            final messageTimestamp = DateTime.fromMillisecondsSinceEpoch(timestamp);
            
            messagesToInsert.add(MessageModel(
              sender: title,
              message: text,
              app: packageName ?? '',
              timestamp: messageTimestamp,
              isRead: false,
              senderName: senderName,
              isGroupChat: isGroupChat,
              avatarPath: validAvatarPath,
            ));
            
            // Track as processed (FIFO eviction)
            _processedNotificationIds.add(notificationId);
            while (_processedNotificationIds.length > _maxProcessedIds) {
              _processedNotificationIds.remove(_processedNotificationIds.first);
            }
          } else if (method == 'onNotificationRemoved') {
            removedSenders.add(title);
          }
        } catch (e, stackTrace) {
          debugPrint('[NotificationService] Error processing notification: $e');
          debugPrint('[NotificationService] $stackTrace');
        }
      }
      
      // Batch insert all collected messages in a single DB transaction
      if (messagesToInsert.isNotEmpty) {
        final inserted = await DatabaseHelper.instance.insertMessages(messagesToInsert);
        _totalProcessed += inserted;
        if (inserted > 0) {
          debugPrint('[NotificationService] ✓ Batch: $inserted/${messagesToInsert.length} new messages saved');
          // Notify UI listeners once per batch, not per message
          newMessageNotifier.value++;
        }
      }
      
      // Process removals
      for (final sender in removedSenders) {
        try {
          await DatabaseHelper.instance.markMessagesAsRead(sender);
        } catch (e) {
          debugPrint('[NotificationService] Error marking read: $e');
        }
      }
    } catch (e) {
      _consecutiveErrors++;
      debugPrint('[NotificationService] Error ($_consecutiveErrors/$_maxConsecutiveErrors): $e');
      
      if (_consecutiveErrors >= _maxConsecutiveErrors) {
        debugPrint('[NotificationService] Too many errors, restarting after 5s delay');
        _consecutiveErrors = 0;
        _pollTimer?.cancel();
        Future.delayed(const Duration(seconds: 5), _startPolling);
      }
    } finally {
      _isChecking = false;
    }
  }

  Future<void> _checkForCleanup() async {
    try {
      final result = await platform.invokeMethod('checkCleanupRequested');
      if (result == true) {
        await performCleanup();
      }
    } catch (_) {}
  }

  Future<bool> isNotificationPermissionGranted() async {
    try {
      return await platform.invokeMethod('isNotificationPermissionGranted') as bool;
    } catch (e) {
      debugPrint('[NotificationService] Permission check error: $e');
      return false;
    }
  }

  Future<void> openNotificationSettings() async {
    try {
      await platform.invokeMethod('openNotificationSettings');
    } catch (e) {
      debugPrint('[NotificationService] Error opening settings: $e');
    }
  }

  Future<void> scheduleCleanupJob() async {
    try {
      await platform.invokeMethod('scheduleCleanupJob');
    } catch (e) {
      debugPrint('[NotificationService] Error scheduling cleanup: $e');
    }
  }

  Future<void> performCleanup() async {
    try {
      final deletedCount = await DatabaseHelper.instance.deleteOldMessages();
      debugPrint('[NotificationService] Cleaned up $deletedCount old messages');
    } catch (e) {
      debugPrint('[NotificationService] Cleanup error: $e');
    }
  }

  /// Manual refresh — call from pull-to-refresh or app resume.
  Future<void> refreshNotifications() async {
    debugPrint('[NotificationService] Manual refresh');
    try {
      await _checkForNewNotifications().timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          debugPrint('[NotificationService] Refresh timed out');
        },
      );
    } catch (e) {
      debugPrint('[NotificationService] Refresh error: $e');
    }
  }

  int get totalProcessed => _totalProcessed;

  void dispose() {
    debugPrint('[NotificationService] Disposing...');
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    _watchdogTimer?.cancel();
  }
}

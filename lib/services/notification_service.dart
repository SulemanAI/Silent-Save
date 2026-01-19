import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'database_helper.dart';
import '../models/message_model.dart';
import 'dart:async';

class NotificationService {
  static final NotificationService instance = NotificationService._init();
  static const platform = MethodChannel('com.silentsave/notifications');
  
  Timer? _pollTimer;
  int _totalProcessed = 0;

  NotificationService._init() {
    debugPrint('[NotificationService] Initializing...');
    // Immediately check for any accumulated notifications on startup
    _checkForNewNotifications();
    _startPolling();
  }

  void _startPolling() {
    debugPrint('[NotificationService] Starting polling with 2-second interval');
    // Poll for new notifications every 2 seconds
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      _checkForNewNotifications();
      _checkForCleanup();
    });
  }

  Future<void> _checkForNewNotifications() async {
    try {
      // Add timeout to prevent hanging
      final List<dynamic>? results = await platform.invokeListMethod('getPendingNotifications')
          .timeout(const Duration(seconds: 5), onTimeout: () {
        debugPrint('[NotificationService] getPendingNotifications timed out');
        return null;
      });
      
      if (results == null || results.isEmpty) {
        return;
      }
      
      debugPrint('[NotificationService] Received ${results.length} pending notifications');
      
      for (final result in results) {
        try {
          // Edge case: Wrap each notification processing in try-catch
          // so one bad notification doesn't break the whole batch
          if (result is Map) {
            final String? method = result['method'];
            final String? title = result['title'];
            final String? text = result['text'];
            final String? packageName = result['packageName'];
            
            debugPrint('[NotificationService] Processing: method=$method, title="$title", text="${text?.toString().substring(0, (text?.length ?? 0) > 30 ? 30 : text?.length ?? 0)}..."');
            
            // Handle timestamp being potentially a String or int/long from JSON
            int? timestamp;
            if (result['timestamp'] is int) {
              timestamp = result['timestamp'];
            } else if (result['timestamp'] is String) {
              timestamp = int.tryParse(result['timestamp']);
            }
            
            // Skip if essential data is missing
            if (method == null || method.isEmpty) {
              debugPrint('[NotificationService] Skipping notification with null/empty method');
              continue;
            }
            
            // Parse new fields for group chat support and avatar
            final String? senderName = result['senderName'];
            final bool isGroupChat = result['isGroupChat'] == true;
            final String? avatarPath = result['avatarPath'];
            
            debugPrint('[NotificationService] Parsed: title=$title, senderName=$senderName, avatarPath=$avatarPath');
            debugPrint('[NotificationService] About to call handler for method: $method');
            if (method == 'onNotificationReceived') {
              await _handleNotificationReceived({
                'title': title,
                'text': text,
                'packageName': packageName,
                'timestamp': timestamp,
                'senderName': senderName,
                'isGroupChat': isGroupChat,
                'avatarPath': avatarPath,
              });
              _totalProcessed++;
              debugPrint('[NotificationService] Finished processing notification, totalProcessed: $_totalProcessed');
            } else if (method == 'onNotificationRemoved') {
              await _handleNotificationRemoved({
                'title': title,
                'text': text,
                'packageName': packageName,
              });
              debugPrint('[NotificationService] Finished handling notification removal');
            }
          } else {
            debugPrint('[NotificationService] Unexpected result type: ${result.runtimeType}');
          }
        } catch (e, stackTrace) {
          // Edge case: Log individual notification processing error but continue with others
          debugPrint('[NotificationService] Error processing individual notification: $e');
          debugPrint('[NotificationService] Stack trace: $stackTrace');
        }
      }
      
      debugPrint('[NotificationService] Total messages processed so far: $_totalProcessed');
    } catch (e, stackTrace) {
      // Log errors (these could indicate real problems)
      debugPrint('[NotificationService] Error checking notifications: $e');
      debugPrint('[NotificationService] Stack trace: $stackTrace');
    }
  }

  Future<void> _checkForCleanup() async {
    try {
      final result = await platform.invokeMethod('checkCleanupRequested');
      if (result == true) {
        debugPrint('[NotificationService] Cleanup requested, performing cleanup...');
        await performCleanup();
      }
    } catch (e) {
      // Silently fail for cleanup checks
    }
  }

  Future<void> _handleNotificationReceived(dynamic arguments) async {
    debugPrint('[NotificationService] _handleNotificationReceived called');
    try {
      debugPrint('[NotificationService] Arguments type: ${arguments.runtimeType}');
      debugPrint('[NotificationService] Arguments: $arguments');
      
      final Map<dynamic, dynamic> data = arguments as Map<dynamic, dynamic>;
      
      final sender = data['title']?.toString() ?? 'Unknown';
      final messageText = data['text']?.toString() ?? '';
      final app = data['packageName']?.toString() ?? '';
      final timestampValue = data['timestamp'];
      final senderName = data['senderName']?.toString() ?? sender;
      final isGroupChat = data['isGroupChat'] == true;
      final avatarPath = data['avatarPath']?.toString();
      
      debugPrint('[NotificationService] Parsed data: sender="$sender", messageText length=${messageText.length}, app="$app", avatarPath=$avatarPath');
      
      // Parse timestamp
      DateTime timestamp;
      if (timestampValue is int) {
        timestamp = DateTime.fromMillisecondsSinceEpoch(timestampValue);
        debugPrint('[NotificationService] Timestamp from notification: $timestampValue -> $timestamp');
      } else {
        timestamp = DateTime.now();
        debugPrint('[NotificationService] Using current time as timestamp: $timestamp');
      }
      
      // Debug: Compare with current date
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final messageDate = DateTime(timestamp.year, timestamp.month, timestamp.day);
      debugPrint('[NotificationService] Now: $now, Today: $today, MessageDate: $messageDate, IsToday: ${messageDate == today}');
      
      final textPreview = messageText.length > 30 ? messageText.substring(0, 30) : messageText;
      debugPrint('[NotificationService] Creating message: sender="$sender", text="$textPreview", app="$app"');
      
      final message = MessageModel(
        sender: sender,  // Chat/Group name for grouping
        message: messageText,
        app: app,
        timestamp: timestamp,
        isRead: false,  // New messages start as unread
        senderName: senderName,  // Individual sender
        isGroupChat: isGroupChat,
        avatarPath: avatarPath,
      );

      debugPrint('[NotificationService] MessageModel created, calling insertMessage...');
      final result = await DatabaseHelper.instance.insertMessage(message);
      debugPrint('[NotificationService] insertMessage returned: $result');
      if (result == -1) {
        debugPrint('[NotificationService] Message was a duplicate, skipped');
      } else {
        debugPrint('[NotificationService] Message inserted with ID: $result');
      }
    } catch (e, stackTrace) {
      debugPrint('[NotificationService] Error handling notification: $e');
      debugPrint('[NotificationService] Stack trace: $stackTrace');
    }
  }

  Future<void> _handleNotificationRemoved(dynamic arguments) async {
    try {
      final Map<dynamic, dynamic> data = arguments as Map<dynamic, dynamic>;
      final sender = data['title'] ?? '';
      
      debugPrint('[NotificationService] Notification removed for sender: "$sender"');
      
      // When a notification is dismissed (user read it in WhatsApp), mark messages as read
      await DatabaseHelper.instance.markMessagesAsRead(sender);
    } catch (e) {
      debugPrint('[NotificationService] Error handling notification removal: $e');
    }
  }

  Future<bool> isNotificationPermissionGranted() async {
    try {
      final bool result = await platform.invokeMethod('isNotificationPermissionGranted');
      debugPrint('[NotificationService] Permission check result: $result');
      return result;
    } catch (e) {
      debugPrint('[NotificationService] Error checking notification permission: $e');
      return false;
    }
  }

  Future<void> openNotificationSettings() async {
    try {
      debugPrint('[NotificationService] Opening notification settings');
      await platform.invokeMethod('openNotificationSettings');
    } catch (e) {
      debugPrint('[NotificationService] Error opening notification settings: $e');
    }
  }

  Future<void> scheduleCleanupJob() async {
    try {
      debugPrint('[NotificationService] Scheduling cleanup job');
      await platform.invokeMethod('scheduleCleanupJob');
    } catch (e) {
      debugPrint('[NotificationService] Error scheduling cleanup job: $e');
    }
  }

  Future<void> performCleanup() async {
    try {
      final deletedCount = await DatabaseHelper.instance.deleteOldMessages();
      debugPrint('[NotificationService] Deleted $deletedCount old messages');
    } catch (e) {
      debugPrint('[NotificationService] Error performing cleanup: $e');
    }
  }

  /// Manually trigger a check for new notifications.
  /// Call this when the app resumes from background or when user pulls to refresh.
  Future<void> refreshNotifications() async {
    debugPrint('[NotificationService] Manual refresh triggered');
    try {
      await _checkForNewNotifications().timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          debugPrint('[NotificationService] Refresh timed out');
        },
      );
    } catch (e) {
      debugPrint('[NotificationService] Error during refresh: $e');
    }
  }

  /// Get the count of processed messages (for debugging)
  int get totalProcessed => _totalProcessed;

  void dispose() {
    debugPrint('[NotificationService] Disposing...');
    _pollTimer?.cancel();
  }
}



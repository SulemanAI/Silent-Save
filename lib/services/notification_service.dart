import 'package:flutter/services.dart';
import 'database_helper.dart';
import '../models/message_model.dart';
import 'dart:async';

class NotificationService {
  static final NotificationService instance = NotificationService._init();
  static const platform = MethodChannel('com.silentsave/notifications');
  
  Timer? _pollTimer;
  String? _lastProcessedData;

  NotificationService._init() {
    _startPolling();
  }

  void _startPolling() {
    // Poll for new notifications every 2 seconds
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      _checkForNewNotifications();
      _checkForCleanup();
    });
  }

  Future<void> _checkForNewNotifications() async {
    try {
      final result = await platform.invokeMethod('getLatestNotification');
      if (result != null && result is Map) {
        final String? method = result['method'];
        final String? title = result['title'];
        final String? text = result['text'];
        final String? packageName = result['packageName'];
        final int? timestamp = result['timestamp'];
        
        // Create unique key to avoid processing same notification twice
        final dataKey = '$method-$title-$text-$timestamp';
        
        if (dataKey != _lastProcessedData && method != null) {
          _lastProcessedData = dataKey;
          
          if (method == 'onNotificationReceived') {
            await _handleNotificationReceived({
              'title': title,
              'text': text,
              'packageName': packageName,
              'timestamp': timestamp,
            });
          } else if (method == 'onNotificationRemoved') {
            await _handleNotificationRemoved({
              'title': title,
              'text': text,
              'packageName': packageName,
            });
          }
        }
      }
    } catch (e) {
      // Silently fail - this is expected when no new notifications
    }
  }

  Future<void> _checkForCleanup() async {
    try {
      final result = await platform.invokeMethod('checkCleanupRequested');
      if (result == true) {
        await performCleanup();
      }
    } catch (e) {
      // Silently fail
    }
  }

  Future<void> _handleNotificationReceived(dynamic arguments) async {
    try {
      final Map<dynamic, dynamic> data = arguments as Map<dynamic, dynamic>;
      
      final message = MessageModel(
        sender: data['title'] ?? 'Unknown',
        message: data['text'] ?? '',
        app: data['packageName'] ?? '',
        timestamp: DateTime.fromMillisecondsSinceEpoch(data['timestamp'] ?? DateTime.now().millisecondsSinceEpoch),
      );

      await DatabaseHelper.instance.insertMessage(message);
    } catch (e) {
      print('Error handling notification: $e');
    }
  }

  Future<void> _handleNotificationRemoved(dynamic arguments) async {
    try {
      final Map<dynamic, dynamic> data = arguments as Map<dynamic, dynamic>;
      
      // Mark message as deleted if it matches
      await DatabaseHelper.instance.markMessageAsDeletedByContent(
        data['title'] ?? '',
        data['text'] ?? '',
      );
    } catch (e) {
      print('Error handling notification removal: $e');
    }
  }

  Future<bool> isNotificationPermissionGranted() async {
    try {
      final bool result = await platform.invokeMethod('isNotificationPermissionGranted');
      return result;
    } catch (e) {
      print('Error checking notification permission: $e');
      return false;
    }
  }

  Future<void> openNotificationSettings() async {
    try {
      await platform.invokeMethod('openNotificationSettings');
    } catch (e) {
      print('Error opening notification settings: $e');
    }
  }

  Future<void> scheduleCleanupJob() async {
    try {
      await platform.invokeMethod('scheduleCleanupJob');
    } catch (e) {
      print('Error scheduling cleanup job: $e');
    }
  }

  Future<void> performCleanup() async {
    try {
      final deletedCount = await DatabaseHelper.instance.deleteOldMessages();
      print('Deleted $deletedCount old messages');
    } catch (e) {
      print('Error performing cleanup: $e');
    }
  }

  void dispose() {
    _pollTimer?.cancel();
  }
}


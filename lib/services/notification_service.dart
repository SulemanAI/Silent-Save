import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'database_helper.dart';
import '../models/message_model.dart';
import '../utils/timestamp_matcher.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:convert';

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

/// Sanitize text to remove invalid UTF-16 characters that could crash the app.
/// This is critical because notifications from apps like WhatsApp can sometimes
/// contain malformed UTF-16 data (unpaired surrogates).
String sanitizeText(String? text) {
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

/// NotificationService — the Flutter-side bridge to the native NotificationListener.
/// 
/// HYBRID ARCHITECTURE:
/// - Native NLS writes to a file queue
/// - Native side can also push via MethodChannel when Flutter is in foreground
/// - Flutter polls every 30 seconds as a safety net (only while app is visible)
/// - Also polls on app resume and manual refresh
/// 
/// This hybrid approach prevents missed messages from any single path failing.
class NotificationService with WidgetsBindingObserver {
  static final NotificationService instance = NotificationService._init();
  static const platform = MethodChannel('com.silentsave/notifications');
  
  int _totalProcessed = 0;
  
  // In-memory dedup: LinkedHashSet preserves insertion order for FIFO eviction.
  // This is a fast path — the database has its own dedup as the final safety net.
  final LinkedHashSet<String> _processedNotificationIds = LinkedHashSet<String>();
  static const int _maxProcessedIds = 1000;
  
  // Track whether we're currently checking, to prevent overlapping calls
  bool _isChecking = false;
  
  // Periodic safety-net poll timer (only while app is in foreground)
  Timer? _pollTimer;
  bool _appInForeground = true;

  /// Notifier that increments whenever new messages are saved to the database.
  /// UI widgets can listen to this to auto-refresh.
  final ValueNotifier<int> newMessageNotifier = ValueNotifier<int>(0);

  NotificationService._init() {
    debugPrint('[NotificationService] Initializing (hybrid mode)...');
    
    // Register lifecycle observer to check for pending notifications when app resumes
    WidgetsBinding.instance.addObserver(this);
    
    // Listen for direct MethodChannel callbacks from native side
    // This allows native to push notifications directly when Flutter is in foreground
    platform.setMethodCallHandler((call) async {
      try {
        if (call.method == 'onNotificationReceived') {
          if (call.arguments is Map && call.arguments['event'] == 'db_updated') {
            debugPrint('[NotificationService] db_updated received -> instant UI refresh');
            newMessageNotifier.value++;
            await _checkForNewMedia();
            return;
          }
          await _handleNotificationReceived(call.arguments);
        } else if (call.method == 'onNotificationRemoved') {
          await _handleNotificationRemoved(call.arguments);
        }
      } catch (e) {
        debugPrint('[NotificationService] MethodChannel handler error: $e');
      }
    });
    
    // Initial check for any pending notifications accumulated while app was closed
    _checkForNewNotifications();
    
    // Start periodic safety-net poll (every 30 seconds while app is in foreground)
    _startPollTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      debugPrint('[NotificationService] App resumed — checking for pending notifications');
      _appInForeground = true;
      // Trigger UI refresh unconditionally on resume to show any messages
      // that were inserted natively into SQLite while app was backgrounded
      newMessageNotifier.value++;
      // Request NLS rebind in case it was killed by OEM battery optimization
      _requestNlsRebind();
      // Check for any notifications that arrived while app was in background
      _checkForNewNotifications();
      _checkForNewMedia();
      _checkForCleanup();
      // Restart poll timer
      _startPollTimer();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _appInForeground = false;
      // Stop the poll timer when app is in background — native side handles capture
      _stopPollTimer();
    }
  }

  /// Start periodic safety-net poll timer (10 seconds).
  /// Only active while app is in foreground.
  /// The native side captures messages independently — this poll is just for
  /// quickly picking up messages from the file queue when the user is looking
  /// at the app.
  void _startPollTimer() {
    _stopPollTimer();
    // Poll every 1 second while the app is in the foreground for instant media/message updates.
    // This is safe because the timer is killed immediately when the app goes to the background.
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_appInForeground) {
        _checkForNewNotifications();
        _checkForNewMedia();
      }
    });
  }

  void _stopPollTimer() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// Request the native NotificationListenerService to rebind.
  /// This is called automatically on app resume to handle OEM battery kill scenarios.
  Future<void> _requestNlsRebind() async {
    try {
      await platform.invokeMethod('requestNlsRebind');
    } catch (e) {
      debugPrint('[NotificationService] NLS rebind request failed: $e');
    }
  }

  Future<void> _checkForNewNotifications() async {
    // Prevent overlapping calls (e.g. manual refresh while already checking)
    if (_isChecking) return;
    _isChecking = true;
    
    try {
      final List<dynamic>? results = await platform
          .invokeListMethod('getPendingNotifications')
          .timeout(const Duration(seconds: 8), onTimeout: () {
        debugPrint('[NotificationService] getPendingNotifications timed out');
        return null;
      });
      
      if (results == null || results.isEmpty) return;
      
      debugPrint('[NotificationService] Received ${results.length} pending notifications');
      
      // Collect all valid messages first, then batch-insert into DB
      final messagesToInsert = <MessageModel>[];
      
      for (final result in results) {
        try {
          if (result is! Map) continue;
          
          final String method = (result['method'] as String?) ?? '';
          final String? rawTitle = result['title'] as String?;
          String? text = result['text'] as String?;
          final String? packageName = result['packageName'] as String?;

          // Validate required fields
          if (method.isEmpty || rawTitle == null || rawTitle.trim().isEmpty) continue;

          // Clean and sanitize group name: strip dynamic " (X messages)" suffix
          final String title = sanitizeText(cleanGroupName(rawTitle));

          // Normalize and sanitize text
          if (text != null) {
            text = sanitizeText(text.trim());
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
          
          final String? mediaPath = (result['mediaPath'] as String?);
          final validMediaPath = (mediaPath != null && mediaPath.isNotEmpty) ? mediaPath : null;
          
          final String senderName = sanitizeText((result['senderName'] as String?) ?? title);
          final bool isGroupChat = result['isGroupChat'] == true;
          final String? avatarPath = (result['avatarPath'] as String?);
          final validAvatarPath = (avatarPath != null && avatarPath.isNotEmpty) ? avatarPath : null;

          // Dedup fast path — uses same key format as the native side
          final notificationId = '$title|$text|$timestamp';
          if (method == 'onNotificationReceived') {
            final isDuplicate = _processedNotificationIds.contains(notificationId);
            final hasMedia = validMediaPath != null || validAvatarPath != null;
            
            // Only skip if it's a duplicate AND brings no new media.
            // If it brings media, let it pass so DatabaseHelper can update the existing row.
            if (isDuplicate && !hasMedia) {
              continue;
            }
            _processedNotificationIds.add(notificationId);
            if (_processedNotificationIds.length > _maxProcessedIds) {
              _processedNotificationIds.remove(_processedNotificationIds.first);
            }
          }
          
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
              mediaPath: validMediaPath,
            ));
            
            // Track as processed (FIFO eviction)
            _processedNotificationIds.add(notificationId);
            while (_processedNotificationIds.length > _maxProcessedIds) {
              _processedNotificationIds.remove(_processedNotificationIds.first);
            }
          }
          // onNotificationRemoved events are intentionally ignored here.
          // Read state is only updated when the user explicitly opens a
          // conversation inside SilentSave (see ConversationScreen._loadMessages).
          // Acting on OS-level dismissals was causing all unread chats to be
          // marked as read whenever Android cleared the notification shade.
        } catch (e, stackTrace) {
          debugPrint('[NotificationService] Error processing notification: $e');
          debugPrint('[NotificationService] $stackTrace');
        }
      }
      
      // Chunk batch inserts (50 at a time) with a yield between chunks so the
      // Flutter main thread can render frames during large backlogs (200+ messages).
      if (messagesToInsert.isNotEmpty) {
        int totalInserted = 0;
        const chunkSize = 50;
        for (int i = 0; i < messagesToInsert.length; i += chunkSize) {
          final end = (i + chunkSize < messagesToInsert.length)
              ? i + chunkSize
              : messagesToInsert.length;
          totalInserted +=
              await DatabaseHelper.instance.insertMessages(messagesToInsert.sublist(i, end));
          if (end < messagesToInsert.length) {
            await Future.delayed(Duration.zero); // yield to UI thread between chunks
          }
        }
        _totalProcessed += totalInserted;
        if (totalInserted > 0) {
          debugPrint('[NotificationService] ✓ Batch: $totalInserted/${messagesToInsert.length} new messages saved');
          newMessageNotifier.value++;
        }
      }
      
    } catch (e) {
      debugPrint('[NotificationService] Error checking notifications: $e');
    } finally {
      _isChecking = false;
    }
  }

  Future<void> _checkForNewMedia() async {
    try {
      final List<dynamic>? results = await platform
          .invokeListMethod('getMediaQueue')
          .timeout(const Duration(seconds: 8), onTimeout: () => null);
      
      if (results == null || results.isEmpty) return;
      
      debugPrint('[NotificationService] Received ${results.length} media queue events');
      
      for (final result in results) {
        if (result is! Map) continue;
        final mediaEvent = Map<String, dynamic>.from(result);
        
        // 24-hour window: covers existing placeholder messages saved before SAF ran.
        // Widened from 1h to catch old "Video"/"Photo" messages that never got a file.
        final matchResult = await TimestampMatcher.matchMediaToNotification(mediaEvent, 86400000);
        
        final attachmentData = <String, dynamic>{
          'media_type': mediaEvent['mediaType'] ?? 'unknown',
          'file_path': mediaEvent['filePath'] ?? '',
          'original_uri': mediaEvent['originalUri'] ?? '',
          'captured_at': mediaEvent['fileTimestampMs'] ?? 0,
        };
        
        if (matchResult.isMatched && matchResult.matchedMessage != null) {
          final msg = matchResult.matchedMessage!;
          attachmentData['notification_id'] = msg['id'];
          attachmentData['sender_name'] = msg['senderName'] ?? msg['sender'];
          attachmentData['matched'] = 1;
          
          // Insert attachment
          await DatabaseHelper.instance.insertMediaAttachment(attachmentData);
          
          // Update the message so ConversationScreen sees the media directly
          await DatabaseHelper.instance.updateMessageMediaPath(msg['id'] as int, attachmentData['file_path'] as String);
          
          // Notify UI immediately so the conversation view refreshes without waiting
          newMessageNotifier.value++;
        } else if (matchResult.isAmbiguous && matchResult.ambiguousCandidates != null) {
          final ids = matchResult.ambiguousCandidates!.map((c) => c['id']).toList();
          attachmentData['candidate_notification_ids'] = jsonEncode(ids);
          attachmentData['matched'] = 0;
          await DatabaseHelper.instance.insertMediaAttachment(attachmentData);
        } else {
          attachmentData['matched'] = 0;
          await DatabaseHelper.instance.insertMediaAttachment(attachmentData);
        }
      }
      
      // Notify UI of new media
      newMessageNotifier.value++;
      
    } catch (e) {
      debugPrint('[NotificationService] Error checking new media: $e');
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

  // Direct MethodChannel handlers (used when native side pushes events)
  Future<void> _handleNotificationReceived(dynamic arguments) async {
    try {
      final Map<dynamic, dynamic> data = arguments as Map<dynamic, dynamic>;

      if (data['event'] == 'db_updated') {
        newMessageNotifier.value++;
        return;
      }

      final rawSender = data['title']?.toString() ?? 'Unknown';
      final sender = sanitizeText(cleanGroupName(rawSender));
      final messageText = sanitizeText(data['text']?.toString() ?? '');
      final app = data['packageName']?.toString() ?? '';
      final timestampValue = data['timestamp'];
      final senderName = sanitizeText(data['senderName']?.toString() ?? sender);
      final isGroupChat = data['isGroupChat'] == true;
      final avatarPath = data['avatarPath']?.toString();
      final validAvatarPath = (avatarPath != null && avatarPath.isNotEmpty) ? avatarPath : null;
      final mediaPath = data['mediaPath']?.toString();
      final validMediaPath = (mediaPath != null && mediaPath.isNotEmpty) ? mediaPath : null;

      DateTime timestamp;
      if (timestampValue is int) {
        timestamp = DateTime.fromMillisecondsSinceEpoch(timestampValue);
      } else {
        timestamp = DateTime.now();
      }

      final message = MessageModel(
        sender: sender,
        message: messageText,
        app: app,
        timestamp: timestamp,
        isRead: false,
        senderName: senderName,
        isGroupChat: isGroupChat,
        avatarPath: validAvatarPath,
        mediaPath: validMediaPath,
      );

      final result = await DatabaseHelper.instance.insertMessage(message);
      if (result == -1) {
        debugPrint('[NotificationService] DB dedup: duplicate skipped');
      } else {
        debugPrint('[NotificationService] ✓ Saved message #$_totalProcessed from "$sender"');
        newMessageNotifier.value++;
      }
    } catch (e, stackTrace) {
      debugPrint('[NotificationService] Error handling notification: $e');
      debugPrint('[NotificationService] $stackTrace');
    }
  }

  // _handleNotificationRemoved intentionally does NOT mark messages as read.
  // Read state is driven exclusively by the user opening a conversation in
  // ConversationScreen, not by OS-level notification dismissals.
  Future<void> _handleNotificationRemoved(dynamic arguments) async {}


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
          debugPrint('[NotificationService] Refresh notifications timed out');
        },
      );
      await _checkForNewMedia().timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          debugPrint('[NotificationService] Refresh media timed out');
        },
      );
    } catch (e) {
      debugPrint('[NotificationService] Refresh error: $e');
    }
  }

  int get totalProcessed => _totalProcessed;

  /// Check whether the app is already exempt from battery optimization.
  Future<bool> isBatteryOptimizationExempt() async {
    try {
      return await platform.invokeMethod('isBatteryOptimizationExempt') as bool? ?? false;
    } catch (e) {
      debugPrint('[NotificationService] Battery opt check failed: $e');
      return false;
    }
  }

  /// Request that Android exempt this app from battery optimization so the
  /// NotificationListenerService is not killed on Android 6+ / 12+.
  /// Shows the system dialog only when not already exempt.
  Future<void> requestBatteryOptimizationExemption() async {
    try {
      await platform.invokeMethod('requestBatteryOptimizationExemption');
    } catch (e) {
      debugPrint('[NotificationService] Battery opt exemption request failed: $e');
    }
  }

  Future<String> getManufacturer() async {
    try {
      return await platform.invokeMethod<String>('getManufacturer') ?? '';
    } catch (e) {
      debugPrint('[NotificationService] getManufacturer error: $e');
      return '';
    }
  }

  Future<void> openOemBatterySettings(String package) async {
    try {
      await platform.invokeMethod('openOemBatterySettings', {'package': package});
    } catch (e) {
      debugPrint('[NotificationService] openOemBatterySettings error: $e');
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  // SAF PERMISSIONS
  // ══════════════════════════════════════════════════════════════════════

  Future<bool> getSafPermissionStatus() async {
    try {
      return await platform.invokeMethod('getSafPermissionStatus') as bool? ?? false;
    } catch (e) {
      debugPrint('[NotificationService] getSafPermissionStatus error: $e');
      return false;
    }
  }

  Future<bool> requestWhatsAppSafPermission() async {
    try {
      return await platform.invokeMethod('requestWhatsAppSafPermission') as bool? ?? false;
    } catch (e) {
      debugPrint('[NotificationService] requestWhatsAppSafPermission error: $e');
      return false;
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  // SILENT CAPTURE
  // ══════════════════════════════════════════════════════════════════════

  /// Capture a photo silently from the background.
  Future<bool> capturePhoto({bool useFrontCamera = false}) async {
    try {
      return await platform.invokeMethod('capturePhoto', {
        'useFrontCamera': useFrontCamera,
      }) as bool? ?? false;
    } catch (e) {
      debugPrint('[NotificationService] capturePhoto error: $e');
      return false;
    }
  }

  /// Start video recording silently from the background.
  Future<bool> startVideoRecording({
    bool useFrontCamera = false,
    int durationSec = 0,
    String quality = '720p',
  }) async {
    try {
      return await platform.invokeMethod('startVideoRecording', {
        'useFrontCamera': useFrontCamera,
        'durationSec': durationSec,
        'quality': quality,
      }) as bool? ?? false;
    } catch (e) {
      debugPrint('[NotificationService] startVideoRecording error: $e');
      return false;
    }
  }

  /// Stop video recording.
  Future<bool> stopVideoRecording() async {
    try {
      return await platform.invokeMethod('stopVideoRecording') as bool? ?? false;
    } catch (e) {
      debugPrint('[NotificationService] stopVideoRecording error: $e');
      return false;
    }
  }

  /// Start audio recording silently from the background.
  Future<bool> startAudioRecording({int durationSec = 0}) async {
    try {
      return await platform.invokeMethod('startAudioRecording', {
        'durationSec': durationSec,
      }) as bool? ?? false;
    } catch (e) {
      debugPrint('[NotificationService] startAudioRecording error: $e');
      return false;
    }
  }

  /// Stop audio recording.
  Future<bool> stopAudioRecording() async {
    try {
      return await platform.invokeMethod('stopAudioRecording') as bool? ?? false;
    } catch (e) {
      debugPrint('[NotificationService] stopAudioRecording error: $e');
      return false;
    }
  }

  /// Get list of all captured media files.
  Future<List<Map<String, dynamic>>> getCapturedMedia() async {
    try {
      final List<dynamic>? results = await platform.invokeListMethod('getCapturedMedia');
      if (results == null) return [];
      return results.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (e) {
      debugPrint('[NotificationService] getCapturedMedia error: $e');
      return [];
    }
  }

  /// Delete a captured media file by path (moves to trash).
  Future<bool> deleteCapturedMedia(String path) async {
    try {
      return await platform.invokeMethod('deleteCapturedMedia', {
        'path': path,
      }) as bool? ?? false;
    } catch (e) {
      debugPrint('[NotificationService] deleteCapturedMedia error: $e');
      return false;
    }
  }

  /// Get list of all trashed media files.
  Future<List<Map<String, dynamic>>> getTrashedMedia() async {
    try {
      final List<dynamic>? results = await platform.invokeListMethod('getTrashedMedia');
      if (results == null) return [];
      return results.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (e) {
      debugPrint('[NotificationService] getTrashedMedia error: $e');
      return [];
    }
  }

  /// Restore a trashed media file to the main captures folder.
  Future<bool> restoreTrashedMedia(String path) async {
    try {
      return await platform.invokeMethod('restoreTrashedMedia', {'path': path}) as bool? ?? false;
    } catch (e) {
      debugPrint('[NotificationService] restoreTrashedMedia error: $e');
      return false;
    }
  }

  /// Permanently delete a media file from the trash.
  Future<bool> permanentDeleteMedia(String path) async {
    try {
      return await platform.invokeMethod('permanentDeleteMedia', {'path': path}) as bool? ?? false;
    } catch (e) {
      debugPrint('[NotificationService] permanentDeleteMedia error: $e');
      return false;
    }
  }

  /// Permanently delete all files in the trash.
  Future<bool> emptyTrash() async {
    try {
      return await platform.invokeMethod('emptyTrash') as bool? ?? false;
    } catch (e) {
      debugPrint('[NotificationService] emptyTrash error: $e');
      return false;
    }
  }

  /// Get current capture status (is recording video/audio).
  Future<Map<String, dynamic>> getCaptureStatus() async {
    try {
      final result = await platform.invokeMapMethod<String, dynamic>('getCaptureStatus');
      return result ?? {'isRecordingVideo': false, 'isRecordingAudio': false};
    } catch (e) {
      debugPrint('[NotificationService] getCaptureStatus error: $e');
      return {'isRecordingVideo': false, 'isRecordingAudio': false};
    }
  }

  /// Check if camera permission is granted.
  Future<bool> hasCameraPermission() async {
    try {
      return await platform.invokeMethod('hasCameraPermission') as bool? ?? false;
    } catch (e) {
      debugPrint('[NotificationService] hasCameraPermission error: $e');
      return false;
    }
  }

  /// Check if audio/microphone permission is granted.
  Future<bool> hasAudioPermission() async {
    try {
      return await platform.invokeMethod('hasAudioPermission') as bool? ?? false;
    } catch (e) {
      debugPrint('[NotificationService] hasAudioPermission error: $e');
      return false;
    }
  }

  /// Opens any document (PDF, Word, CSV, etc.) using default viewer app via Android FileProvider.
  Future<bool> openFile(String filePath) async {
    try {
      return await platform.invokeMethod('openFile', {'filePath': filePath}) as bool? ?? false;
    } catch (e) {
      debugPrint('[NotificationService] openFile error: $e');
      return false;
    }
  }

  /// Copies one or more media files (images, audio, video, document) to the Android system clipboard.
  Future<bool> copyMediaToClipboard({
    String? filePath,
    List<String>? filePaths,
    String? text,
  }) async {
    try {
      final List<String> paths = filePaths ?? (filePath != null ? [filePath] : []);
      if (paths.isEmpty) return false;
      return await platform.invokeMethod('copyMediaToClipboard', {
        'filePaths': paths,
        'text': text,
      }) as bool? ?? false;
    } catch (e) {
      debugPrint('[NotificationService] copyMediaToClipboard error: $e');
      return false;
    }
  }

  void dispose() {
    debugPrint('[NotificationService] Disposing...');
    _stopPollTimer();
    WidgetsBinding.instance.removeObserver(this);
  }
}


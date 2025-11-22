# SilentSave - Technical Documentation

## Database Schema Documentation

### Table: messages

Complete table structure with indexes for optimal query performance.

```sql
CREATE TABLE messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sender TEXT NOT NULL,           -- Sender name or group name from notification
  message TEXT NOT NULL,           -- Message content (encrypted if encryption enabled)
  app TEXT NOT NULL,               -- Package name (com.whatsapp or com.instagram.android)
  timestamp INTEGER NOT NULL,      -- Unix timestamp in milliseconds
  isDeleted INTEGER DEFAULT 0      -- 0 = active, 1 = deleted/recalled
);

-- Performance indexes
CREATE INDEX idx_timestamp ON messages(timestamp);  -- For date-based queries and cleanup
CREATE INDEX idx_sender ON messages(sender);        -- For conversation grouping
```

### Database Operations

#### Insert Message
```dart
await DatabaseHelper.instance.insertMessage(MessageModel(
  sender: 'John Doe',
  message: 'Hello!',
  app: 'com.whatsapp',
  timestamp: DateTime.now(),
));
```

#### Get All Messages
```dart
List<MessageModel> messages = await DatabaseHelper.instance.getAllMessages();
```

#### Get Messages by Sender
```dart
List<MessageModel> messages = await DatabaseHelper.instance.getMessagesBySender('John Doe');
```

#### Get Conversations (Grouped)
```dart
List<Map<String, dynamic>> conversations = await DatabaseHelper.instance.getConversations();
// Returns: [{ sender, app, lastTimestamp, messageCount }, ...]
```

#### Search Messages
```dart
List<MessageModel> results = await DatabaseHelper.instance.searchMessages('search query');
```

#### Mark Message as Deleted
```dart
await DatabaseHelper.instance.markMessageAsDeletedByContent('John Doe', 'Hello!');
```

#### Delete Old Messages (15+ days)
```dart
int deletedCount = await DatabaseHelper.instance.deleteOldMessages();
```

## Daily Cleanup Job

The app uses Android WorkManager to schedule a periodic cleanup job that runs every 24 hours.

### Implementation

**File:** `CleanupWorker.kt`

```kotlin
class CleanupWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        return try {
            // Signal Flutter to perform cleanup
            val prefs = applicationContext.getSharedPreferences("notification_data", Context.MODE_PRIVATE)
            prefs.edit().putBoolean("cleanup_requested", true).apply()
            Result.success()
        } catch (e: Exception) {
            Result.retry()
        }
    }
}
```

### Scheduling

**File:** `MainActivity.kt`

```kotlin
private fun scheduleCleanupJob() {
    val constraints = Constraints.Builder()
        .setRequiresBatteryNotLow(true)  // Run when battery is not low
        .build()

    val cleanupRequest = PeriodicWorkRequestBuilder<CleanupWorker>(
        1, TimeUnit.DAYS  // Run every 24 hours
    )
        .setConstraints(constraints)
        .setInitialDelay(1, TimeUnit.HOURS)  // First run after 1 hour
        .build()

    WorkManager.getInstance(applicationContext).enqueueUniquePeriodicWork(
        "cleanup_old_messages",
        ExistingPeriodicWorkPolicy.KEEP,  // Don't reschedule if already scheduled
        cleanupRequest
    )
}
```

### Execution Flow

1. **App Launch:** `main.dart` calls `scheduleCleanupJob()`
2. **WorkManager:** Schedules job to run daily
3. **Job Trigger:** After 1 hour initially, then every 24 hours
4. **Worker Runs:** Sets `cleanup_requested` flag in SharedPreferences
5. **Flutter Polls:** Detects flag and calls `deleteOldMessages()`
6. **Database Cleanup:** Deletes messages where `timestamp < (now - 15 days)`

### Manual Trigger

You can manually trigger cleanup by restarting the app or calling:

```dart
await NotificationService.instance.performCleanup();
```

## Encryption System

### Overview

SilentSave uses AES-256 encryption with keys stored in Android Keystore via `flutter_secure_storage`.

### Implementation

**File:** `encryption_service.dart`

### Key Generation

```dart
// First time: Generate random 256-bit key
final key = encrypt.Key.fromSecureRandom(32);  // 32 bytes = 256 bits
final iv = encrypt.IV.fromSecureRandom(16);    // 16 bytes = 128 bits

// Store in Android Keystore
await _secureStorage.write(key: 'encryption_key', value: key.base64);
await _secureStorage.write(key: 'encryption_iv', value: iv.base64);
```

### Encryption Flow

1. **User enables encryption** via lock icon in app bar
2. **Key is generated** and stored in Android Keystore
3. **Future messages** are encrypted before storing in database
4. **Existing messages** remain unencrypted

### Encrypt Message

```dart
Future<String> encrypt(String plainText) async {
  if (_encrypter == null || _iv == null) {
    await initializeEncryption();
  }
  
  final encrypted = _encrypter!.encrypt(plainText, iv: _iv);
  return encrypted.base64;  // Store this in database
}
```

### Decrypt Message

```dart
Future<String> decrypt(String encryptedText) async {
  if (_encrypter == null || _iv == null) {
    await initializeEncryption();
  }
  
  try {
    final encrypted = encrypt.Encrypted.fromBase64(encryptedText);
    return _encrypter!.decrypt(encrypted, iv: _iv);
  } catch (e) {
    return encryptedText;  // Return as-is if decryption fails
  }
}
```

### Security Considerations

- **Keys never leave device** - stored in Android Keystore
- **Encryption is optional** - user must enable it
- **Irreversible** - once enabled, disabling won't decrypt old messages
- **No backup** - if keys are lost, encrypted messages are unrecoverable

## Native Android Components

### NotificationListenerService

**File:** `NotificationListener.kt`

### Supported Apps

```kotlin
private val WHATSAPP_PACKAGE = "com.whatsapp"
private val INSTAGRAM_PACKAGE = "com.instagram.android"
```

### Capturing Notifications

```kotlin
override fun onNotificationPosted(sbn: StatusBarNotification?) {
    val packageName = sbn.packageName
    
    // Filter for WhatsApp/Instagram only
    if (packageName != WHATSAPP_PACKAGE && packageName != INSTAGRAM_PACKAGE) {
        return
    }

    val notification = sbn.notification
    val extras = notification.extras

    val title = extras.getCharSequence("android.title")?.toString()
    val text = extras.getCharSequence("android.text")?.toString()
    val timestamp = sbn.postTime

    // Store in SharedPreferences for Flutter to poll
    val prefs = getSharedPreferences("notification_data", Context.MODE_PRIVATE)
    prefs.edit()
        .putString("method", "onNotificationReceived")
        .putString("title", title)
        .putString("text", text)
        .putString("packageName", packageName)
        .putLong("timestamp", timestamp)
        .apply()
}
```

### Detecting Deleted Messages

```kotlin
override fun onNotificationRemoved(sbn: StatusBarNotification?) {
    // When WhatsApp deletes a message, the notification is removed
    // We mark the corresponding message as deleted in our database
    
    val prefs = getSharedPreferences("notification_data", Context.MODE_PRIVATE)
    prefs.edit()
        .putString("method", "onNotificationRemoved")
        .putString("title", title)
        .putString("text", text)
        .apply()
}
```

## Flutter-Native Communication

### MethodChannel

**Channel Name:** `com.silentsave/notifications`

### Available Methods

#### 1. Check Notification Permission
```dart
bool hasPermission = await platform.invokeMethod('isNotificationPermissionGranted');
```

**Kotlin Implementation:**
```kotlin
private fun isNotificationServiceEnabled(): Boolean {
    val packageName = packageName
    val flat = Settings.Secure.getString(
        contentResolver,
        "enabled_notification_listeners"
    )
    
    return flat?.contains(packageName) ?: false
}
```

#### 2. Open Settings
```dart
await platform.invokeMethod('openNotificationSettings');
```

**Kotlin Implementation:**
```kotlin
private fun openNotificationSettings() {
    val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
    startActivity(intent)
}
```

#### 3. Get Latest Notification
```dart
Map<String, dynamic>? data = await platform.invokeMethod('getLatestNotification');
```

**Returns:**
```json
{
  "method": "onNotificationReceived",
  "title": "John Doe",
  "text": "Hello!",
  "packageName": "com.whatsapp",
  "timestamp": 1234567890000
}
```

#### 4. Check Cleanup Requested
```dart
bool needsCleanup = await platform.invokeMethod('checkCleanupRequested');
```

### Polling Mechanism

Since background MethodChannel communication is unreliable, Flutter polls for new notifications:

**File:** `notification_service.dart`

```dart
void _startPolling() {
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
        _checkForNewNotifications();
        _checkForCleanup();
    });
}
```

**Why Polling?**
- NotificationListenerService runs in background
- Can't reliably invoke Flutter methods when app is backgrounded
- SharedPreferences + polling ensures messages are never missed
- 2-second interval is fast enough for real-time feel

## UI Components

### Home Screen

**File:** `home_screen.dart`

**Features:**
- Permission warning banner
- Search bar with real-time filtering
- Conversation list with last message time
- Encryption toggle
- Pull-to-refresh

**Key Methods:**
```dart
_loadConversations()        // Load conversation groups from database
_filterConversations(query) // Filter conversations by sender name
_checkPermission()          // Check if notification access is granted
_toggleEncryption()         // Enable/disable message encryption
```

### Conversation Screen

**File:** `conversation_screen.dart`

**Features:**
- Message bubbles with timestamps
- Deleted message indicators
- App icon badge (WhatsApp/Instagram)
- Automatic scrolling

**Message States:**
- **Active:** Blue/purple bubble
- **Deleted:** Red border, strikethrough text, delete icon

## Performance Optimizations

### Database Indexes

```sql
CREATE INDEX idx_timestamp ON messages(timestamp);  -- Speeds up cleanup queries
CREATE INDEX idx_sender ON messages(sender);        -- Speeds up conversation grouping
```

### Query Optimization

**Get Conversations (Grouped):**
```sql
SELECT sender, app, MAX(timestamp) as lastTimestamp, COUNT(*) as messageCount
FROM messages
GROUP BY sender, app
ORDER BY lastTimestamp DESC
```

This query is optimized with the `idx_sender` index.

**Delete Old Messages:**
```sql
DELETE FROM messages WHERE timestamp < ?
```

This query is optimized with the `idx_timestamp` index.

### Polling Frequency

- **Notification polling:** Every 2 seconds
- **Cleanup checking:** Every 2 seconds (piggybacked on notification poll)
- **UI refresh:** On-demand via pull-to-refresh

## Error Handling

### Database Errors

All database operations are wrapped in try-catch:

```dart
Future<void> _handleNotificationReceived(dynamic arguments) async {
    try {
        // ... database insert
    } catch (e) {
        print('Error handling notification: $e');
        // Silently fail - don't crash the app
    }
}
```

### Encryption Errors

If decryption fails, return the original encrypted text:

```dart
try {
    final encrypted = encrypt.Encrypted.fromBase64(encryptedText);
    return _encrypter!.decrypt(encrypted, iv: _iv);
} catch (e) {
    return encryptedText;  // Show encrypted text rather than crashing
}
```

### Permission Errors

If notification access is not granted, show a warning banner:

```dart
if (!_hasPermission) _buildPermissionWarning()
```

## Testing Checklist

- [ ] Install app on physical Android device (API 21+)
- [ ] Grant notification access permission
- [ ] Send test WhatsApp message
- [ ] Verify message appears in app
- [ ] Delete WhatsApp message
- [ ] Verify message marked as deleted in app
- [ ] Enable encryption
- [ ] Send new message
- [ ] Verify message is encrypted in database
- [ ] Wait 15+ days or manually trigger cleanup
- [ ] Verify old messages are deleted
- [ ] Test search functionality
- [ ] Test conversation grouping

## Troubleshooting

### NotificationListenerService Not Working

**Issue:** Messages not being captured

**Solutions:**
1. Check notification access: Settings → Special app access → Notification access
2. Ensure app is not force-stopped
3. Restart the app
4. Check if WhatsApp/Instagram notifications are enabled

### Database Not Created

**Issue:** App crashes on launch

**Solutions:**
1. Check minimum SDK is 21+
2. Verify sqflite dependency installed
3. Check app has storage permissions (automatic in modern Android)

### Encryption Not Working

**Issue:** Messages not decrypting

**Solutions:**
1. Check flutter_secure_storage is installed
2. Verify encryption was enabled before messages were received
3. Old messages won't be encrypted if encryption was enabled later

## Future Enhancements

Potential improvements for personal use:

1. **Export Data:** Export messages to CSV/JSON
2. **App Settings:** Customize cleanup period, add more apps
3. **Statistics:** Show message counts, most active contacts
4. **Backup/Restore:** Encrypted cloud backup option
5. **Notification Filtering:** Filter out group messages or specific senders
6. **Media Support:** Attempt to capture media file paths (limited by notification API)

## References

- [NotificationListenerService Docs](https://developer.android.com/reference/android/service/notification/NotificationListenerService)
- [WorkManager Guide](https://developer.android.com/topic/libraries/architecture/workmanager)
- [Flutter MethodChannel](https://docs.flutter.dev/platform-integration/platform-channels)
- [SQLite in Flutter](https://pub.dev/packages/sqflite)
- [AES Encryption in Dart](https://pub.dev/packages/encrypt)

---

**Last Updated:** November 2025

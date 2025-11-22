# SilentSave - Build Output Summary

## 📦 Complete Build Output

This document provides a summary of all the components built for the SilentSave app.

---

## ✅ Flutter Code (Dart)

### 📱 Main Application
- **`lib/main.dart`** - App entry point with Material 3 theme and dark mode

### 📊 Data Models
- **`lib/models/message_model.dart`** - Message data structure with encryption support

### 🖥️ UI Screens
- **`lib/screens/home_screen.dart`** - Home screen with conversation list, search, and encryption toggle
- **`lib/screens/conversation_screen.dart`** - Message history view with deleted message indicators

### ⚙️ Services
- **`lib/services/database_helper.dart`** - SQLite operations with encryption integration
- **`lib/services/encryption_service.dart`** - AES-256 encryption for messages
- **`lib/services/notification_service.dart`** - Native Android communication via MethodChannel

---

## 🤖 Native Android Code (Kotlin)

### 📲 Main Activity
- **`android/app/src/main/kotlin/com/silentsave/silentsave/MainActivity.kt`**
  - MethodChannel handler for Flutter communication
  - Permission checking
  - Settings navigation
  - Cleanup job scheduling
  - SharedPreferences polling methods

### 🔔 Notification Listener
- **`android/app/src/main/kotlin/com/silentsave/silentsave/NotificationListener.kt`**
  - Captures WhatsApp and Instagram notifications
  - Filters system messages
  - Stores notification data in SharedPreferences
  - Detects deleted/recalled messages

### 🧹 Cleanup Worker
- **`android/app/src/main/kotlin/com/silentsave/silentsave/CleanupWorker.kt`**
  - Daily WorkManager job
  - Triggers cleanup of messages older than 15 days
  - Runs when device battery is not low

---

## 🗄️ Database Schema

### Table: messages
```sql
CREATE TABLE messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sender TEXT NOT NULL,
  message TEXT NOT NULL,
  app TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  isDeleted INTEGER DEFAULT 0
);

CREATE INDEX idx_timestamp ON messages(timestamp);
CREATE INDEX idx_sender ON messages(sender);
```

**Fields:**
- `id` - Auto-incrementing primary key
- `sender` - Sender name or group name from notification
- `message` - Message content (encrypted if encryption enabled)
- `app` - Package name (com.whatsapp or com.instagram.android)
- `timestamp` - Unix timestamp in milliseconds
- `isDeleted` - 0 = active, 1 = deleted/recalled

---

## 🔧 Configuration Files

### Android Configuration
- **`android/app/src/main/AndroidManifest.xml`** - Added NotificationListenerService and WorkManager provider
- **`android/app/build.gradle.kts`** - Added WorkManager dependency, set minSdk to 21

### Flutter Configuration
- **`pubspec.yaml`** - Dependencies:
  - `sqflite: ^2.3.0` - SQLite database
  - `path: ^1.8.3` - Path utilities
  - `intl: ^0.18.1` - Date formatting
  - `flutter_secure_storage: ^9.0.0` - Secure key storage
  - `encrypt: ^5.0.3` - AES encryption
  - `permission_handler: ^11.0.1` - Permission management

---

## 🚀 Daily Cleanup Job Implementation

### How It Works

1. **Scheduling (MainActivity.kt):**
   ```kotlin
   WorkManager.getInstance(applicationContext).enqueueUniquePeriodicWork(
       "cleanup_old_messages",
       ExistingPeriodicWorkPolicy.KEEP,
       cleanupRequest  // Runs every 24 hours
   )
   ```

2. **Execution (CleanupWorker.kt):**
   ```kotlin
   override fun doWork(): Result {
       // Set flag in SharedPreferences
       prefs.edit().putBoolean("cleanup_requested", true).apply()
       return Result.success()
   }
   ```

3. **Flutter Detection (notification_service.dart):**
   ```dart
   Future<void> _checkForCleanup() async {
       final result = await platform.invokeMethod('checkCleanupRequested');
       if (result == true) {
           await performCleanup();
       }
   }
   ```

4. **Database Cleanup (database_helper.dart):**
   ```dart
   Future<int> deleteOldMessages() async {
       final fifteenDaysAgo = DateTime.now().subtract(const Duration(days: 15));
       return await db.delete(
           'messages',
           where: 'timestamp < ?',
           whereArgs: [fifteenDaysAgo.millisecondsSinceEpoch],
       );
   }
   ```

### Schedule Details
- **Frequency:** Every 24 hours
- **First Run:** 1 hour after app launch
- **Constraint:** Battery not low
- **Policy:** KEEP (don't reschedule if already scheduled)

---

## 📋 Features Summary

### ✨ Core Features
- [x] Captures WhatsApp notifications
- [x] Captures Instagram notifications
- [x] Stores sender, message, app, timestamp
- [x] SQLite database with indexes
- [x] Automatic 15-day message deletion
- [x] Daily cleanup job with WorkManager

### 🎨 UI Features
- [x] Home screen with conversation list
- [x] Grouped by sender
- [x] Search bar for filtering
- [x] Tap sender to view message history
- [x] Material 3 dark theme design
- [x] Pull-to-refresh

### 🔐 Privacy Features
- [x] All data stored locally
- [x] No network access
- [x] Optional AES-256 encryption
- [x] Secure key storage in Android Keystore
- [x] No cloud sync

### 📱 Platform Features
- [x] Notification access permission request
- [x] Permission status detection
- [x] Settings navigation button
- [x] Deleted/recalled message detection
- [x] Visual indicators for deleted messages

---

## 🏃 How to Run

### 1. Build and Run
```bash
cd silentsave
flutter pub get
flutter run
```

### 2. Enable Notification Access
- Open the app
- Tap "Enable" on the warning banner
- Enable "SilentSave Notification Listener"
- Return to app

### 3. Optional: Enable Encryption
- Tap lock icon in app bar
- Confirm to enable encryption

### 4. Test
- Send a test WhatsApp or Instagram message
- Check if it appears in the app
- Delete the message
- Verify it's marked as deleted

---

## 📁 File Tree

```
silentsave/
├── lib/
│   ├── main.dart                              ✅ Created
│   ├── models/
│   │   └── message_model.dart                 ✅ Created
│   ├── screens/
│   │   ├── home_screen.dart                   ✅ Created
│   │   └── conversation_screen.dart           ✅ Created
│   └── services/
│       ├── database_helper.dart               ✅ Created
│       ├── encryption_service.dart            ✅ Created
│       └── notification_service.dart          ✅ Created
│
├── android/
│   └── app/
│       ├── src/main/
│       │   ├── AndroidManifest.xml            ✅ Updated
│       │   └── kotlin/com/silentsave/silentsave/
│       │       ├── MainActivity.kt            ✅ Updated
│       │       ├── NotificationListener.kt    ✅ Created
│       │       └── CleanupWorker.kt           ✅ Created
│       └── build.gradle.kts                   ✅ Updated
│
├── pubspec.yaml                               ✅ Updated
├── README.md                                  ✅ Created
└── TECHNICAL_DOCS.md                          ✅ Created
```

---

## 🎯 Key Implementation Details

### Notification Capture
- Uses Android NotificationListenerService
- Filters for WhatsApp (com.whatsapp) and Instagram (com.instagram.android)
- Extracts title and text from notification extras
- Stores in SharedPreferences for Flutter to poll

### Flutter-Native Communication
- MethodChannel: `com.silentsave/notifications`
- Polling every 2 seconds (reliable for background operation)
- SharedPreferences as data bridge

### Encryption
- AES-256 encryption with Encrypter package
- Keys stored in Android Keystore via flutter_secure_storage
- Per-message encryption/decryption
- Optional feature (user must enable)

### Database Design
- SQLite with sqflite package
- Indexes on timestamp and sender for performance
- Automatic cleanup of messages older than 15 days
- Support for marking messages as deleted

---

## ✅ All Requirements Met

| Requirement | Status | Implementation |
|------------|---------|----------------|
| WhatsApp support | ✅ | NotificationListener.kt filters for com.whatsapp |
| Instagram support | ✅ | NotificationListener.kt filters for com.instagram.android |
| Capture title/sender | ✅ | extras.getCharSequence("android.title") |
| Capture message text | ✅ | extras.getCharSequence("android.text") |
| Capture timestamp | ✅ | sbn.postTime |
| Capture package name | ✅ | sbn.packageName |
| SQLite storage | ✅ | database_helper.dart with sqflite |
| Table schema | ✅ | id, sender, message, app, timestamp, isDeleted |
| 15-day auto-delete | ✅ | deleteOldMessages() in database_helper.dart |
| Daily cleanup job | ✅ | CleanupWorker.kt with WorkManager |
| Home page UI | ✅ | home_screen.dart with conversation list |
| Grouped by sender | ✅ | getConversations() groups by sender |
| Message history view | ✅ | conversation_screen.dart |
| Search bar | ✅ | TextField with _filterConversations() |
| Deleted message indicator | ✅ | Red border, strikethrough, delete icon |
| Notification permission | ✅ | isNotificationServiceEnabled() |
| Permission detection | ✅ | _hasPermission in home_screen.dart |
| Settings navigation | ✅ | openNotificationSettings() |
| Offline storage | ✅ | No network permissions |
| No cloud sync | ✅ | All local SQLite |
| Local encryption | ✅ | encryption_service.dart with AES-256 |

---

## 📝 Notes

- **Private Use Only:** This app captures notification previews and should not be published
- **Notification Previews:** Only captures what appears in notifications (first line)
- **Android Only:** Uses NotificationListenerService (Android-specific API)
- **Minimum API:** Requires Android 5.0 (API 21) or higher
- **No Media:** Cannot capture images/videos from notifications

---

**Build Date:** November 2025  
**Flutter Version:** 3.9.2+  
**Android Min SDK:** 21  
**Target SDK:** Latest

---

✅ **All code complete and ready to run!**

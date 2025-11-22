# SilentSave - Personal Message Archive App

**SilentSave** is a personal Android app that captures and stores WhatsApp and Instagram DM messages from notification previews. All data remains offline and private.

## ⚠️ Important Notice

This app is for **personal use only** and should not be published to any app store. It captures notification previews for archival purposes.

## Features

✅ **Supported Apps:** WhatsApp, Instagram  
✅ **Automatic Capture:** Saves notification title, text, timestamp, and package name  
✅ **Smart Storage:** SQLite database with automatic 15-day deletion  
✅ **Beautiful UI:** Material 3 design with dark theme  
✅ **Conversation View:** Messages grouped by sender  
✅ **Search Functionality:** Find messages quickly  
✅ **Deleted Message Detection:** Shows when WhatsApp messages are deleted/recalled  
✅ **Privacy First:** All data stays offline, no cloud sync  
✅ **Optional Encryption:** AES encryption for stored messages  
✅ **Auto Cleanup:** Daily job to delete messages older than 15 days

## 📱 Screenshots

The app features:
- Home screen with conversation list
- Individual conversation view with message history
- Search bar for filtering
- Visual indicators for deleted/recalled messages
- Encryption toggle in app bar

## 🏗️ Architecture

### Flutter (UI Layer)
- **Material 3 Design** with dark theme
- **SQLite** for local database
- **flutter_secure_storage** for encryption keys
- **encrypt** package for AES encryption

### Native Android (Data Capture)
- **NotificationListenerService** for capturing notifications
- **WorkManager** for daily cleanup jobs
- **SharedPreferences** for Flutter-Native communication

## 📊 Database Schema

```sql
CREATE TABLE messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sender TEXT NOT NULL,
  message TEXT NOT NULL,
  app TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  isDeleted INTEGER DEFAULT 0
);

-- Indexes for performance
CREATE INDEX idx_timestamp ON messages(timestamp);
CREATE INDEX idx_sender ON messages(sender);
```

## 🚀 Setup Instructions

### Prerequisites
- Flutter SDK (3.9.2 or higher)
- Android SDK
- Android device or emulator running API 21+

### Installation

1. **Clone/Navigate to the project:**
   ```bash
   cd silentsave
   ```

2. **Get dependencies:**
   ```bash
   flutter pub get
   ```

3. **Run the app:**
   ```bash
   flutter run
   ```

### First-Time Setup

1. **Grant Notification Access:**
   - Open the app
   - Tap "Enable" on the permission warning banner
   - Enable "SilentSave Notification Listener" in Android settings
   - Return to the app

2. **Optional: Enable Encryption:**
   - Tap the lock icon in the app bar
   - Confirm to enable encryption for future messages

## 🔒 Privacy & Security

### Data Storage
- All data is stored locally in SQLite database
- Database location: `/data/data/com.silentsave.silentsave/databases/silentsave.db`
- No network permissions - data never leaves your device

### Encryption
- Optional AES-256 encryption for messages
- Encryption keys stored in Android Keystore via flutter_secure_storage
- Existing messages remain unencrypted when enabling encryption

### Auto Cleanup
- Messages are automatically deleted after 15 days
- Cleanup job runs daily at low battery usage times
- Manual cleanup can be triggered by restarting the app

## 📁 Project Structure

```
silentsave/
├── lib/
│   ├── main.dart                          # App entry point
│   ├── models/
│   │   └── message_model.dart             # Message data model
│   ├── screens/
│   │   ├── home_screen.dart               # Conversation list
│   │   └── conversation_screen.dart       # Message history
│   └── services/
│       ├── database_helper.dart           # SQLite operations
│       ├── encryption_service.dart        # AES encryption
│       └── notification_service.dart      # Native communication
├── android/
│   └── app/src/main/
│       ├── AndroidManifest.xml            # Permissions & services
│       └── kotlin/com/silentsave/silentsave/
│           ├── MainActivity.kt            # MethodChannel handler
│           ├── NotificationListener.kt    # Notification capture
│           └── CleanupWorker.kt           # Daily cleanup job
└── pubspec.yaml                           # Dependencies
```

## 🛠️ How It Works

### Notification Capture Flow

1. **WhatsApp/Instagram** sends a notification
2. **NotificationListenerService** intercepts it
3. Notification data is stored in **SharedPreferences**
4. **Flutter app** polls every 2 seconds
5. New notification data is saved to **SQLite**
6. **UI updates** to show new message

### Message Deletion Detection

1. When a notification is **removed** (e.g., WhatsApp message deleted)
2. **NotificationListenerService** detects removal
3. Matching message is marked as `isDeleted = 1`
4. **UI shows** red border and strikethrough text

### Cleanup Job

1. **WorkManager** schedules daily job
2. Job runs when device is not low on battery
3. Deletes messages older than 15 days from database
4. First run is 1 hour after app launch, then every 24 hours

## 🔧 Customization

### Change Auto-Delete Period

Edit `database_helper.dart`:
```dart
Future<int> deleteOldMessages() async {
  final db = await database;
  final fifteenDaysAgo = DateTime.now().subtract(const Duration(days: 30)); // Change here
  // ...
}
```

### Add More Apps

Edit `NotificationListener.kt`:
```kotlin
private val SUPPORTED_PACKAGES = listOf(
    "com.whatsapp",
    "com.instagram.android",
    "com.facebook.orca" // Add Messenger
)
```

### Modify Cleanup Schedule

Edit `MainActivity.kt`:
```kotlin
val cleanupRequest = PeriodicWorkRequestBuilder<CleanupWorker>(
    7, TimeUnit.DAYS  // Run weekly instead of daily
)
```

## 🐛 Troubleshooting

### Messages Not Being Captured

1. Check notification access is enabled:
   - Settings → Apps → Special app access → Notification access
   - Enable for SilentSave

2. Ensure WhatsApp/Instagram notifications are enabled

3. Check if app is running in background

### Deleted Messages Not Showing

- Deleted message detection works when WhatsApp removes the notification
- If notifications are dismissed manually, they won't be marked as deleted

### Encryption Issues

- If you enable encryption and later disable it, old encrypted messages may not decrypt
- Consider this permanent once enabled

## 📋 Known Limitations

1. **Notification Preview Only:** Only captures what appears in the notification (usually first line of message)
2. **No Media:** Cannot capture images, videos, or voice messages
3. **Group Messages:** Shows group name as sender, not individual senders
4. **Requires App Running:** App must be installed and not force-stopped
5. **Android Only:** This is an Android-specific app using NotificationListenerService

## 🔐 Permissions Required

- **Notification Access:** To read WhatsApp and Instagram notifications
- **Storage:** For SQLite database (automatic)

## 📝 License

This is personal software for private use. Not licensed for distribution or commercial use.

## ⚠️ Disclaimer

This app is designed for personal archival purposes. Users are responsible for ensuring compliance with local laws and the terms of service of WhatsApp and Instagram. The developers assume no liability for misuse.

## 🤝 Contributing

This is a personal project, but you can fork it and customize for your own use.

## 📞 Support

For issues or questions, please refer to the source code comments or Flutter/Android documentation.

---

**Built with Flutter 💙 and Kotlin**

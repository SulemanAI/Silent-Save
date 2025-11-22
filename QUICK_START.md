# 📱 SilentSave - Quick Start Guide

A personal Android app to capture and archive WhatsApp and Instagram message notifications.

---

## 🚀 Quick Start (5 Steps)

### Step 1: Install Dependencies
```bash
cd silentsave
flutter pub get
```

### Step 2: Connect Android Device
```bash
# Enable Developer Mode and USB Debugging on your Android device
# Connect via USB and authorize the computer
flutter devices
```

### Step 3: Run the App
```bash
flutter run
```

### Step 4: Grant Notification Access
1. Open the app on your device
2. You'll see an **orange warning banner**
3. Tap the **"Enable"** button
4. In Android settings, toggle on **"SilentSave Notification Listener"**
5. Return to the app (the warning should disappear)

### Step 5: Test It!
1. Send yourself a test WhatsApp or Instagram message
2. Check if it appears in SilentSave
3. Delete the WhatsApp message
4. See it marked as deleted in SilentSave ✅

---

## 📖 User Guide

### Home Screen

**🔍 Search Bar**
- Type to filter conversations by sender name
- Real-time filtering as you type
- Tap X to clear search

**📋 Conversation List**
- Shows grouped conversations by sender
- Displays message count and last message time
- Emoji badge indicates app (💬 = WhatsApp, 📸 = Instagram)
- Tap a conversation to view message history

**🔒 Encryption Toggle** (Top right)
- Lock icon: Tap to enable/disable encryption
- Green = Enabled, Gray = Disabled
- Only encrypts **future** messages

**🔄 Refresh** (Top right)
- Tap to reload conversations
- Also works with pull-to-refresh gesture

### Conversation Screen

**💬 Message Bubbles**
- Blue/purple background for active messages
- Timestamp below each message
- Most recent messages at bottom

**🗑️ Deleted Messages**
- Red border around message
- Strikethrough text
- Delete icon with "Message deleted" label
- Shows when WhatsApp message was recalled

### Permission Warning

If notification access is **not granted**, you'll see:

```
⚠️ Notification Access Required
Enable notification access to capture messages
[Enable Button]
```

Tap **Enable** to open Android settings.

---

## ⚙️ Settings & Features

### Enable Encryption

1. Tap **lock icon** in top right
2. Read the warning dialog
3. Tap **"Enable"**
4. Future messages will be encrypted with AES-256
5. Encryption keys are stored in Android Keystore

**⚠️ Important:**
- Only encrypts **new** messages after enabling
- Old messages remain unencrypted
- Disabling encryption won't decrypt old messages
- If keys are lost, encrypted messages are unrecoverable

### Auto-Delete Messages (15 Days)

**How it works:**
- Automatically enabled when you launch the app
- Daily cleanup job runs every 24 hours
- Deletes messages older than 15 days
- First cleanup runs 1 hour after app launch

**Manual cleanup:**
- Restart the app to trigger immediate cleanup
- Or wait for the daily job

### Search Messages

1. Tap the **search bar** on home screen
2. Type sender name or message content
3. Results filter in real-time
4. Tap **X** to clear and show all

---

## 🔐 Privacy & Security

### What This App Does
✅ Captures notification previews from WhatsApp and Instagram  
✅ Stores them locally in a SQLite database  
✅ Deletes messages automatically after 15 days  
✅ Optionally encrypts messages with AES-256  

### What This App Does NOT Do
❌ Does not access your actual WhatsApp/Instagram messages  
❌ Does not send data to any server  
❌ Does not require internet access  
❌ Does not capture media (images, videos, voice notes)  
❌ Cannot read messages sent before app was installed  

### Data Location
- **Database:** `/data/data/com.silentsave.silentsave/databases/silentsave.db`
- **Encryption Keys:** Android Keystore (hardware-backed)
- **No backups:** Data is not backed up to cloud

---

## 🐛 Troubleshooting

### "Messages not appearing in the app"

**Check:**
1. ✅ Notification access is enabled:
   - Settings → Apps → Special app access → Notification access
   - "SilentSave Notification Listener" is ON

2. ✅ WhatsApp/Instagram notifications are enabled:
   - Open WhatsApp/Instagram
   - Settings → Notifications → Enable all

3. ✅ App is not force-stopped:
   - Don't swipe away the app from recent apps
   - Android may kill background processes

4. ✅ Test with a real message:
   - Ask a friend to send you a message
   - Or send yourself a message from another device

### "Deleted messages not showing as deleted"

**Note:** This only works when **WhatsApp deletes the notification**

✅ **Will work:**
- Someone sends a message then recalls it
- WhatsApp removes the notification automatically

❌ **Won't work:**
- You manually swipe away the notification
- You clear all notifications

### "Encryption not working"

**Check:**
1. ✅ Encryption was enabled **before** receiving messages
2. ✅ Lock icon shows **green** (enabled)
3. ✅ Try disabling and re-enabling encryption

**If encrypted messages show as gibberish:**
- This means encryption keys were lost or changed
- Encrypted messages cannot be recovered
- Disable encryption and start fresh

### "App crashes on launch"

**Try:**
1. Uninstall and reinstall the app
2. Check Android version is 5.0+ (API 21+)
3. Check storage space is available
4. View logs: `flutter logs`

---

## 🎯 Best Practices

### For Maximum Privacy
1. ✅ Enable encryption immediately after installation
2. ✅ Don't root your device (encryption keys could be compromised)
3. ✅ Use a strong device lock screen (PIN/password/fingerprint)
4. ✅ Don't share your device with others

### For Best Performance
1. ✅ Restart the app occasionally to free memory
2. ✅ Let the auto-cleanup job run (don't force-stop app)
3. ✅ Don't store millions of messages (15-day limit is good)

### For Reliability
1. ✅ Keep notification access enabled
2. ✅ Don't disable battery optimization for WhatsApp/Instagram
3. ✅ Update WhatsApp/Instagram regularly (notification format may change)

---

## 📊 Understanding the Data

### What Gets Captured

**From WhatsApp:**
```
Title: "John Doe" (or group name)
Text: "Hey, how are you?" (first line only)
App: com.whatsapp
Timestamp: 2025-11-23 15:30:45
```

**From Instagram:**
```
Title: "jane_doe"
Text: "Saw your story!" (preview only)
App: com.instagram.android
Timestamp: 2025-11-23 16:20:10
```

### What Does NOT Get Captured
- ❌ Full message content (only notification preview)
- ❌ Images, videos, GIFs
- ❌ Voice notes
- ❌ Stickers, reactions
- ❌ Messages sent before app was installed
- ❌ Messages when notifications are disabled

---

## 🔧 Advanced Usage

### Customizing Auto-Delete Period

Edit `lib/services/database_helper.dart`:

```dart
Future<int> deleteOldMessages() async {
  final db = await database;
  final fifteenDaysAgo = DateTime.now().subtract(const Duration(days: 30)); // Change to 30 days
  // ...
}
```

### Adding More Apps

Edit `android/app/src/main/kotlin/com/silentsave/silentsave/NotificationListener.kt`:

```kotlin
private val WHATSAPP_PACKAGE = "com.whatsapp"
private val INSTAGRAM_PACKAGE = "com.instagram.android"
private val MESSENGER_PACKAGE = "com.facebook.orca" // Add Messenger
```

Then update the filter logic to include the new package.

### Changing Cleanup Schedule

Edit `android/app/src/main/kotlin/com/silentsave/silentsave/MainActivity.kt`:

```kotlin
val cleanupRequest = PeriodicWorkRequestBuilder<CleanupWorker>(
    7, TimeUnit.DAYS  // Change to weekly instead of daily
)
```

---

## 📱 Tested Devices

This app has been designed for:
- **Android 5.0 (Lollipop)** or higher (API 21+)
- Physical devices and emulators
- All screen sizes

**Known to work with:**
- WhatsApp (all versions)
- WhatsApp Business
- Instagram (all versions)

---

## ⚖️ Legal & Ethical Use

### ✅ Acceptable Use
- Personal archival of your own messages
- Backup for important conversations
- Recovering deleted messages you received

### ❌ Unacceptable Use
- Spying on others without consent
- Publishing or distributing captured messages
- Using for commercial purposes
- Violating WhatsApp/Instagram Terms of Service

**Disclaimer:** This app is for personal use only. Users are responsible for ensuring compliance with local laws and platform terms of service.

---

## 🆘 Support

### Getting Help

1. **Check the docs:**
   - `README.md` - Overview and setup
   - `TECHNICAL_DOCS.md` - Technical details
   - `BUILD_OUTPUT.md` - Build summary

2. **Check logs:**
   ```bash
   flutter logs
   ```

3. **Rebuild:**
   ```bash
   flutter clean
   flutter pub get
   flutter run
   ```

### Common Issues

| Issue | Solution |
|-------|----------|
| App not appearing in notification listener settings | Reinstall the app |
| Messages duplicating | Clear app data and restart |
| Search not working | Pull to refresh, then try again |
| Encryption keys lost | No recovery possible, disable encryption |

---

## 🎉 You're All Set!

Your SilentSave app is now ready to capture and archive your WhatsApp and Instagram message notifications!

**Remember:**
- ✅ Enable notification access
- ✅ Optionally enable encryption
- ✅ Messages auto-delete after 15 days
- ✅ All data stays on your device

Enjoy your private message archive! 📱🔒

---

**Need help?** Check `TECHNICAL_DOCS.md` for detailed information.

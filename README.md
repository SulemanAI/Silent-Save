# SilentSave - Personal Message & Media Archive

**SilentSave** is an advanced, offline-first Android application that captures and preserves notification messages and media (photos, videos, voice notes, audio, stickers, and documents) from WhatsApp, WhatsApp Business, and Instagram Direct. All data remains completely offline, secure, and private on your device.

---

## 🌟 Key Features

### 📩 Message Archiving & Anti-Delete Preservation
- **Auto Capture**: Intercepts and archives incoming notification text, timestamps, sender names, group info, and app origins in real time.
- **Anti-Delete Preservation**: Instantly saves incoming messages and media before the sender can use "Delete for Everyone" (WhatsApp) or un-send (Instagram), keeping the content permanently preserved in your local archive.
- **Group Chat Intelligence**: Correctly isolates individual sender names within group conversations (`Sender: Message`), maintaining accurate user attribution.
- **Advanced Deduplication**: High-speed hash-based dedup avoids duplicate messages from continuous notification updates.

### 🖼️ Zero-Touch Media Capture Engine
- **Full Media Support**: Automatically links and archives:
  - 📷 **Images & Photos** (JPEG, PNG, WebP)
  - 🎥 **Videos** (MP4, MKV, 3GP, MOV)
  - 🎙️ **Voice Notes & Audio** (Opus, OGG, MP3, M4A, WAV)
  - 📄 **Documents** (PDF, DOC/DOCX, XLS/XLSX, CSV, PPTX, TXT, ZIP)
  - 💟 **Stickers** (WebP)
- **Zero-Touch Background Storage Access Framework (SAF)**: Continuously monitors WhatsApp incoming media directories with intelligent burst backoff and WakeLock management.
- **Direct Notification Byte Streaming**: Extracts BigPicture images and inline notification data URIs directly into internal storage before senders can delete them.
- **1-to-1 Media Uniqueness**: Strict database and filesystem constraints ensure a single media file is never duplicated or cross-linked to unrelated chats.

### 📋 Native Media Sharing & Clipboard Copying
- **Copy Media to Clipboard**: Copies the actual image, video, audio, or document file via `FileProvider` content URIs and proper MIME types directly to Android's `ClipboardManager`. Compatible keyboards (Gboard, Samsung Keyboard) and messaging apps (WhatsApp, Telegram, Notes) can paste the media directly.
- **Native File Sharing**: Shares real media files (with user captions preserved) directly to external apps via `SharePlus` rather than sharing plain text placeholders (`"📷 Photo"`).
- **In-App Save**: Save photos/videos directly to device Gallery via `Gal` or export audio/voice notes to public Downloads (`/Download/SilentSave`).

### 🔍 Rich Media Viewer & Playback
- **Full-Screen Media Viewer**: Multi-format viewer featuring interactive zoomable image viewing, integrated video player controls, voice note/audio playback, and instant copy/share/download actions.
- **Document Launcher**: One-tap opening of PDFs, spreadsheets, and documents via default system viewer apps.

### 🕵️ Silent Capture Suite
- **Stealth Photo Capture**: Front or rear camera capture in background.
- **Stealth Video Recording**: Configurable background recording (duration & quality presets).
- **Stealth Audio Recording**: Low-profile background microphone capture.
- **Media Bin & Recovery**: Built-in 24-hour Trash Bin with restore, permanent delete, and auto-cleanup.

### 🛡️ Privacy, Security & Resilience
- **100% Offline & Private**: Zero cloud sync, zero telemetry. All database records and media files stay on the local device.
- **Biometric Security**: Protect chat history with Fingerprint and Face Unlock (`local_auth`).
- **OEM Battery Kill Prevention**: Includes `KeepAliveService` foreground service and `NlsHealthWorker` to prevent aggressive OEM battery managers (Transsion/Infinix, Xiaomi/MIUI, Samsung) from terminating the Notification Listener Service.
- **Automated Retention & Cleanup**: Daily WorkManager background maintenance with 15-day automated message retention.

---

## 🏗️ Architecture

```
                               ┌──────────────────────────────────────────────────────────┐
                               │                    Android System                        │
                               │ (WhatsApp / Instagram / System Notification Service)     │
                               └────────────────────────────┬─────────────────────────────┘
                                                            │
                                ┌───────────────────────────┴─────────────────────────────┐
                                │                 Native Android Layer (Kotlin)           │
                                ├─────────────────────────────────────────────────────────┤
                                │ • NotificationListener (NLS byte extraction)            │
                                │ • MediaWatcherService (SAF directory burst observer)    │
                                │ • KeepAliveService & NlsHealthWorker                    │
                                │ • SilentCaptureService (CameraX & AudioRecord)          │
                                │ • NativeDatabaseHelper (Direct SQLite synchronization)  │
                                │ • FileProvider & ClipboardManager integration           │
                                └───────────────────────────┬─────────────────────────────┘
                                                            │ MethodChannel & SQLite
                                ┌───────────────────────────┴─────────────────────────────┐
                                │                 Flutter Application (Dart)              │
                                ├─────────────────────────────────────────────────────────┤
                                │ • DatabaseHelper (SQLite transactions & 1-1 constraints)│
                                │ • NotificationService (Event dispatcher & hybrid sync)  │
                                │ • ConversationScreen (Group/DM chat view, copy/share)   │
                                │ • FullScreenMediaViewer (Image, Video, Audio viewer)    │
                                │ • CaptureScreen & TrashScreen (Stealth capture suite)   │
                                └─────────────────────────────────────────────────────────┘
```

---

## 📊 Database Schema

```sql
CREATE TABLE messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sender TEXT NOT NULL,
  senderName TEXT,
  message TEXT NOT NULL,
  app TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  isDeleted INTEGER DEFAULT 0,
  isRead INTEGER DEFAULT 0,
  isGroupChat INTEGER DEFAULT 0,
  avatarPath TEXT,
  mediaPath TEXT
);

-- Performance Indexes
CREATE INDEX idx_dedup ON messages(sender, app, message, timestamp);
CREATE INDEX idx_sender ON messages(sender);
CREATE INDEX idx_conversations_base ON messages(sender, app, isDeleted, timestamp);
CREATE INDEX idx_unread_count ON messages(sender, app, isDeleted, isRead);
CREATE INDEX idx_mediaPath ON messages(mediaPath);
```

---

## 🚀 Setup Instructions

### Prerequisites
- Flutter SDK (3.24.0 or higher)
- Android SDK (minSdkVersion 24, targetSdkVersion 34)
- Physical Android device (recommended for testing NotificationListenerService & SAF)

### Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/your-username/silentsave.git
   cd silentsave
   ```

2. **Install Flutter dependencies:**
   ```bash
   flutter pub get
   ```

3. **Run on your connected Android device:**
   ```bash
   flutter run --release
   ```

### First-Time Permission Setup

1. **Notification Listener Permission**:
   - Open SilentSave.
   - Tap **Enable** on the Notification Access banner.
   - Toggle **SilentSave Notification Listener** to ON in Android Settings.
2. **WhatsApp Media Folder Access (SAF)**:
   - Go to App Settings / Media Setup.
   - Grant read access to the WhatsApp Media directory (`Android/media/com.whatsapp/WhatsApp/Media`) using Android's system document picker.
3. **Battery Optimization Exemption**:
   - Allow SilentSave to ignore battery optimization to ensure persistent zero-touch background capture even when the phone is idle or in Doze mode.

---

## 📋 Permissions Summary

| Permission | Purpose |
| :--- | :--- |
| `BIND_NOTIFICATION_LISTENER_SERVICE` | Intercept incoming notification previews and data URIs |
| `FOREGROUND_SERVICE` & `FOREGROUND_SERVICE_DATA_SYNC` | Keep the capture pipeline active across OEM process killers |
| `RECEIVE_BOOT_COMPLETED` | Ensure services automatically restart after device reboot |
| `WAKE_LOCK` | Perform rapid background media scans when new notifications arrive |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Request exemption from OEM battery throttling |
| `ACTION_OPEN_DOCUMENT_TREE` (SAF) | Zero-touch reading of downloaded media in WhatsApp directories |
| `CAMERA` & `RECORD_AUDIO` | Required exclusively for optional Silent Capture suite |
| `USE_BIOMETRIC` | Biometric fingerprint/face screen lock |

---

## 📁 Project Structure

```
silentsave/
├── android/
│   └── app/src/main/
│       ├── AndroidManifest.xml                  # Permissions, services, and FileProvider
│       ├── res/xml/file_paths.xml               # Configured paths for FileProvider sharing
│       └── kotlin/com/silentsave/silentsave/
│           ├── MainActivity.kt                  # MethodChannel bridge & ClipboardManager
│           ├── NotificationListener.kt          # Native notification capture & byte streaming
│           ├── MediaWatcherService.kt           # SAF observer, burst scanner, WakeLocks
│           ├── NativeDatabaseHelper.kt          # Direct native SQLite synchronization
│           ├── KeepAliveService.kt              # Persistent foreground guard service
│           ├── SilentCaptureService.kt          # Stealth photo/video/audio recorder
│           ├── BootReceiver.kt                  # Rebinds NLS on device reboot
│           ├── NlsHealthWorker.kt               # NLS watchdog worker
│           └── CleanupWorker.kt                 # Daily SQLite retention worker
└── lib/
    ├── main.dart                                # Entry point & biometric check
    ├── models/
    │   └── message_model.dart                   # Chat message data model
    ├── screens/
    │   ├── home_screen.dart                     # Conversation list & status dashboard
    │   ├── conversation_screen.dart             # Message timeline, media copy & share
    │   ├── capture_screen.dart                  # Silent capture suite dashboard
    │   ├── trash_screen.dart                    # 24-hour recycle bin for silent captures
    │   ├── settings_screen.dart                 # SAF folder setup & battery configuration
    │   └── chat_info_screen.dart                # Chat details & media gallery
    ├── services/
    │   ├── database_helper.dart                 # SQLite helper, migrations & 1-1 media rules
    │   └── notification_service.dart            # Flutter-Native channel bridge
    ├── utils/
    │   └── timestamp_matcher.dart               # Heuristic timestamp & filename matcher
    └── widgets/
        ├── full_screen_media_viewer.dart        # Image/video/audio viewer with copy & share
        └── video_thumbnail_widget.dart          # Video preview generator
```

---

## 🔒 Security & Privacy Notice

- **All Data Stays On Your Device**: SilentSave contains **no internet networking code** for syncing data to remote servers.
- **Local SQLite Storage**: Encapsulated within app-private internal storage (`/data/data/com.silentsave.silentsave/`).
- **Personal Archival Only**: This tool is designed strictly for personal message and media backup. Please use responsibly and in compliance with all applicable local privacy laws and platform terms of service.

---

## 📝 License

Distributed under the MIT License. See [LICENSE](LICENSE) for more information.

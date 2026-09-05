import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _isLoading = true;
  double _dbSizeMb = 0.0;
  double _avatarsSizeMb = 0.0;
  double _captureSizeMb = 0.0;
  double _totalSizeMb = 0.0;

  // Capture settings
  bool _useFrontCamera = false;
  int _videoDurationSec = 0;
  int _audioDurationSec = 0;
  String _videoQuality = '720p';

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _calculateStorage();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _useFrontCamera = prefs.getBool('capture_use_front_camera') ?? false;
      _videoDurationSec = prefs.getInt('capture_video_duration') ?? 0;
      _audioDurationSec = prefs.getInt('capture_audio_duration') ?? 0;
      _videoQuality = prefs.getString('capture_video_quality') ?? '720p';
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('capture_use_front_camera', _useFrontCamera);
    await prefs.setInt('capture_video_duration', _videoDurationSec);
    await prefs.setInt('capture_audio_duration', _audioDurationSec);
    await prefs.setString('capture_video_quality', _videoQuality);
  }

  Future<void> _calculateStorage() async {
    double dbSize = 0;
    double avatarsSize = 0;
    double captureSize = 0;

    try {
      // DB Size
      final dbPath = await getDatabasesPath();
      final dbFile = File(p.join(dbPath, 'silentsave.db'));
      if (dbFile.existsSync()) {
        dbSize = dbFile.lengthSync() / (1024 * 1024);
      }
    } catch (e) {
      debugPrint("Error calculating db size: $e");
    }

    try {
      // Avatars Size
      final supportDir = await getApplicationSupportDirectory();
      final avatarsDir = Directory('${supportDir.path}/avatars');
      if (avatarsDir.existsSync()) {
        int totalBytes = 0;
        await for (var entity in avatarsDir.list(recursive: true, followLinks: false)) {
          if (entity is File) {
            totalBytes += entity.lengthSync();
          }
        }
        avatarsSize = totalBytes / (1024 * 1024);
      }
    } catch (e) {
      debugPrint("Error calculating avatars size: $e");
    }

    try {
      // Capture folder size
      final externalDir = await getExternalStorageDirectory();
      if (externalDir != null) {
        final captureDir = Directory('${externalDir.path}/SilentCapture');
        if (captureDir.existsSync()) {
          int totalBytes = 0;
          await for (var entity in captureDir.list(recursive: true, followLinks: false)) {
            if (entity is File) {
              totalBytes += entity.lengthSync();
            }
          }
          captureSize = totalBytes / (1024 * 1024);
        }
      }
    } catch (e) {
      debugPrint("Error calculating capture size: $e");
    }

    setState(() {
      _dbSizeMb = dbSize;
      _avatarsSizeMb = avatarsSize;
      _captureSizeMb = captureSize;
      _totalSizeMb = dbSize + avatarsSize + captureSize;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        elevation: 0,
        backgroundColor: Colors.deepPurple.shade800,
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.grey.shade900, Colors.black87],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: _isLoading
            ? const Center(child: CircularProgressIndicator(color: Colors.deepPurple))
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // ── Capture Settings ─────────────────────────────────
                  const Text(
                    'Capture Settings',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const SizedBox(height: 16),
                  
                  // Camera selection
                  _buildSettingsTile(
                    icon: Icons.flip_camera_android,
                    title: 'Camera',
                    subtitle: _useFrontCamera ? 'Front camera' : 'Back camera',
                    trailing: Switch(
                      value: _useFrontCamera,
                      onChanged: (value) {
                        setState(() => _useFrontCamera = value);
                        _saveSettings();
                      },
                      activeThumbColor: Colors.deepPurpleAccent,
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Video duration
                  _buildSettingsTile(
                    icon: Icons.videocam,
                    title: 'Video Duration',
                    subtitle: _videoDurationSec == 0 ? 'Unlimited' : '${_videoDurationSec}s',
                    trailing: DropdownButton<int>(
                      value: _videoDurationSec,
                      dropdownColor: Colors.grey.shade800,
                      underline: const SizedBox(),
                      items: const [
                        DropdownMenuItem(value: 0, child: Text('Unlimited', style: TextStyle(color: Colors.white))),
                        DropdownMenuItem(value: 15, child: Text('15s', style: TextStyle(color: Colors.white))),
                        DropdownMenuItem(value: 30, child: Text('30s', style: TextStyle(color: Colors.white))),
                        DropdownMenuItem(value: 60, child: Text('60s', style: TextStyle(color: Colors.white))),
                        DropdownMenuItem(value: 120, child: Text('120s', style: TextStyle(color: Colors.white))),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => _videoDurationSec = value);
                          _saveSettings();
                        }
                      },
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Audio duration
                  _buildSettingsTile(
                    icon: Icons.mic,
                    title: 'Audio Duration',
                    subtitle: _audioDurationSec == 0 ? 'Unlimited' : '${_audioDurationSec}s',
                    trailing: DropdownButton<int>(
                      value: _audioDurationSec,
                      dropdownColor: Colors.grey.shade800,
                      underline: const SizedBox(),
                      items: const [
                        DropdownMenuItem(value: 0, child: Text('Unlimited', style: TextStyle(color: Colors.white))),
                        DropdownMenuItem(value: 30, child: Text('30s', style: TextStyle(color: Colors.white))),
                        DropdownMenuItem(value: 60, child: Text('60s', style: TextStyle(color: Colors.white))),
                        DropdownMenuItem(value: 120, child: Text('120s', style: TextStyle(color: Colors.white))),
                        DropdownMenuItem(value: 300, child: Text('300s', style: TextStyle(color: Colors.white))),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => _audioDurationSec = value);
                          _saveSettings();
                        }
                      },
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Video quality
                  _buildSettingsTile(
                    icon: Icons.high_quality,
                    title: 'Video Quality',
                    subtitle: _videoQuality,
                    trailing: DropdownButton<String>(
                      value: _videoQuality,
                      dropdownColor: Colors.grey.shade800,
                      underline: const SizedBox(),
                      items: const [
                        DropdownMenuItem(value: '720p', child: Text('720p', style: TextStyle(color: Colors.white))),
                        DropdownMenuItem(value: '1080p', child: Text('1080p', style: TextStyle(color: Colors.white))),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => _videoQuality = value);
                          _saveSettings();
                        }
                      },
                    ),
                  ),
                  
                  const SizedBox(height: 32),
                  
                  // ── Storage Usage ─────────────────────────────────────
                  const Text(
                    'Storage Usage',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const SizedBox(height: 16),
                  _buildStorageItem(Icons.storage, 'Database (Messages)', _dbSizeMb),
                  const SizedBox(height: 12),
                  _buildStorageItem(Icons.image, 'Avatars & Media', _avatarsSizeMb),
                  const SizedBox(height: 12),
                  _buildStorageItem(Icons.camera_alt, 'Captures', _captureSizeMb),
                  const Divider(color: Colors.grey, height: 32),
                  _buildStorageItem(Icons.data_usage, 'Total Usage', _totalSizeMb, isTotal: true),
                ],
              ),
      ),
    );
  }

  Widget _buildSettingsTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget trailing,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey.shade800.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.deepPurpleAccent, size: 24),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 15, color: Colors.white)),
                Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
              ],
            ),
          ),
          trailing,
        ],
      ),
    );
  }

  Widget _buildStorageItem(IconData icon, String title, double sizeMb, {bool isTotal = false}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isTotal ? Colors.deepPurple.shade800.withValues(alpha: 0.3) : Colors.grey.shade800.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: isTotal ? Border.all(color: Colors.deepPurple.shade500) : null,
      ),
      child: Row(
        children: [
          Icon(icon, color: isTotal ? Colors.deepPurpleAccent : Colors.grey.shade400, size: 28),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: isTotal ? FontWeight.bold : FontWeight.normal,
                color: Colors.white,
              ),
            ),
          ),
          Text(
            '${sizeMb.toStringAsFixed(2)} MB',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: isTotal ? Colors.deepPurpleAccent : Colors.white70,
            ),
          ),
        ],
      ),
    );
  }
}

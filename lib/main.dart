import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'services/notification_service.dart';
import 'services/encryption_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Cap image cache to prevent uncompressed bitmap accumulation from ballooning RSS past OEM thresholds
  PaintingBinding.instance.imageCache.maximumSizeBytes = 50 * 1024 * 1024; // 50 MB
  PaintingBinding.instance.imageCache.maximumSize = 100;
  
  // Initialize services with error handling to prevent app crash on startup
  try {
    await EncryptionService.instance.initializeEncryption()
        .timeout(const Duration(seconds: 5), onTimeout: () {
      debugPrint('Encryption initialization timed out');
    });
  } catch (e) {
    // Log but don't crash - encryption will be re-attempted when needed
    debugPrint('Encryption initialization failed: $e');
  }
  
  // Run app first, then schedule cleanup in background
  runApp(const SilentSaveApp());
  
  // Schedule cleanup and request battery optimization exemption after app is running.
  Future.delayed(const Duration(seconds: 2), () async {
    try {
      await NotificationService.instance.scheduleCleanupJob()
          .timeout(const Duration(seconds: 5), onTimeout: () {
        debugPrint('Cleanup job scheduling timed out');
      });
    } catch (e) {
      debugPrint('Cleanup job scheduling failed: $e');
    }
    try {
      await NotificationService.instance.requestBatteryOptimizationExemption()
          .timeout(const Duration(seconds: 5), onTimeout: () {
        debugPrint('Battery optimization exemption request timed out');
      });
    } catch (e) {
      debugPrint('Battery optimization exemption request failed: $e');
    }
  });
}

class SilentSaveApp extends StatelessWidget {
  const SilentSaveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Silent Save',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        cardTheme: const CardThemeData(
          elevation: 2,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'services/notification_service.dart';
import 'services/encryption_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
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
  
  // Schedule cleanup after app is running (non-blocking)
  Future.delayed(const Duration(seconds: 2), () async {
    try {
      await NotificationService.instance.scheduleCleanupJob()
          .timeout(const Duration(seconds: 5), onTimeout: () {
        debugPrint('Cleanup job scheduling timed out');
      });
    } catch (e) {
      debugPrint('Cleanup job scheduling failed: $e');
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

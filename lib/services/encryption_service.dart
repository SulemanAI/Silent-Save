import 'dart:async';
import 'package:flutter/foundation.dart' hide Key;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:encrypt/encrypt.dart';

class EncryptionService {
  static final EncryptionService instance = EncryptionService._init();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      resetOnError: true,  // Reset storage if corrupted
    ),
  );
  
  Encrypter? _encrypter;
  IV? _iv;
  
  // Race condition prevention: track initialization state
  bool _isInitializing = false;
  Completer<void>? _initCompleter;

  EncryptionService._init();

  static const String _keyStorageKey = 'encryption_key';
  static const String _ivStorageKey = 'encryption_iv';
  static const String _enabledStorageKey = 'encryption_enabled';

  Future<void> initializeEncryption() async {
    // Race condition prevention: if already initializing, wait for it to complete
    if (_isInitializing && _initCompleter != null) {
      return _initCompleter!.future;
    }
    
    // Start initialization first to prevent race conditions
    _isInitializing = true;
    _initCompleter = Completer<void>();
    
    try {
      // Check if encryption is enabled (with error handling)
      bool enabled;
      try {
        enabled = await isEncryptionEnabled();
      } catch (e) {
        // If we can't read encryption status, reset and disable
        debugPrint('[EncryptionService] Error checking encryption status, resetting: $e');
        await _resetStorage();
        enabled = false;
      }
      
      if (!enabled) {
        _initCompleter!.complete();
        return;
      }
      
      // Already initialized
      if (_encrypter != null && _iv != null) {
        _initCompleter!.complete();
        return;
      }
      
      // Get or create encryption key
      String? keyString;
      String? ivString;
      
      try {
        keyString = await _secureStorage.read(key: _keyStorageKey);
        ivString = await _secureStorage.read(key: _ivStorageKey);
      } catch (e) {
        // If reading fails (corrupted storage), reset everything
        debugPrint('[EncryptionService] Storage corrupted while reading keys, resetting: $e');
        await _resetStorage();
        keyString = null;
        ivString = null;
      }

      if (keyString == null || ivString == null) {
        // Generate new key and IV
        final key = Key.fromSecureRandom(32);
        final iv = IV.fromSecureRandom(16);

        try {
          await _secureStorage.write(key: _keyStorageKey, value: key.base64);
          await _secureStorage.write(key: _ivStorageKey, value: iv.base64);
        } catch (e) {
          debugPrint('[EncryptionService] Error writing new keys, resetting: $e');
          await _resetStorage();
          // Try writing again after reset
          await _secureStorage.write(key: _keyStorageKey, value: key.base64);
          await _secureStorage.write(key: _ivStorageKey, value: iv.base64);
        }

        _encrypter = Encrypter(AES(key));
        _iv = iv;
      } else {
        // Use existing key and IV
        final key = Key.fromBase64(keyString);
        final iv = IV.fromBase64(ivString);

        _encrypter = Encrypter(AES(key));
        _iv = iv;
      }
      
      _initCompleter!.complete();
    } catch (e) {
      debugPrint('[EncryptionService] Initialization error: $e');
      // Reset state on error so encryption is disabled
      _encrypter = null;
      _iv = null;
      // Reset storage to clear corrupted data
      await _resetStorage();
      // Complete the completer to allow callers to proceed (without encryption)
      _initCompleter!.complete();
      // Don't rethrow - allow graceful degradation to unencrypted mode
    } finally {
      _isInitializing = false;
    }
  }

  Future<void> _resetStorage() async {
    try {
      await _secureStorage.deleteAll();
      debugPrint('[EncryptionService] Storage reset complete');
    } catch (e) {
      debugPrint('[EncryptionService] Failed to reset storage: $e');
    }
  }

  Future<bool> isEncryptionEnabled() async {
    try {
      final enabled = await _secureStorage.read(key: _enabledStorageKey);
      return enabled == 'true';
    } catch (e) {
      // If we can't read, encryption is effectively disabled
      debugPrint('[EncryptionService] Error reading encryption status: $e');
      await _resetStorage();
      return false;
    }
  }

  Future<void> enableEncryption(bool enable) async {
    try {
      await _secureStorage.write(
        key: _enabledStorageKey,
        value: enable.toString(),
      );
      
      if (enable) {
        await initializeEncryption();
      } else {
        _encrypter = null;
        _iv = null;
      }
    } catch (e) {
      debugPrint('[EncryptionService] Error enabling encryption: $e');
      await _resetStorage();
    }
  }

  Future<String> encrypt(String plainText) async {
    try {
      if (_encrypter == null || _iv == null) {
        await initializeEncryption();
      }
      
      if (_encrypter == null || _iv == null) {
        return plainText; // Return as-is if encryption not initialized
      }

      final encrypted = _encrypter!.encrypt(plainText, iv: _iv);
      return encrypted.base64;
    } catch (e) {
      debugPrint('[EncryptionService] Encryption error: $e');
      return plainText; // Return unencrypted on error
    }
  }

  /// Check if text looks like AES-encrypted base64 output.
  /// Plain text (with spaces, emojis, punctuation) will fail this check,
  /// preventing noisy "Invalid or corrupted pad block" errors.
  bool _isLikelyEncrypted(String text) {
    if (text.isEmpty || text.length < 24) return false;
    // AES-CBC output in base64: only base64 chars, length is multiple of 4
    if (text.length % 4 != 0) return false;
    // Quick scan: if text contains spaces, newlines, or common non-base64 chars, it's plain text
    for (int i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      final isBase64 = (c >= 65 && c <= 90) ||  // A-Z
                       (c >= 97 && c <= 122) || // a-z
                       (c >= 48 && c <= 57) ||  // 0-9
                       c == 43 || c == 47 || c == 61; // + / =
      if (!isBase64) return false;
    }
    return true;
  }

  // Throttle decryption error logging
  int _decryptErrorCount = 0;
  static const int _maxDecryptErrors = 3;

  Future<String> decrypt(String encryptedText) async {
    try {
      // Quick check: if text doesn't look like base64-encoded ciphertext, return as-is
      if (!_isLikelyEncrypted(encryptedText)) {
        return encryptedText;
      }

      if (_encrypter == null || _iv == null) {
        await initializeEncryption();
      }
      
      if (_encrypter == null || _iv == null) {
        return encryptedText; // Return as-is if encryption not initialized
      }

      final encrypted = Encrypted.fromBase64(encryptedText);
      final result = _encrypter!.decrypt(encrypted, iv: _iv);
      _decryptErrorCount = 0; // Reset on success
      return result;
    } catch (e) {
      _decryptErrorCount++;
      if (_decryptErrorCount <= _maxDecryptErrors) {
        debugPrint('[EncryptionService] Decryption error ($_decryptErrorCount): $e');
        if (_decryptErrorCount == _maxDecryptErrors) {
          debugPrint('[EncryptionService] Suppressing further decryption errors');
        }
      }
      return encryptedText; // Return as-is if decryption fails
    }
  }

  Future<void> clearEncryptionKeys() async {
    await _secureStorage.delete(key: _keyStorageKey);
    await _secureStorage.delete(key: _ivStorageKey);
    await _secureStorage.delete(key: _enabledStorageKey);
    _encrypter = null;
    _iv = null;
  }
}

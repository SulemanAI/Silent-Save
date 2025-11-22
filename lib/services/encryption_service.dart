import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:encrypt/encrypt.dart';

class EncryptionService {
  static final EncryptionService instance = EncryptionService._init();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  
  Encrypter? _encrypter;
  IV? _iv;

  EncryptionService._init();

  static const String _keyStorageKey = 'encryption_key';
  static const String _ivStorageKey = 'encryption_iv';
  static const String _enabledStorageKey = 'encryption_enabled';

  Future<void> initializeEncryption() async {
    // Check if encryption is enabled
    final enabled = await isEncryptionEnabled();
    if (!enabled) return;

    // Get or create encryption key
    String? keyString = await _secureStorage.read(key: _keyStorageKey);
    String? ivString = await _secureStorage.read(key: _ivStorageKey);

    if (keyString == null || ivString == null) {
      // Generate new key and IV
      final key = Key.fromSecureRandom(32);
      final iv = IV.fromSecureRandom(16);

      await _secureStorage.write(key: _keyStorageKey, value: key.base64);
      await _secureStorage.write(key: _ivStorageKey, value: iv.base64);

      _encrypter = Encrypter(AES(key));
      _iv = iv;
    } else {
      // Use existing key and IV
      final key = Key.fromBase64(keyString);
      final iv = IV.fromBase64(ivString);

      _encrypter = Encrypter(AES(key));
      _iv = iv;
    }
  }

  Future<bool> isEncryptionEnabled() async {
    final enabled = await _secureStorage.read(key: _enabledStorageKey);
    return enabled == 'true';
  }

  Future<void> enableEncryption(bool enable) async {
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
  }

  Future<String> encrypt(String plainText) async {
    if (_encrypter == null || _iv == null) {
      await initializeEncryption();
    }
    
    if (_encrypter == null || _iv == null) {
      return plainText; // Return as-is if encryption not initialized
    }

    final encrypted = _encrypter!.encrypt(plainText, iv: _iv);
    return encrypted.base64;
  }

  Future<String> decrypt(String encryptedText) async {
    if (_encrypter == null || _iv == null) {
      await initializeEncryption();
    }
    
    if (_encrypter == null || _iv == null) {
      return encryptedText; // Return as-is if encryption not initialized
    }

    try {
      final encrypted = Encrypted.fromBase64(encryptedText);
      return _encrypter!.decrypt(encrypted, iv: _iv);
    } catch (e) {
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


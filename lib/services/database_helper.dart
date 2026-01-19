import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:flutter/foundation.dart';
import '../models/message_model.dart';
import 'encryption_service.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;
  final EncryptionService _encryptionService = EncryptionService.instance;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('silentsave.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 4,  // Updated for avatarPath column
      onCreate: _createDB,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Add isRead column for version 2
      await db.execute('ALTER TABLE messages ADD COLUMN isRead INTEGER DEFAULT 0');
    }
    if (oldVersion < 3) {
      // Add senderName and isGroupChat columns for version 3
      await db.execute('ALTER TABLE messages ADD COLUMN senderName TEXT');
      await db.execute('ALTER TABLE messages ADD COLUMN isGroupChat INTEGER DEFAULT 0');
    }
    if (oldVersion < 4) {
      // Add avatarPath column for version 4
      await db.execute('ALTER TABLE messages ADD COLUMN avatarPath TEXT');
    }
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sender TEXT NOT NULL,
        message TEXT NOT NULL,
        app TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        isDeleted INTEGER DEFAULT 0,
        isRead INTEGER DEFAULT 0,
        senderName TEXT,
        isGroupChat INTEGER DEFAULT 0,
        avatarPath TEXT
      )
    ''');

    // Create index for faster queries
    await db.execute('''
      CREATE INDEX idx_timestamp ON messages(timestamp)
    ''');
    
    await db.execute('''
      CREATE INDEX idx_sender ON messages(sender)
    ''');
  }

  Future<int> insertMessage(MessageModel message) async {
    final db = await database;
    
    debugPrint('[DatabaseHelper] Attempting to insert message: sender="${message.sender}", text="${message.message.substring(0, message.message.length > 30 ? 30 : message.message.length)}..."');
    
    // Encrypt message first if encryption is enabled
    final isEncrypted = await _encryptionService.isEncryptionEnabled();
    final encryptedMessage = isEncrypted
        ? await _encryptionService.encrypt(message.message)
        : message.message;
    
    // Check for duplicate message before inserting
    // A message is considered duplicate if it has the same sender, app, and content
    // within a 10-second window (to handle notification repeats)
    // We check against the encrypted message since that's what's stored in the database
    final duplicateCheck = await db.query(
      'messages',
      where: 'sender = ? AND app = ? AND message = ? AND ABS(timestamp - ?) < ?',
      whereArgs: [
        message.sender,
        message.app,
        encryptedMessage,
        message.timestamp.millisecondsSinceEpoch, 
        10000, // 10 second window on either side
      ],
      limit: 1,
    );
    
    if (duplicateCheck.isNotEmpty) {
      // Message already exists, skip insertion
      debugPrint('[DatabaseHelper] Duplicate message found, skipping');
      return -1;
    }
    
    final messageToInsert = MessageModel(
      sender: message.sender,
      message: encryptedMessage,
      app: message.app,
      timestamp: message.timestamp,
      isDeleted: message.isDeleted,
      isRead: message.isRead,
      senderName: message.senderName,
      isGroupChat: message.isGroupChat,
    );
    
    final result = await db.insert('messages', messageToInsert.toMap());
    debugPrint('[DatabaseHelper] Message inserted with ID: $result, isGroupChat: ${message.isGroupChat}, senderName: ${message.senderName}');
    
    // Verify insertion
    final count = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM messages'));
    debugPrint('[DatabaseHelper] Total messages in database: $count');
    
    return result;
  }

  Future<List<MessageModel>> getAllMessages() async {
    final db = await database;
    final result = await db.query('messages', orderBy: 'timestamp DESC');
    
    final messages = result.map((map) => MessageModel.fromMap(map)).toList();
    
    // Decrypt messages if encryption is enabled
    if (await _encryptionService.isEncryptionEnabled()) {
      for (var i = 0; i < messages.length; i++) {
        try {
          final decryptedMessage = await _encryptionService.decrypt(messages[i].message);
          messages[i] = MessageModel(
            id: messages[i].id,
            sender: messages[i].sender,
            message: decryptedMessage,
            app: messages[i].app,
            timestamp: messages[i].timestamp,
            isDeleted: messages[i].isDeleted,
            isRead: messages[i].isRead,
            senderName: messages[i].senderName,
            isGroupChat: messages[i].isGroupChat,
            avatarPath: messages[i].avatarPath,
          );
        } catch (e) {
          // If decryption fails, keep original
        }
      }
    }
    
    return messages;
  }

  Future<List<MessageModel>> getMessagesBySender(String sender) async {
    final db = await database;
    final result = await db.query(
      'messages',
      where: 'sender = ?',
      whereArgs: [sender],
      orderBy: 'timestamp DESC',
    );
    
    final messages = result.map((map) => MessageModel.fromMap(map)).toList();
    
    // Decrypt messages if encryption is enabled
    if (await _encryptionService.isEncryptionEnabled()) {
      for (var i = 0; i < messages.length; i++) {
        try {
          final decryptedMessage = await _encryptionService.decrypt(messages[i].message);
          messages[i] = MessageModel(
            id: messages[i].id,
            sender: messages[i].sender,
            message: decryptedMessage,
            app: messages[i].app,
            timestamp: messages[i].timestamp,
            isDeleted: messages[i].isDeleted,
            isRead: messages[i].isRead,
            senderName: messages[i].senderName,
            isGroupChat: messages[i].isGroupChat,
            avatarPath: messages[i].avatarPath,
          );
        } catch (e) {
          // If decryption fails, keep original
        }
      }
    }
    
    return messages;
  }

  Future<List<Map<String, dynamic>>> getConversations() async {
    final db = await database;
    
    // Get conversations with last message, unread count, group chat info, and avatar
    final result = await db.rawQuery('''
      SELECT 
        m.sender, 
        m.app, 
        m.timestamp as lastTimestamp,
        m.message as lastMessage,
        m.senderName as lastSenderName,
        m.isGroupChat,
        m.avatarPath,
        (SELECT COUNT(*) FROM messages m2 WHERE m2.sender = m.sender AND m2.app = m.app AND m2.isDeleted = 0) as messageCount,
        (SELECT COUNT(*) FROM messages m3 WHERE m3.sender = m.sender AND m3.app = m.app AND m3.isRead = 0 AND m3.isDeleted = 0) as unreadCount
      FROM messages m
      WHERE m.isDeleted = 0
      AND m.timestamp = (
        SELECT MAX(timestamp) FROM messages m4 
        WHERE m4.sender = m.sender AND m4.app = m.app AND m4.isDeleted = 0
      )
      GROUP BY m.sender, m.app
      ORDER BY lastTimestamp DESC
    ''');
    
    // Decrypt last message if encryption is enabled
    if (await _encryptionService.isEncryptionEnabled()) {
      final decryptedResults = <Map<String, dynamic>>[];
      for (var row in result) {
        final mutableRow = Map<String, dynamic>.from(row);
        try {
          final decryptedMessage = await _encryptionService.decrypt(row['lastMessage'] as String? ?? '');
          mutableRow['lastMessage'] = decryptedMessage;
        } catch (e) {
          // Keep original if decryption fails
        }
        decryptedResults.add(mutableRow);
      }
      return decryptedResults;
    }
    
    debugPrint('[DatabaseHelper] getConversations returning ${result.length} conversations');
    for (var conv in result) {
      debugPrint('[DatabaseHelper] Conversation: sender=${conv['sender']}, messageCount=${conv['messageCount']}, unreadCount=${conv['unreadCount']}');
    }
    
    return result;
  }

  Future<List<MessageModel>> searchMessages(String query) async {
    final db = await database;
    final isEncrypted = await _encryptionService.isEncryptionEnabled();
    
    // If encryption is enabled, we need to search in decrypted content
    // So we fetch all messages first, decrypt, then filter
    if (isEncrypted) {
      // Get all messages and decrypt them
      final allResult = await db.query(
        'messages',
        where: 'isDeleted = 0',
        orderBy: 'timestamp DESC',
      );
      
      final messages = allResult.map((map) => MessageModel.fromMap(map)).toList();
      final queryLower = query.toLowerCase();
      final filteredMessages = <MessageModel>[];
      
      for (var i = 0; i < messages.length; i++) {
        try {
          final decryptedMessage = await _encryptionService.decrypt(messages[i].message);
          final decryptedModel = MessageModel(
            id: messages[i].id,
            sender: messages[i].sender,
            message: decryptedMessage,
            app: messages[i].app,
            timestamp: messages[i].timestamp,
            isDeleted: messages[i].isDeleted,
            isRead: messages[i].isRead,
            senderName: messages[i].senderName,
            isGroupChat: messages[i].isGroupChat,
            avatarPath: messages[i].avatarPath,
          );
          
          // Filter by query on decrypted content
          if (decryptedModel.sender.toLowerCase().contains(queryLower) ||
              decryptedModel.message.toLowerCase().contains(queryLower)) {
            filteredMessages.add(decryptedModel);
          }
        } catch (e) {
          // If decryption fails, search on original values
          if (messages[i].sender.toLowerCase().contains(queryLower) ||
              messages[i].message.toLowerCase().contains(queryLower)) {
            filteredMessages.add(messages[i]);
          }
        }
      }
      
      return filteredMessages;
    } else {
      // Non-encrypted: use regular SQL search
      final result = await db.query(
        'messages',
        where: '(sender LIKE ? OR message LIKE ?) AND isDeleted = 0',
        whereArgs: ['%$query%', '%$query%'],
        orderBy: 'timestamp DESC',
      );
      
      return result.map((map) => MessageModel.fromMap(map)).toList();
    }
  }

  Future<int> markMessageAsDeleted(int id) async {
    final db = await database;
    return await db.update(
      'messages',
      {'isDeleted': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // Mark message as deleted by matching sender and message content
  Future<int> markMessageAsDeletedByContent(String sender, String message) async {
    final db = await database;
    return await db.update(
      'messages',
      {'isDeleted': 1},
      where: 'sender = ? AND message = ?',
      whereArgs: [sender, message],
    );
  }

  // Delete messages older than 15 days
  Future<int> deleteOldMessages() async {
    final db = await database;
    final fifteenDaysAgo = DateTime.now().subtract(const Duration(days: 15));
    
    return await db.delete(
      'messages',
      where: 'timestamp < ?',
      whereArgs: [fifteenDaysAgo.millisecondsSinceEpoch],
    );
  }

  // Mark all messages from a sender as read
  Future<int> markMessagesAsRead(String sender) async {
    final db = await database;
    return await db.update(
      'messages',
      {'isRead': 1},
      where: 'sender = ? AND isRead = 0',
      whereArgs: [sender],
    );
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
  }
}

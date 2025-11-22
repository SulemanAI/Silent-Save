import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
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
      version: 1,
      onCreate: _createDB,
    );
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sender TEXT NOT NULL,
        message TEXT NOT NULL,
        app TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        isDeleted INTEGER DEFAULT 0
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
    
    // Encrypt message if encryption is enabled
    final encryptedMessage = await _encryptionService.isEncryptionEnabled()
        ? await _encryptionService.encrypt(message.message)
        : message.message;
    
    final messageToInsert = MessageModel(
      sender: message.sender,
      message: encryptedMessage,
      app: message.app,
      timestamp: message.timestamp,
      isDeleted: message.isDeleted,
    );
    
    return await db.insert('messages', messageToInsert.toMap());
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
    final result = await db.rawQuery('''
      SELECT sender, app, MAX(timestamp) as lastTimestamp, COUNT(*) as messageCount
      FROM messages
      GROUP BY sender, app
      ORDER BY lastTimestamp DESC
    ''');
    
    return result;
  }

  Future<List<MessageModel>> searchMessages(String query) async {
    final db = await database;
    final result = await db.query(
      'messages',
      where: 'sender LIKE ? OR message LIKE ?',
      whereArgs: ['%$query%', '%$query%'],
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
          );
        } catch (e) {
          // If decryption fails, keep original
        }
      }
    }
    
    return messages;
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

  Future<void> close() async {
    final db = await database;
    await db.close();
  }
}

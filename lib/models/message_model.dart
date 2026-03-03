class MessageModel {
  final int? id;
  final String sender;  // Chat/Group name for grouping
  final String message;
  final String app;
  final DateTime timestamp;
  final bool? isDeleted; // Track if message was deleted/recalled
  final bool? isRead; // Track if message has been read
  final String? senderName; // Individual sender name (for group chats, shows who sent the message)
  final bool? isGroupChat; // Whether this message is from a group chat
  final String? avatarPath; // Path to sender's profile picture

  MessageModel({
    this.id,
    required this.sender,
    required this.message,
    required this.app,
    required this.timestamp,
    this.isDeleted = false,
    this.isRead = false,
    this.senderName,
    this.isGroupChat = false,
    this.avatarPath,
  });

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'id': id,
      'sender': sender,
      'message': message,
      'app': app,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'isDeleted': isDeleted == true ? 1 : 0,
      'isRead': isRead == true ? 1 : 0,
      'senderName': senderName ?? sender,
      'isGroupChat': isGroupChat == true ? 1 : 0,
    };
    // Only include avatarPath if it has a value, to avoid errors
    // when the column doesn't exist yet in older databases
    if (avatarPath != null) {
      map['avatarPath'] = avatarPath;
    }
    return map;
  }

  factory MessageModel.fromMap(Map<String, dynamic> map) {
    // Null-safe timestamp parsing with fallback to current time
    final timestampValue = map['timestamp'];
    final timestamp = timestampValue != null
        ? DateTime.fromMillisecondsSinceEpoch(timestampValue as int)
        : DateTime.now();
    
    return MessageModel(
      id: map['id'],
      sender: map['sender'] ?? 'Unknown',
      message: map['message'] ?? '',
      app: map['app'] ?? '',
      timestamp: timestamp,
      isDeleted: map['isDeleted'] == 1,
      isRead: map['isRead'] == 1,
      senderName: map['senderName'] ?? map['sender'] ?? 'Unknown',
      isGroupChat: map['isGroupChat'] == 1,
      avatarPath: map['avatarPath'],
    );
  }
}

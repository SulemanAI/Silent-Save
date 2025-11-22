class MessageModel {
  final int? id;
  final String sender;
  final String message;
  final String app;
  final DateTime timestamp;
  final bool? isDeleted; // Track if message was deleted/recalled

  MessageModel({
    this.id,
    required this.sender,
    required this.message,
    required this.app,
    required this.timestamp,
    this.isDeleted = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'sender': sender,
      'message': message,
      'app': app,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'isDeleted': isDeleted == true ? 1 : 0,
    };
  }

  factory MessageModel.fromMap(Map<String, dynamic> map) {
    return MessageModel(
      id: map['id'],
      sender: map['sender'],
      message: map['message'],
      app: map['app'],
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp']),
      isDeleted: map['isDeleted'] == 1,
    );
  }
}

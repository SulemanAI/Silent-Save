import 'package:flutter/material.dart';
import 'services/database_helper.dart';
import 'services/notification_service.dart';
import 'models/message_model.dart';

void main() {
  runApp(const TestApp());
}

class TestApp extends StatelessWidget {
  const TestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Notification Test',
      theme: ThemeData.dark(),
      home: const TestScreen(),
    );
  }
}

class TestScreen extends StatefulWidget {
  const TestScreen({super.key});

  @override
  State<TestScreen> createState() => _TestScreenState();
}

class _TestScreenState extends State<TestScreen> {
  String _log = '';
  List<Map<String, dynamic>> _conversations = [];
  List<MessageModel> _messages = [];

  void _addLog(String message) {
    setState(() {
      _log += '$message\n';
    });
    debugPrint('[TEST] $message');
  }

  Future<void> _testDatabaseInsert() async {
    _addLog('--- Testing Database Insert ---');
    
    try {
      final message = MessageModel(
        sender: 'Test Sender',
        message: 'Test message content ${DateTime.now()}',
        app: 'com.test.app',
        timestamp: DateTime.now(),
        isRead: false,
        senderName: 'Test Person',
        isGroupChat: false,
      );
      
      _addLog('Created MessageModel: sender="${message.sender}", text="${message.message}"');
      
      final result = await DatabaseHelper.instance.insertMessage(message);
      _addLog('Insert result: $result');
      
      if (result > 0) {
        _addLog('✅ Message inserted successfully with ID: $result');
      } else if (result == -1) {
        _addLog('⚠️ Message was duplicate');
      } else {
        _addLog('❌ Insert failed with result: $result');
      }
    } catch (e, stackTrace) {
      _addLog('❌ Error: $e');
      _addLog('Stack: $stackTrace');
    }
  }

  Future<void> _testGetConversations() async {
    _addLog('--- Testing Get Conversations ---');
    
    try {
      final conversations = await DatabaseHelper.instance.getConversations();
      _addLog('Found ${conversations.length} conversations');
      
      setState(() {
        _conversations = conversations;
      });
      
      for (var conv in conversations) {
        _addLog('  - ${conv['sender']}: ${conv['messageCount']} messages, ${conv['unreadCount']} unread');
      }
    } catch (e, stackTrace) {
      _addLog('❌ Error: $e');
      _addLog('Stack: $stackTrace');
    }
  }

  Future<void> _testGetAllMessages() async {
    _addLog('--- Testing Get All Messages ---');
    
    try {
      final messages = await DatabaseHelper.instance.getAllMessages();
      _addLog('Found ${messages.length} messages');
      
      setState(() {
        _messages = messages;
      });
      
      for (var msg in messages.take(10)) {
        _addLog('  - [${msg.sender}] ${msg.message.substring(0, msg.message.length > 30 ? 30 : msg.message.length)}...');
      }
    } catch (e, stackTrace) {
      _addLog('❌ Error: $e');
      _addLog('Stack: $stackTrace');
    }
  }

  Future<void> _testNotificationService() async {
    _addLog('--- Testing Notification Service ---');
    
    try {
      _addLog('Calling refreshNotifications...');
      await NotificationService.instance.refreshNotifications();
      _addLog('✅ refreshNotifications completed');
      _addLog('Total processed: ${NotificationService.instance.totalProcessed}');
    } catch (e, stackTrace) {
      _addLog('❌ Error: $e');
      _addLog('Stack: $stackTrace');
    }
  }

  Future<void> _runAllTests() async {
    setState(() {
      _log = '';
    });
    
    _addLog('=== Starting All Tests ===\n');
    
    await _testDatabaseInsert();
    _addLog('');
    
    await _testGetConversations();
    _addLog('');
    
    await _testGetAllMessages();
    _addLog('');
    
    await _testNotificationService();
    _addLog('');
    
    // Refresh conversations after notification service
    await _testGetConversations();
    
    _addLog('\n=== Tests Complete ===');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notification Test'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton(
                  onPressed: _runAllTests,
                  child: const Text('Run All Tests'),
                ),
                ElevatedButton(
                  onPressed: _testDatabaseInsert,
                  child: const Text('Test Insert'),
                ),
                ElevatedButton(
                  onPressed: _testGetConversations,
                  child: const Text('Get Conversations'),
                ),
                ElevatedButton(
                  onPressed: _testGetAllMessages,
                  child: const Text('Get Messages'),
                ),
                ElevatedButton(
                  onPressed: _testNotificationService,
                  child: const Text('Test Notifications'),
                ),
                ElevatedButton(
                  onPressed: () => setState(() => _log = ''),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  child: const Text('Clear Log'),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(8),
              child: SelectableText(
                _log.isEmpty ? 'Press a button to run tests...' : _log,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

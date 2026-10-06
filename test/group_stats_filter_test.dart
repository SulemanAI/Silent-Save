import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:silentsave/services/database_helper.dart';

void main() {
  databaseFactory = databaseFactoryFfi;
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    final db = await DatabaseHelper.instance.database;
    await db.delete('messages');
    await db.delete('media_attachments');
  });

  test('group stats and sender filtering work accurately', () async {
    final db = await DatabaseHelper.instance.database;
    final group = 'Family Group';
    final baseTime = DateTime(2026, 9, 24, 10, 0).millisecondsSinceEpoch;
    final nextDay = DateTime(2026, 9, 25, 12, 0).millisecondsSinceEpoch;

    // Insert messages for Alice
    await db.insert('messages', {
      'sender': group,
      'message': 'Hello from Alice 1',
      'app': 'com.whatsapp',
      'timestamp': baseTime,
      'isDeleted': 0,
      'isRead': 0,
      'senderName': 'Alice',
      'isGroupChat': 1,
      'avatarPath': null,
      'mediaPath': null,
      'isSaved': 0,
    });
    await db.insert('messages', {
      'sender': group,
      'message': 'Photo from Alice',
      'app': 'com.whatsapp',
      'timestamp': baseTime + 1000,
      'isDeleted': 0,
      'isRead': 0,
      'senderName': 'Alice',
      'isGroupChat': 1,
      'avatarPath': null,
      'mediaPath': '/path/to/alice_photo.jpg',
      'isSaved': 0,
    });
    await db.insert('messages', {
      'sender': group,
      'message': 'Alice message on next day',
      'app': 'com.whatsapp',
      'timestamp': nextDay,
      'isDeleted': 0,
      'isRead': 0,
      'senderName': 'Alice',
      'isGroupChat': 1,
      'avatarPath': null,
      'mediaPath': null,
      'isSaved': 0,
    });

    // Insert message for Bob
    await db.insert('messages', {
      'sender': group,
      'message': 'Hey from Bob',
      'app': 'com.whatsapp',
      'timestamp': baseTime + 5000,
      'isDeleted': 0,
      'isRead': 0,
      'senderName': 'Bob',
      'isGroupChat': 1,
      'avatarPath': null,
      'mediaPath': null,
      'isSaved': 0,
    });

    // 1. Test getGroupMembersWithStats
    final membersWithStats = await DatabaseHelper.instance.getGroupMembersWithStats(group);
    expect(membersWithStats.length, 2);
    expect(membersWithStats[0]['name'], 'Alice');
    expect(membersWithStats[0]['messageCount'], 3);
    expect(membersWithStats[0]['mediaCount'], 1);
    expect(membersWithStats[0]['lastTimestamp'], nextDay);

    expect(membersWithStats[1]['name'], 'Bob');
    expect(membersWithStats[1]['messageCount'], 1);
    expect(membersWithStats[1]['mediaCount'], 0);

    // 2. Test getChatStatsSummary with and without senderName
    final allStats = await DatabaseHelper.instance.getChatStatsSummary(group);
    expect(allStats['total'], 4);
    expect(allStats['media'], 1);

    final aliceStats = await DatabaseHelper.instance.getChatStatsSummary(group, senderName: 'Alice');
    expect(aliceStats['total'], 3);
    expect(aliceStats['media'], 1);

    final bobStats = await DatabaseHelper.instance.getChatStatsSummary(group, senderName: 'Bob');
    expect(bobStats['total'], 1);
    expect(bobStats['media'], 0);

    // 3. Test getDailyMessageCounts with senderName
    final aliceDaily = await DatabaseHelper.instance.getDailyMessageCounts(group, senderName: 'Alice');
    expect(aliceDaily.length, 2); // 2 distinct days
    final bobDaily = await DatabaseHelper.instance.getDailyMessageCounts(group, senderName: 'Bob');
    expect(bobDaily.length, 1); // 1 day

    // 4. Test getAllTextMessages with senderName
    final aliceTexts = await DatabaseHelper.instance.getAllTextMessages(group, senderName: 'Alice');
    expect(aliceTexts.length, 2); // 2 text messages (1 was photo)
    final bobTexts = await DatabaseHelper.instance.getAllTextMessages(group, senderName: 'Bob');
    expect(bobTexts.length, 1);

    // 5. Test getMediaMessagesBySender with senderName
    final aliceMedia = await DatabaseHelper.instance.getMediaMessagesBySender(group, senderName: 'Alice');
    expect(aliceMedia.length, 1);
    expect(aliceMedia.first.mediaPath, '/path/to/alice_photo.jpg');

    final bobMedia = await DatabaseHelper.instance.getMediaMessagesBySender(group, senderName: 'Bob');
    expect(bobMedia.length, 0);
  });
}

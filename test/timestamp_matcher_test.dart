import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:silentsave/services/database_helper.dart';
import 'package:silentsave/utils/timestamp_matcher.dart';

void main() {
  databaseFactory = databaseFactoryFfi;
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    final db = await DatabaseHelper.instance.database;
    await db.delete('messages');
    await db.delete('media_attachments');
  });

  test('matches a unique no-sender message candidate when it is the only valid media match', () async {
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.insert('messages', {
      'sender': 'alice',
      'message': 'Photo',
      'app': 'com.whatsapp',
      'timestamp': now,
      'isDeleted': 0,
      'isRead': 0,
      'senderName': 'Alice',
      'isGroupChat': 0,
      'avatarPath': null,
      'mediaPath': null,
      'isSaved': 0,
    });

    final result = await TimestampMatcher.matchMediaToNotification(
      {
        'fileTimestampMs': now,
        'mediaType': 'image',
        'displayName': 'IMG_1234.jpg',
      },
      60 * 1000,
    );

    expect(result.isMatched, isTrue);
    expect(result.matchedMessage, isNotNull);
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('each bubble engine reads and forwards its own intent room', () {
    final bubble = File(
      'android/app/src/main/kotlin/chat/fluffy/fluffychat/BubbleActivity.kt',
    ).readAsStringSync();
    final main = File(
      'android/app/src/main/kotlin/chat/fluffy/fluffychat/MainActivity.kt',
    ).readAsStringSync();
    expect(bubble, contains('var roomId: String?'));
    expect(bubble, contains('roomId = intent?.getStringExtra(EXTRA_ROOM)'));
    expect(bubble, contains('"roomId" to room'));
    expect(main, contains('bubbleActivity?.roomId'));
    expect(main, contains('bubbleActivity?.payload'));
    expect(bubble, isNot(contains('MainActivity.pendingBubbleRoomId')));
    expect(main, isNot(contains('var pendingBubbleRoomId')));
    expect(bubble, contains('FlutterEngine(context.applicationContext)'));
  });
}

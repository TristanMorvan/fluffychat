// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// ignore_for_file: unused_import

import 'dart:io';

import 'package:fluffychat/pages/chat/events/message.dart';
import 'package:fluffychat/pages/chat_details/chat_details_view.dart';
import 'package:fluffychat/pages/chat_list/chat_list_item.dart';
import 'package:fluffychat/utils/push_helper.dart';
import 'package:fluffychat/widgets/member_actions_popup_menu_button.dart';
import 'package:flutter_test/flutter_test.dart';

// Compile the actual presentation and push paths, not only the local store.

void main() {
  test('person avatar entry points carry explicit user identity', () {
    for (final file in [
      'widgets/member_actions_popup_menu_button.dart',
      'widgets/adaptive_dialogs/user_dialog.dart',
      'pages/chat_list/chat_list_item.dart',
      'pages/chat/chat_app_bar_title.dart',
      'pages/chat/chat_event_list.dart',
      'pages/chat/events/message.dart',
      'pages/chat_details/chat_details_view.dart',
      'pages/chat_details/participant_list_item.dart',
      'pages/new_private_chat/new_private_chat_view.dart',
    ]) {
      expect(
        File('lib/$file').readAsStringSync(),
        contains('userId:'),
        reason: file,
      );
    }
  });
  test('room images gate private identity to direct chats, never groups', () {
    for (final file in [
      'pages/chat_list/chat_list_item.dart',
      'pages/chat/chat_app_bar_title.dart',
      'pages/chat/chat_event_list.dart',
      'pages/chat_details/chat_details_view.dart',
    ]) {
      expect(
        File('lib/$file')
            .readAsStringSync()
            .replaceAll(RegExp(r'\s+'), ' ')
            .contains('room.isDirectChat ? room.directChatMatrixID : null'),
        isTrue,
        reason: file,
      );
    }
  });
  test('push path resolves sender and direct peer identities', () {
    final push = File('lib/utils/push_helper.dart').readAsStringSync();
    expect(push, contains('userId: event.senderId'));
    expect(
      push,
      contains(
        'userId: event.room.isDirectChat ? event.room.directChatMatrixID : null',
      ),
    );
  });
  test(
    'Android manual bubble and refresh channel preserve private avatar bytes',
    () {
      final activity = File(
        'android/app/src/main/kotlin/chat/fluffy/fluffychat/MainActivity.kt',
      ).readAsStringSync();
      expect(
        'call.argument<ByteArray>("avatar")'.allMatches(activity).length,
        greaterThanOrEqualTo(2),
      );
      expect(activity.contains('refreshConversationAvatar'), isTrue);
      final helper = File(
        'android/app/src/main/kotlin/chat/fluffy/fluffychat/BubbleNotificationHelper.kt',
      ).readAsStringSync();
      expect(helper.contains('fun refreshConversationAvatar('), isTrue);
      expect(
        activity,
        contains('BubbleNotificationHelper.refreshContactSenderAvatar('),
      );
      final senderRefresh = helper
          .split('fun refreshContactSenderAvatar(')
          .last
          .split('fun refreshConversationAvatar(')
          .first;
      expect(senderRefresh, contains('notification.group != groupKey'));
      expect(senderRefresh, contains('person == null || person.key != userId'));
      expect(senderRefresh, contains('style.messages.forEach'));
      expect(senderRefresh, contains('style.historicMessages.forEach'));
      expect(senderRefresh, contains('copy.extras.putAll(message.extras)'));
      expect(
        senderRefresh,
        contains('manager.notify(item.tag, item.id, builder.build())'),
      );
      for (final forbidden in [
        'ensureBubbleShortcut(',
        'showBubble(',
        '.setLargeIcon(',
        '.setShortcutId(',
        '.setBubbleMetadata(',
        '.addMessage(text',
      ]) {
        expect(senderRefresh, isNot(contains(forbidden)));
      }
      expect(
        helper.contains('putExtra(BubbleActivity.EXTRA_ROOM, roomId)'),
        isTrue,
        reason:
            'An account-scoped shortcut ID must never become a Matrix room ID',
      );
      expect(
        helper.contains('putExtra(BubbleActivity.EXTRA_SHORTCUT, shortcutId)'),
        isTrue,
      );
      expect(
        File('lib/widgets/fluffy_chat_app.dart').readAsStringSync().contains(
          'conversationBubbleLocation(roomId, payload)',
        ),
        isTrue,
      );
    },
  );

  test(
    'group avatar refresh resets stale Android views without cancelling bubbles',
    () {
      final helper = File(
        'android/app/src/main/kotlin/chat/fluffy/fluffychat/BubbleNotificationHelper.kt',
      ).readAsStringSync();
      final refresh = helper
          .split('fun refreshContactSenderAvatar(')
          .last
          .split('fun refreshConversationAvatar(')
          .first;
      expect(
        refresh,
        contains(
          'if (style.isGroupConversation && (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || notification.bubbleMetadata == null))',
        ),
      );
      expect(
        refresh,
        contains('setGroupAlertBehavior(Notification.GROUP_ALERT_SUMMARY)'),
      );
      expect(refresh, contains('manager.cancel(item.tag, item.id)'));
      expect(
        refresh.indexOf('manager.cancel(item.tag, item.id)'),
        lessThan(
          refresh.indexOf('manager.notify(item.tag, item.id, builder.build())'),
        ),
      );
    },
  );

  test(
    'private avatar code has no Matrix upload, profile, room or account-data writes',
    () {
      for (final file
          in Directory('lib')
              .listSync(recursive: true)
              .whereType<File>()
              .where(
                (f) => f.path.contains('private_') && f.path.endsWith('.dart'),
              )) {
        final source = file.readAsStringSync();
        for (final forbidden in [
          'setAvatar(',
          'setAccountData(',
          'setRoomState(',
          'uploadContent(',
          'sendEvent(',
        ]) {
          expect(source, isNot(contains(forbidden)), reason: file.path);
        }
      }
    },
  );

  test(
    "bubble mode owns conversation shortcuts, plugin push cannot uncategorize",
    () {
      final push = File("lib/utils/push_helper.dart")
          .readAsStringSync()
          .replaceAll(RegExp(r"\s+"), " ");
      // flutter_shortcuts_new never sets the conversation category: pushing
      // it over the native shortcut id removes the conversation from the
      // bubble picker. It must not run while bubbles are enabled.
      expect(
        push,
        contains(
          "messagingStyleInformation == null && !AppSettings.androidBubbles.value",
        ),
      );
    },
  );

  test("native cleanup removes legacy room-id conversation shortcuts", () {
    final helper = File(
      "android/app/src/main/kotlin/chat/fluffy/fluffychat/"
      "BubbleNotificationHelper.kt",
    ).readAsStringSync();
    expect(helper, contains("fun cleanupLegacyShortcuts"));
    expect(helper, contains("removeLongLivedShortcuts"));
    final main = File(
      "android/app/src/main/kotlin/chat/fluffy/fluffychat/MainActivity.kt",
    ).readAsStringSync();
    expect(main, contains("cleanupLegacyShortcuts"));
  });
}

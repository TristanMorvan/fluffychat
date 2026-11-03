// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/push_helper.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluffychat/utils/conversation_bubble.dart';
import 'package:fluffychat/utils/notification_avatar_extension.dart';
import 'package:fluffychat/utils/private_avatar_storage.dart';
import 'package:fluffychat/utils/private_contact_avatar.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:matrix/matrix.dart';

class _UnusedDatabase implements DatabaseApi {
  final Completer<void>? fileStarted;
  final Completer<Uint8List?>? fileResult;
  _UnusedDatabase({this.fileStarted, this.fileResult});
  @override
  Future<Uint8List?> getFile(Uri uri) async {
    if (fileStarted != null && !fileStarted!.isCompleted)
      fileStarted!.complete();
    if (fileResult != null) return fileResult!.future;
    return Uint8List.fromList(uri.path.contains('contact') ? [7] : [9]);
  }

  @override
  Future<CachedProfileInformation?> getUserProfile(String userId) async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('No Matrix storage access expected');
}

class _DelayedStore extends PrivateContactAvatarStore {
  final started = Completer<void>();
  final result = Completer<Uint8List?>();
  _DelayedStore() : super(storage: PrivateAvatarStorage());
  @override
  Future<Uint8List?> read(PrivateAvatarAccount account, String contact) {
    if (!started.isCompleted) started.complete();
    return result.future;
  }
}

class _Client extends Client {
  final List<Room> testRooms = [];
  @override
  List<Room> get rooms => testRooms;
  String? accountId;
  String server;
  Event? pushEvent;
  @override
  Future<Event?> getEventByPushNotification(
    PushNotification notification, {
    bool storeInDatabase = true,
    Duration timeoutForServerRequests = const Duration(seconds: 8),
    bool returnNullIfSeen = true,
  }) async => pushEvent;
  @override
  PushruleEvaluator get pushruleEvaluator => _NotifyEvaluator();
  _Client({
    this.accountId = '@me:example.org',
    this.server = 'https://example.org',
    DatabaseApi? database,
  }) : super(
         'private-avatar-notification',
         database: database ?? _UnusedDatabase(),
       );
  @override
  String? get userID => accountId;
  @override
  Uri? get homeserver => Uri.parse(server);
}

class _NotifyEvaluator implements PushruleEvaluator {
  @override
  EvaluatedPushRuleAction match(Event event) =>
      EvaluatedPushRuleAction()..notify = true;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected evaluator call');
}

class _Notifications implements FlutterLocalNotificationsPlugin {
  final shown = <NotificationDetails?>[];
  @override
  T? resolvePlatformSpecificImplementation<
    T extends FlutterLocalNotificationsPlatform
  >() => null;
  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async {
    shown.add(notificationDetails);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected notification call');
}

class _Room implements Room {
  @override
  final Client client;
  @override
  final bool isDirectChat;
  @override
  final String? directChatMatrixID;
  final bool publicAvatar;
  final bool roomAvatar;
  _Room(
    this.client,
    this.isDirectChat,
    this.directChatMatrixID, {
    this.publicAvatar = false,
    this.roomAvatar = true,
  });
  @override
  Uri? get avatar =>
      publicAvatar && roomAvatar ? Uri.parse('mxc://example.org/room') : null;
  @override
  User unsafeGetUserFromMemoryOrFallback(String id) => User(
    id,
    room: this,
    avatarUrl: publicAvatar ? 'mxc://example.org/contact' : null,
  );
  @override
  String get id => '!room:example.org';
  @override
  String getLocalizedDisplayname([dynamic i18n]) => 'Friend';
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('No room writes expected');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('avatar read discards bytes after account switch during IO', () async {
    final client = _Client();
    final store = _DelayedStore();
    final pending = client.tryDownloadNotificationAvatar(
      null,
      userId: '@friend:example.org',
      privateAvatarStore: store,
    );
    await store.started.future;
    client.accountId = '@other:example.org';
    store.result.complete(Uint8List.fromList([42]));
    expect(await pending, isNull);
    store.dispose();
  });
  for (final change in ['user', 'homeserver', 'logout', 'none']) {
    testWidgets('manual bubble $change switch during avatar IO', (
      tester,
    ) async {
      late Completer<void> started;
      late Completer<Uint8List?> result;
      await tester.runAsync(() async {
        started = Completer<void>();
        result = Completer<Uint8List?>();
      });
      final client = _Client(
        database: _UnusedDatabase(fileStarted: started, fileResult: result),
      );
      final room = _Room(
        client,
        true,
        '@friend:example.org',
        publicAvatar: true,
      );
      final calls = <MethodCall>[];
      const channel = MethodChannel('chat.fluffy/bubbles');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (value) {
                context = value;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final pending = openConversationBubble(context, room);
        await started.future;
        if (change == 'logout') client.accountId = null;
        if (change == 'user') client.accountId = '@other:example.org';
        if (change == 'homeserver')
          client.server = 'https://elsewhere.example.org';
        result.complete(Uint8List.fromList([42]));
        await pending;
      });
      expect(
        calls.map((c) => c.method),
        change == 'none' ? ['openBubble'] : isEmpty,
      );
      if (change == 'none') expect(calls.single.arguments['avatar'], [42]);
    });
  }

  for (final change in ['user', 'homeserver', 'logout', 'none']) {
    test('normal push $change switch during avatar IO', () async {
      SharedPreferences.setMockInitialValues({});
      final started = Completer<void>();
      final result = Completer<Uint8List?>();
      final client = _Client(
        database: _UnusedDatabase(fileStarted: started, fileResult: result),
      );
      final room = _Room(
        client,
        true,
        '@friend:example.org',
        publicAvatar: true,
      );
      client.pushEvent = Event(
        content: {},
        type: EventTypes.Encrypted,
        eventId: r'$event',
        senderId: '@friend:example.org',
        originServerTs: DateTime.utc(2026),
        room: room,
      );
      final notifications = _Notifications();
      final pending = pushHelper(
        PushNotification(roomId: room.id, eventId: r'$event'),
        clients: [client],
        l10n: await L10n.delegate.load(const Locale('en')),
        flutterLocalNotificationsPlugin: notifications,
      );
      await started.future.timeout(const Duration(seconds: 10));
      if (change == 'logout') client.accountId = null;
      if (change == 'user') client.accountId = '@other:example.org';
      if (change == 'homeserver')
        client.server = 'https://elsewhere.example.org';
      result.complete(Uint8List.fromList([42]));
      await pending;
      expect(notifications.shown, change == 'none' ? hasLength(1) : isEmpty);
      if (change == 'none') {
        final style =
            notifications.shown.single!.android!.styleInformation
                as MessagingStyleInformation;
        expect(style.person.icon, isA<ByteArrayAndroidIcon>());
      }
    });
  }

  test(
    'manual DM and reset use public contact before different room image',
    () async {
      final client = _Client();
      final room = _Room(
        client,
        true,
        '@friend:example.org',
        publicAvatar: true,
      );
      expect(await downloadConversationBubbleAvatar(room), [7]);
      expect(
        await downloadConversationBubbleAvatar(
          _Room(
            client,
            true,
            '@friend:example.org',
            publicAvatar: true,
            roomAvatar: false,
          ),
        ),
        [7],
      );
      final directory = await Directory.systemTemp.createTemp(
        'private-avatar-reset-',
      );
      final store = PrivateContactAvatarStore(
        storage: PrivateAvatarStorage(directory.path),
      );
      final account = PrivateAvatarAccount.fromClient(client)!;
      await store.set(
        account,
        '@friend:example.org',
        Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2))),
      );
      expect(
        await downloadConversationBubbleAvatar(room, privateAvatarStore: store),
        isNot([7]),
      );
      await store.reset(account, '@friend:example.org');
      expect(
        await downloadConversationBubbleAvatar(room, privateAvatarStore: store),
        [7],
      );
      store.dispose();
      await directory.delete(recursive: true);
      expect(
        await downloadConversationBubbleAvatar(
          _Room(client, false, null, publicAvatar: true),
        ),
        [9],
      );
    },
  );
  test(
    'group-only account refreshes senders once, never a room shortcut',
    () async {
      final client = _Client();
      client.testRooms.add(_Room(client, false, null, publicAvatar: true));
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('chat.fluffy/bubbles'),
            (call) async {
              calls.add(call);
              return null;
            },
          );
      await refreshPrivateContactAvatarSurfaces(client, '@friend:example.org');
      expect(calls.length, 1);
      expect(calls.single.method, 'refreshContactSenderAvatar');
      expect(calls.single.arguments['avatar'], [7]);
      expect(calls.single.arguments['groupKey'], client.clientName);
      expect(calls.single.arguments['userId'], '@friend:example.org');
      expect(calls.single.arguments.containsKey('shortcutId'), isFalse);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('chat.fluffy/bubbles'),
            null,
          );
    },
  );
  test('Android conversation caches and bubble routes are account scoped', () {
    const roomId = '!shared:example.org';
    final client = _Client();
    final first = conversationShortcutId(client, roomId);
    expect(first, conversationShortcutId(_Client(), roomId));
    expect(
      first,
      isNot(
        conversationShortcutId(
          _Client(accountId: '@other:example.org'),
          roomId,
        ),
      ),
    );
    expect(
      first,
      isNot(
        conversationShortcutId(
          _Client(server: 'https://elsewhere.example.org'),
          roomId,
        ),
      ),
    );
    final route = Uri.parse(
      conversationBubbleLocation(roomId, 'account two|$roomId|'),
    );
    expect(route.queryParameters['client'], 'account two');
    expect(route.pathSegments.last, roomId);
  });
  test(
    'notification and bubble download use the same durable person override before MXC',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'private-avatar-notification-',
      );
      final store = PrivateContactAvatarStore(
        storage: PrivateAvatarStorage(directory.path),
      );
      final client = _Client();
      const account = PrivateAvatarAccount(
        '@me:example.org',
        'https://example.org',
      );
      const contact = '@friend:example.org';
      await store.set(
        account,
        contact,
        Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2))),
      );
      final bytes = await client.tryDownloadNotificationAvatar(
        null,
        userId: contact,
        privateAvatarStore: store,
      );
      expect(
        bytes,
        isNotNull,
        reason:
            'Notification avatars must prefer the private photo even without a public MXC',
      );
      expect(img.decodePng(bytes!)?.width, 2);
      expect(
        await downloadConversationBubbleAvatar(
          _Room(client, true, contact),
          privateAvatarStore: store,
        ),
        isNotNull,
      );
      expect(
        await downloadConversationBubbleAvatar(
          _Room(client, false, contact),
          privateAvatarStore: store,
        ),
        isNull,
      );
      expect(
        await client.tryDownloadNotificationAvatar(
          null,
          privateAvatarStore: store,
        ),
        isNull,
        reason: 'Group room photos must not use contact overrides',
      );
      expect(
        await client.tryDownloadNotificationAvatar(
          null,
          userId: '@same-avatar:example.org',
          privateAvatarStore: store,
        ),
        isNull,
      );
      client.testRooms.addAll([
        _Room(client, true, contact),
        _Room(client, false, contact),
        _Room(client, true, '@other:example.org'),
      ]);
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('chat.fluffy/bubbles'),
            (call) async {
              calls.add(call);
              return null;
            },
          );
      await refreshPrivateContactAvatarSurfaces(
        client,
        contact,
        privateAvatarStore: store,
      );
      expect(calls.map((c) => c.method), [
        'refreshContactSenderAvatar',
        'refreshConversationAvatar',
      ]);
      expect(calls.first.arguments['userId'], contact);
      expect(calls.first.arguments['avatar'], isNotNull);
      expect(calls.first.arguments['groupKey'], client.clientName);
      expect(
        calls.first.arguments.containsKey('roomId'),
        isFalse,
        reason:
            'Account/user refresh must include group notifications without creating group bubbles',
      );
      expect(calls.last.arguments['avatar'], isNotNull);
      expect(calls.last.arguments['groupKey'], client.clientName);
      await store.reset(account, contact);
      calls.clear();
      await refreshPrivateContactAvatarSurfaces(
        client,
        contact,
        privateAvatarStore: store,
      );
      expect(calls.map((c) => c.arguments['avatar']), everyElement(isNull));
      calls.clear();
      final pendingRefresh = refreshPrivateContactAvatarSurfaces(
        client,
        contact,
        privateAvatarStore: store,
      );
      client.accountId = '@other:example.org';
      await pendingRefresh;
      expect(
        calls,
        isEmpty,
        reason: 'An account switch during image IO must cancel native refresh',
      );
      client.accountId = account.userId;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('chat.fluffy/bubbles'),
            null,
          );
      expect(
        await client.tryDownloadNotificationAvatar(
          null,
          userId: contact,
          privateAvatarStore: store,
        ),
        isNull,
      );
      store.dispose();
      await directory.delete(recursive: true);
    },
  );
}

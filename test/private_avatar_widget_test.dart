// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/private_avatar_storage.dart';
import 'package:fluffychat/utils/private_contact_avatar.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/mxc_image.dart';
import 'package:fluffychat/widgets/mxc_image_viewer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Avatar must not touch Matrix storage');
}

class _AvatarClient extends Client {
  String accountId;
  final Uri server;
  _AvatarClient(this.accountId, String server)
    : server = Uri.parse(server),
      super('private-avatar-test', database: _UnusedDatabase());
  @override
  String? get userID => accountId;
  @override
  Uri? get homeserver => server;
  @override
  bool isLogged() => false;
}

void main() {
  testWidgets(
    'Avatar resolves explicit person identity, refreshes and restores original',
    (tester) async {
      late Directory directory;
      late PrivateContactAvatarStore store;
      final client = _AvatarClient('@me:example.org', 'https://example.org');
      const account = PrivateAvatarAccount(
        '@me:example.org',
        'https://example.org',
      );
      const contact = '@friend:example.org';
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp(
          'private-avatar-widget-',
        );
        store = PrivateContactAvatarStore(
          storage: PrivateAvatarStorage(directory.path),
        );
      });
      Future<void> pumpPhoto(String? userId, {Client? asClient}) async {
        await tester.runAsync(
          () => tester.pumpWidget(
            MaterialApp(
              home: Avatar(
                client: asClient ?? client,
                userId: userId,
                name: 'Friend',
                privateAvatarStore: store,
              ),
            ),
          ),
        );
        for (var i = 0; i < 5; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump();
        }
      }

      await pumpPhoto(contact);
      expect(find.byType(MxcImage), findsOneWidget);
      await tester.runAsync(
        () => store.set(
          account,
          contact,
          Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2))),
        ),
      );
      await pumpPhoto(contact);
      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(MxcImage), findsNothing);
      client.accountId =
          '@other:example.org'; // Re-login can reuse a Client instance.
      await pumpPhoto(contact);
      expect(find.byType(MxcImage), findsOneWidget);
      client.accountId = account.userId;
      await pumpPhoto(contact);
      expect(find.byType(Image), findsOneWidget);
      await pumpPhoto('@same-mxc-other-person:example.org');
      expect(find.byType(MxcImage), findsOneWidget);
      await pumpPhoto(
        null,
      ); // Group room avatar never gets a person's override.
      expect(find.byType(MxcImage), findsOneWidget);
      await pumpPhoto(
        contact,
        asClient: _AvatarClient('@other:example.org', 'https://example.org'),
      );
      expect(find.byType(MxcImage), findsOneWidget);
      await pumpPhoto(contact);
      expect(find.byType(Image), findsOneWidget);
      await tester.runAsync(() => store.reset(account, contact));
      await pumpPhoto(contact);
      expect(find.byType(MxcImage), findsOneWidget);
      await tester.runAsync(
        () => store.set(
          account,
          contact,
          Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2))),
        ),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => tester.pumpWidget(
          MaterialApp(
            key: const ValueKey('viewer'),
            locale: const Locale('en'),
            localizationsDelegates: L10n.localizationsDelegates,
            home: MxcImageViewer(
              Uri.parse('mxc://example.org/public'),
              client: client,
              userId: contact,
              privateAvatarStore: store,
            ),
          ),
        ),
      );
      for (var i = 0; i < 30 && find.byType(Image).evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      expect(
        find.byType(Image),
        findsOneWidget,
        reason:
            'Opening the contact photo must not reveal the unrelated original avatar',
      );
      expect(find.byType(MxcImage), findsNothing);
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await tester.runAsync(() => directory.delete(recursive: true));
    },
  );
}

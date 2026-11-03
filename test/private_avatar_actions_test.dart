// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/private_avatar_storage.dart';
import 'package:fluffychat/utils/private_contact_avatar.dart';
import 'package:fluffychat/widgets/private_contact_avatar_actions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Private selection must not use Matrix writes');
}

class _Client extends Client {
  _Client() : super('private-avatar-actions', database: _UnusedDatabase());
  @override
  String? get userID => '@me:example.org';
  @override
  Uri? get homeserver => Uri.parse('https://example.org');
}

void main() {
  testWidgets('unsupported iOS hides private avatar controls', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('fr'),
        localizationsDelegates: [
          ...L10n.localizationsDelegates,
          ...GlobalMaterialLocalizations.delegates,
          ...GlobalCupertinoLocalizations.delegates,
        ],
        supportedLocales: L10n.supportedLocales,
        home: Scaffold(
          body: PrivateContactAvatarActions(
            client: _Client(),
            userId: '@friend:example.org',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(Column), findsNothing);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets(
    'French profile actions choose, cancel, reject invalid and restore locally',
    (tester) async {
      late Directory directory;
      late PrivateContactAvatarStore store;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp(
          'private-avatar-actions-',
        );
        store = PrivateContactAvatarStore(
          storage: PrivateAvatarStorage(directory.path),
        );
      });
      const account = PrivateAvatarAccount(
        '@me:example.org',
        'https://example.org',
      );
      const contact = '@friend:example.org';
      XFile? selection = XFile.fromData(
        Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2))),
        name: 'photo.png',
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('fr'),
          localizationsDelegates: [
            ...L10n.localizationsDelegates,
            ...GlobalMaterialLocalizations.delegates,
            ...GlobalCupertinoLocalizations.delegates,
          ],
          supportedLocales: L10n.supportedLocales,
          home: Scaffold(
            body: PrivateContactAvatarActions(
              client: _Client(),
              userId: contact,
              store: store,
              pickImage: () async => selection,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Visible uniquement pour ce compte sur cet appareil. Cette photo ne sera jamais envoyée.',
        ),
        findsOneWidget,
      );
      Future<void> tap(String text) async {
        await tester.runAsync(() => tester.tap(find.text(text)));
        for (var i = 0; i < 5; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump();
        }
      }

      await tap('Choisir une photo privée');
      final saved = await tester.runAsync(() => store.read(account, contact));
      expect(saved, isNotNull);
      selection = null;
      await tap('Choisir une photo privée');
      expect(await tester.runAsync(() => store.read(account, contact)), saved);
      selection = XFile.fromData(
        Uint8List.fromList([1, 2, 3]),
        name: 'fake.jpg',
      );
      await tap('Choisir une photo privée');
      expect(
        find.text(
          'Impossible d’utiliser cette photo. Choisissez une image valide de moins de 20 Mo.',
        ),
        findsOneWidget,
      );
      expect(await tester.runAsync(() => store.read(account, contact)), saved);
      await tap('Rétablir la photo d’origine');
      expect(await tester.runAsync(() => store.read(account, contact)), isNull);
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await tester.runAsync(() => directory.delete(recursive: true));
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );
}

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
  String? accountId = '@me:example.org';
  @override
  String? get userID => accountId;
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
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
      }

      await tap('Choisir une photo privée');
      expect(find.text('Recadrer la photo'), findsOneWidget);
      expect(await tester.runAsync(() => store.read(account, contact)), isNull);
      await tap('Utiliser cette photo');
      final saved = await tester.runAsync(() => store.read(account, contact));
      expect(saved, isNotNull);
      expect(img.decodePng(saved!)!.width, 256);
      await tap('Choisir une photo privée');
      expect(find.text('Recadrer la photo'), findsOneWidget);
      await tap('Annuler');
      expect(await tester.runAsync(() => store.read(account, contact)), saved);
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

  for (final switchAccount in [false, true]) {
    testWidgets(
      switchAccount
          ? 'account switch during crop cancels saving'
          : 'zoom and drag save the selected blue area instead of the red center',
      (tester) async {
        late Directory directory;
        late PrivateContactAvatarStore store;
        await tester.runAsync(() async {
          directory = await Directory.systemTemp.createTemp('avatar-crop-ui-');
          store = PrivateContactAvatarStore(
            storage: PrivateAvatarStorage(directory.path),
          );
        });
        final client = _Client();
        const account = PrivateAvatarAccount(
          '@me:example.org',
          'https://example.org',
        );
        const contact = '@friend:example.org';
        final photo = img.Image(width: 800, height: 400);
        for (var y = 0; y < photo.height; y++) {
          for (var x = 0; x < photo.width; x++) {
            photo.setPixelRgb(x, y, x < 500 ? 255 : 0, 0, x < 500 ? 0 : 255);
          }
        }
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
                client: client,
                userId: contact,
                store: store,
                pickImage: () async => XFile.fromData(
                  Uint8List.fromList(img.encodePng(photo)),
                  name: 'color-test.png',
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        Future<void> tapAndWait(String text) async {
          await tester.runAsync(() => tester.tap(find.text(text)));
          for (var i = 0; i < 6; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 50)),
            );
            await tester.pump(const Duration(milliseconds: 100));
          }
          await tester.pumpAndSettle();
        }

        await tapAndWait('Choisir une photo privée');
        expect(find.text('Recadrer la photo'), findsOneWidget);
        tester.widget<Slider>(find.byType(Slider)).onChanged!(2);
        await tester.pump();
        await tester.drag(
          find.byKey(const ValueKey('private-avatar-crop-viewport')),
          const Offset(-600, 0),
        );
        await tester.pump();
        if (switchAccount) client.accountId = '@other:example.org';
        await tapAndWait('Utiliser cette photo');
        final saved = await tester.runAsync(() => store.read(account, contact));
        if (switchAccount) {
          expect(saved, isNull);
        } else {
          final pixel = img.decodePng(saved!)!.getPixel(128, 128);
          expect(pixel.b, 255);
          expect(pixel.r, 0);
        }
        await tester.pumpWidget(const SizedBox());
        store.dispose();
        await tester.runAsync(() => directory.delete(recursive: true));
      },
      variant: const TargetPlatformVariant({TargetPlatform.android}),
    );
  }
}

// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fluffychat/utils/private_avatar_storage.dart';
import 'package:fluffychat/utils/private_avatar_storage_stub.dart' as web;
import 'package:fluffychat/utils/private_contact_avatar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PrivateContactAvatarStore store;
  const account = PrivateAvatarAccount(
    '@me:example.org',
    'https://example.org',
  );
  const contact = '@friend:example.org';
  final photo = Uint8List.fromList(
    img.encodePng(img.Image(width: 2, height: 2)),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('private-avatar-test-');
    store = PrivateContactAvatarStore(
      storage: PrivateAvatarStorage(directory.path),
    );
  });
  tearDown(() async {
    store.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'unsupported web storage preserves original avatars and forbids writes',
    () async {
      final storage = web.PrivateAvatarStorage();
      expect(storage.supported, isFalse);
      expect(await storage.read('anything'), isNull);
      await expectLater(
        storage.write('anything', photo),
        throwsUnsupportedError,
      );
      await storage.delete('anything');
    },
  );

  test(
    'persistent read rejects oversized sparse file before decoding',
    () async {
      await store.set(account, contact, photo);
      final file = directory.listSync().whereType<File>().single;
      final handle = await file.open(mode: FileMode.append);
      await handle.truncate(PrivateContactAvatarStore.maxFileBytes + 1);
      await handle.close();
      final key = file.uri.pathSegments.last.replaceAll('.png', '');
      final result = await store.storage.read(key);
      expect(
        result?.length,
        isNull,
        reason:
            'Storage must reject before allocating the full oversized image',
      );
      expect(await store.read(account, contact), isNull);
    },
  );

  test('oversized selection cannot replace an existing photo', () async {
    await store.set(account, contact, photo);
    await expectLater(
      store.set(
        account,
        contact,
        Uint8List(PrivateContactAvatarStore.maxFileBytes + 1),
      ),
      throwsFormatException,
    );
    expect(await store.read(account, contact), isNotNull);
  });

  test(
    'bubble reader is notified when another store replaces the file',
    () async {
      final changed = Completer<void>();
      store.addListener(() {
        if (!changed.isCompleted) changed.complete();
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final writer = PrivateContactAvatarStore(
        storage: PrivateAvatarStorage(directory.path),
      );
      await writer.set(account, contact, photo);
      await expectLater(
        changed.future.timeout(const Duration(seconds: 2)),
        completes,
      );
      expect(await store.read(account, contact), isNotNull);
      writer.dispose();
    },
  );

  test(
    'restore original removes only this account contact and persists',
    () async {
      const other = PrivateAvatarAccount(
        '@other:example.org',
        'https://example.org',
      );
      await store.set(account, contact, photo);
      await store.set(other, contact, photo);
      var changes = 0;
      store.addListener(() => changes++);
      await store.reset(account, contact);
      expect(changes, greaterThan(0));
      final restarted = PrivateContactAvatarStore(
        storage: PrivateAvatarStorage(directory.path),
      );
      expect(await restarted.read(account, contact), isNull);
      expect(await restarted.read(other, contact), isNotNull);
      await store.reset(account, contact); // Repeated reset is safe.
    },
  );

  test(
    'corrupt persisted photo falls back instead of returning unusable bytes',
    () async {
      await store.set(account, contact, photo);
      await directory.listSync().whereType<File>().single.writeAsBytes([
        1,
        2,
        3,
      ]);
      expect(await store.read(account, contact), isNull);
    },
  );

  test('large valid photo is downscaled and persisted as PNG', () async {
    await store.set(
      account,
      contact,
      Uint8List.fromList(img.encodeJpg(img.Image(width: 800, height: 400))),
    );
    final decoded = img.decodePng((await store.read(account, contact))!)!;
    expect(decoded.width, 256);
    expect(decoded.height, 128);
  });

  test('invalid image cannot replace an existing private photo', () async {
    await store.set(account, contact, photo);
    await expectLater(
      store.set(account, contact, Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
    expect(img.decodePng((await store.read(account, contact))!), isNotNull);
  });

  test('accounts and contacts sharing a Matrix avatar stay isolated', () async {
    await store.set(account, contact, photo);
    expect(
      await store.read(
        const PrivateAvatarAccount('@other:example.org', 'https://example.org'),
        contact,
      ),
      isNull,
    );
    expect(
      await store.read(
        const PrivateAvatarAccount(
          '@me:example.org',
          'https://other.example.org',
        ),
        contact,
      ),
      isNull,
    );
    expect(await store.read(account, '@alias:example.org'), isNull);
  });

  test('missing file falls back to the original avatar', () async {
    await store.set(account, contact, photo);
    for (final file in directory.listSync().whereType<File>()) {
      await file.delete();
    }
    expect(await store.read(account, contact), isNull);
  });

  test(
    'private photo survives a new store (including a bubble isolate reader)',
    () async {
      await store.set(account, contact, photo);
      final restarted = PrivateContactAvatarStore(
        storage: PrivateAvatarStorage(directory.path),
      );
      final bytes = await restarted.read(account, contact);
      expect(
        bytes,
        isNotNull,
        reason: 'The chosen photo must persist in app-private storage',
      );
      expect(img.decodePng(bytes!)?.width, 2);
    },
  );
}

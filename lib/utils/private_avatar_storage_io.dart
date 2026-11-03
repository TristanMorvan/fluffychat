// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class PrivateAvatarStorage {
  final String? directory;
  PrivateAvatarStorage([this.directory]);
  bool get supported => true;

  Future<File> _file(String key) async {
    final root =
        directory ??
        p.join(
          (await getApplicationSupportDirectory()).path,
          'private_contact_avatars',
        );
    return File(p.join(root, '$key.png'));
  }

  Future<Uint8List?> read(String key) async {
    try {
      final handle = await (await _file(key)).open();
      try {
        // Same 20 MiB cap as selection validation, checked before allocation.
        // Reading from this handle avoids a path replacement race; a bounded
        // read and second length check also reject concurrent file growth.
        const maxBytes = 20 * 1024 * 1024;
        final length = await handle.length();
        if (length <= 0 || length > maxBytes) return null;
        final bytes = await handle.read(length);
        if (bytes.length != length || await handle.length() != length)
          return null;
        return bytes;
      } finally {
        await handle.close();
      }
    } on FileSystemException {
      return null;
    }
  }

  Stream<void> watch() async* {
    try {
      final directory = (await _file('watch')).parent;
      await directory.create(recursive: true);
      yield* directory
          .watch()
          .where(
            (event) =>
                event.path.endsWith('.png') ||
                (event is FileSystemMoveEvent &&
                    (event.destination?.endsWith('.png') ?? false)),
          )
          .map((_) {});
    } on FileSystemException {
      // Unsupported/unavailable file watching must not break avatars.
    }
  }

  Future<void> delete(String key) async {
    final file = await _file(key);
    if (await file.exists()) await file.delete();
  }

  Future<void> write(String key, Uint8List bytes) async {
    final file = await _file(key);
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.${const Uuid().v4()}.tmp');
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}

// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

// Web deliberately keeps Matrix avatars: this feature is device-local storage.
class PrivateAvatarStorage {
  PrivateAvatarStorage([String? directory]);
  bool get supported => false;
  Future<Uint8List?> read(String key) async => null;
  Stream<void> watch() => const Stream.empty();
  Future<void> delete(String key) async {}
  Future<void> write(String key, Uint8List bytes) async =>
      throw UnsupportedError('Private avatars require local storage');
}

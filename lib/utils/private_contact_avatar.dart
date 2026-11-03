// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:uuid/uuid.dart';

import 'private_avatar_storage.dart';

class PrivateAvatarAccount {
  final String userId;
  final String homeserver;
  const PrivateAvatarAccount(this.userId, this.homeserver);

  static PrivateAvatarAccount? fromClient(Client? client) {
    final userId = client?.userID;
    final homeserver = client?.homeserver;
    if (userId == null || userId.isEmpty || homeserver == null) return null;
    return PrivateAvatarAccount(userId, homeserver.toString());
  }
}

// Snapshot identity, not Client object identity: a Client may be reused at login.
class PrivateAvatarOperation {
  final Client client;
  final String? _userId;
  final Uri? _homeserver;
  PrivateAvatarOperation(this.client)
    : _userId = client.userID,
      _homeserver = client.homeserver;

  bool get isCurrent =>
      client.userID == _userId && client.homeserver == _homeserver;
}

class PrivateContactAvatarStore extends ChangeNotifier {
  static final instance = PrivateContactAvatarStore(
    storage: PrivateAvatarStorage(),
  );
  final PrivateAvatarStorage storage;
  PrivateContactAvatarStore({required this.storage});
  StreamSubscription<void>? _watchSubscription;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _watchSubscription ??= storage.watch().listen((_) {
      if (hasListeners) notifyListeners();
    }, onError: (Object _) {});
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _watchSubscription?.cancel();
      _watchSubscription = null;
    }
  }

  @override
  void dispose() {
    _watchSubscription?.cancel();
    _watchSubscription = null;
    super.dispose();
  }

  String _key(PrivateAvatarAccount account, String contact) => const Uuid().v5(
    Namespace.url.value,
    jsonEncode([account.userId, account.homeserver, contact]),
  );
  static const maxFileBytes = 20 * 1024 * 1024;

  // Decode before persisting, bound resolution, flatten animation and strip
  // metadata. A picker extension/MIME type is never treated as validation.
  Future<Uint8List> _normalize(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > maxFileBytes)
      throw const FormatException('Invalid avatar image');
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width <= 0 ||
          descriptor.height <= 0 ||
          descriptor.width * descriptor.height > 40000000)
        throw const FormatException('Avatar image is too large');
      final scale =
          256 /
          (descriptor.width > descriptor.height
              ? descriptor.width
              : descriptor.height);
      codec = await descriptor.instantiateCodec(
        targetWidth: scale < 1
            ? (descriptor.width * scale).round().clamp(1, 256)
            : descriptor.width,
        targetHeight: scale < 1
            ? (descriptor.height * scale).round().clamp(1, 256)
            : descriptor.height,
      );
      image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw const FormatException('Invalid avatar image');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {
      throw const FormatException('Invalid avatar image');
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  Future<void> set(
    PrivateAvatarAccount account,
    String contact,
    Uint8List bytes,
  ) async {
    final normalized = await _normalize(bytes);
    await storage.write(_key(account, contact), normalized);
    notifyListeners();
  }

  Future<void> reset(PrivateAvatarAccount account, String contact) async {
    await storage.delete(_key(account, contact));
    notifyListeners();
  }

  // Always read disk, not preferences or an isolate-local cache. Notification
  // workers and the independent bubble engine must see changes immediately.
  Future<Uint8List?> read(PrivateAvatarAccount account, String contact) async {
    try {
      final bytes = await storage.read(_key(account, contact));
      return bytes == null ? null : await _normalize(bytes);
    } catch (_) {
      return null;
    }
  }
}

// Android caches icons by shortcut ID, so a shared room ID is not enough.
String conversationShortcutId(Client client, String roomId) {
  final account = PrivateAvatarAccount.fromClient(client);
  if (account == null) return roomId;
  return 'private-avatar-${const Uuid().v5(Namespace.url.value, jsonEncode([account.userId, account.homeserver, roomId]))}';
}

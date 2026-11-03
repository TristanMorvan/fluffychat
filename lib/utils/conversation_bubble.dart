// Fork: action commune aux détails de la pièce et au menu de conversation.
import 'dart:typed_data';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:fluffychat/utils/notification_avatar_extension.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/utils/private_contact_avatar.dart';
import 'package:fluffychat/utils/push_helper.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

bool canOpenConversationBubble(Room room) =>
    PlatformInfos.isAndroid &&
    AppSettings.androidBubbles.value &&
    room.isDirectChat;

Future<Uint8List?> downloadConversationBubbleAvatar(
  Room room, {
  PrivateContactAvatarStore? privateAvatarStore,
}) async {
  final operation = PrivateAvatarOperation(room.client);
  final userId = room.isDirectChat ? room.directChatMatrixID : null;
  final publicAvatar = userId == null
      ? room.avatar
      : await publicContactAvatar(room.client, userId, room: room) ??
            room.avatar;
  if (!operation.isCurrent) return null;
  final bytes = await room.client.tryDownloadNotificationAvatar(
    publicAvatar,
    userId: userId,
    privateAvatarStore: privateAvatarStore,
  );
  return operation.isCurrent ? bytes : null;
}

// Match push's sender-first fallback. A room image is not a person's profile.
// Read only cached membership/profile data; never mutate a Matrix profile.
Future<Uri?> publicContactAvatar(
  Client client,
  String userId, {
  Room? room,
}) async {
  final memberAvatar = room
      ?.unsafeGetUserFromMemoryOrFallback(userId)
      .avatarUrl;
  if (memberAvatar != null) return memberAvatar;
  for (final cachedRoom in client.rooms) {
    final avatar = cachedRoom
        .unsafeGetUserFromMemoryOrFallback(userId)
        .avatarUrl;
    if (avatar != null) return avatar;
  }
  try {
    return (await client.database.getUserProfile(userId))?.avatarUrl;
  } catch (_) {
    return null;
  }
}

Future<void> openConversationBubble(BuildContext context, Room room) async {
  final operation = PrivateAvatarOperation(room.client);
  final l10n = L10n.of(context);
  try {
    final avatar = await downloadConversationBubbleAvatar(room);
    if (!operation.isCurrent) return;
    await const MethodChannel(
      'chat.fluffy/bubbles',
    ).invokeMethod<void>('openBubble', {
      'roomId': room.id,
      'shortcutId': conversationShortcutId(room.client, room.id),
      'groupKey': room.client.clientName,
      'avatar': avatar,
      'title': room.getLocalizedDisplayname(MatrixLocals(l10n)),
      'payload': FluffyChatPushPayload(
        room.client.clientName,
        room.id,
        null,
      ).toString(),
    });
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.bubbleOpenedHint)));
  } on PlatformException catch (e) {
    if (!context.mounted) return;
    final notAllowed = e.code == 'bubbles_not_allowed';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 8),
        content: Text(
          notAllowed ? l10n.bubblesNotAllowedInSettings : l10n.openBubbleFailed,
        ),
        action: notAllowed
            ? SnackBarAction(
                label: l10n.openSystemSettings,
                onPressed: () => const MethodChannel(
                  'chat.fluffy/bubbles',
                ).invokeMethod<void>('openNotificationSettings'),
              )
            : null,
      ),
    );
  }
}

Future<void> refreshPrivateContactAvatarSurfaces(
  Client client,
  String userId, {
  PrivateContactAvatarStore? privateAvatarStore,
}) async {
  final account = PrivateAvatarAccount.fromClient(client);
  if (account == null) return;
  bool sameAccount() {
    final current = PrivateAvatarAccount.fromClient(client);
    return current?.userId == account.userId &&
        current?.homeserver == account.homeserver;
  }

  try {
    final publicAvatar = await publicContactAvatar(client, userId);
    final avatar = await client.tryDownloadNotificationAvatar(
      publicAvatar,
      userId: userId,
      privateAvatarStore: privateAvatarStore,
    );
    if (!sameAccount()) return;
    // One account/user update covers senders in ALL active rooms, including
    // groups. It must not change their room icons, shortcuts or bubble state.
    await const MethodChannel('chat.fluffy/bubbles').invokeMethod<void>(
      'refreshContactSenderAvatar',
      {'userId': userId, 'groupKey': client.clientName, 'avatar': avatar},
    );
  } catch (error, stack) {
    Logs().w('Unable to refresh local sender avatar', error, stack);
  }
  if (!sameAccount()) return;
  for (final room in client.rooms.where(
    (room) => room.isDirectChat && room.directChatMatrixID == userId,
  )) {
    try {
      final avatar = await downloadConversationBubbleAvatar(
        room,
        privateAvatarStore: privateAvatarStore,
      );
      final currentAccount = PrivateAvatarAccount.fromClient(client);
      if (currentAccount?.userId != account.userId ||
          currentAccount?.homeserver != account.homeserver)
        return;
      await const MethodChannel(
        'chat.fluffy/bubbles',
      ).invokeMethod<void>('refreshConversationAvatar', {
        'roomId': room.id,
        'shortcutId': conversationShortcutId(client, room.id),
        'payload': FluffyChatPushPayload(
          client.clientName,
          room.id,
          null,
        ).toString(),
        'title': room.getLocalizedDisplayname(),
        'userId': userId,
        'groupKey': client.clientName,
        'avatar': avatar,
      });
    } catch (error, stack) {
      Logs().w('Unable to refresh local conversation avatar', error, stack);
    }
  }
}

String conversationBubbleLocation(String roomId, String? payload) {
  final clientName = payload == null
      ? null
      : FluffyChatPushPayload.fromString(payload).clientName;
  return Uri(
    pathSegments: ['', 'rooms', roomId],
    queryParameters: clientName == null ? null : {'client': clientName},
  ).toString();
}

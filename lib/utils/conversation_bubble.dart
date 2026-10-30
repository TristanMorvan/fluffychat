// Fork: action commune aux détails de la pièce et au menu de conversation.
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/utils/push_helper.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

bool canOpenConversationBubble(Room room) =>
    PlatformInfos.isAndroid &&
    AppSettings.androidBubbles.value &&
    room.isDirectChat;

Future<void> openConversationBubble(BuildContext context, Room room) async {
  final l10n = L10n.of(context);
  try {
    await const MethodChannel(
      'chat.fluffy/bubbles',
    ).invokeMethod<void>('openBubble', {
      'roomId': room.id,
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

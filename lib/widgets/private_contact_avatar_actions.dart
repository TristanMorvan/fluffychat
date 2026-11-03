// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:file_selector/file_selector.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/conversation_bubble.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/utils/private_contact_avatar.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// Contact-only actions. These intentionally never call Matrix profile, room,
/// media-upload or account-data APIs.
class PrivateContactAvatarActions extends StatefulWidget {
  final Client client;
  final String userId;
  final PrivateContactAvatarStore? store;
  final Future<XFile?> Function()? pickImage;
  const PrivateContactAvatarActions({
    super.key,
    required this.client,
    required this.userId,
    this.store,
    this.pickImage,
  });

  @override
  State<PrivateContactAvatarActions> createState() =>
      _PrivateContactAvatarActionsState();
}

class _PrivateContactAvatarActionsState
    extends State<PrivateContactAvatarActions> {
  bool _busy = false;
  PrivateContactAvatarStore get store =>
      widget.store ?? PrivateContactAvatarStore.instance;

  Future<void> _change({bool reset = false}) async {
    final client = widget.client;
    final account = PrivateAvatarAccount.fromClient(client);
    if (account == null || _busy) return;
    final userId = widget.userId;
    final localStore = store;
    final l10n = L10n.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      if (reset) {
        await localStore.reset(account, userId);
      } else {
        final file =
            await (widget.pickImage?.call() ??
                openFile(
                  acceptedTypeGroups: const [
                    XTypeGroup(
                      label: 'Images',
                      extensions: ['jpg', 'jpeg', 'png', 'webp', 'gif'],
                      mimeTypes: [
                        'image/jpeg',
                        'image/png',
                        'image/webp',
                        'image/gif',
                      ],
                      uniformTypeIdentifiers: ['public.image'],
                    ),
                  ],
                ));
        if (file == null) return;
        final currentAccount = PrivateAvatarAccount.fromClient(widget.client);
        if (!mounted ||
            widget.userId != userId ||
            currentAccount?.userId != account.userId ||
            currentAccount?.homeserver != account.homeserver)
          return;
        if (await file.length() > PrivateContactAvatarStore.maxFileBytes)
          throw const FormatException('Image too large');
        await localStore.set(account, userId, await file.readAsBytes());
      }
      final refreshAccount = PrivateAvatarAccount.fromClient(client);
      if (PlatformInfos.isAndroid &&
          refreshAccount?.userId == account.userId &&
          refreshAccount?.homeserver == account.homeserver)
        await refreshPrivateContactAvatarSurfaces(
          client,
          userId,
          privateAvatarStore: localStore,
        );
    } catch (_) {
      if (mounted)
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.privateAvatarFailed)),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        !store.storage.supported ||
        PrivateAvatarAccount.fromClient(widget.client) == null ||
        widget.client.userID == widget.userId)
      return const SizedBox.shrink();
    final l10n = L10n.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 4,
      children: [
        Text(
          l10n.privateAvatarHelp,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _change(),
          icon: const Icon(Icons.add_photo_alternate_outlined),
          label: Text(l10n.privateAvatarChoose),
        ),
        TextButton.icon(
          onPressed: _busy ? null : () => _change(reset: true),
          icon: const Icon(Icons.restore),
          label: Text(l10n.privateAvatarReset),
        ),
      ],
    );
  }
}

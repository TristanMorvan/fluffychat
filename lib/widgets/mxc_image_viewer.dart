// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/private_contact_avatar.dart';
import 'package:fluffychat/widgets/private_contact_avatar_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'mxc_image.dart';

class MxcImageViewer extends StatelessWidget {
  final Uri? mxContent;
  final Client? client;
  final String? userId;
  final PrivateContactAvatarStore? privateAvatarStore;

  const MxcImageViewer(
    this.mxContent, {
    this.client,
    this.userId,
    this.privateAvatarStore,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final iconButtonStyle = IconButton.styleFrom(
      backgroundColor: Colors.black.withAlpha(200),
      foregroundColor: Colors.white,
    );
    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: Scaffold(
        backgroundColor: Colors.black.withAlpha(128),
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          elevation: 0,
          leading: IconButton(
            style: iconButtonStyle,
            icon: const Icon(Icons.close),
            onPressed: Navigator.of(context).pop,
            color: Colors.white,
            tooltip: L10n.of(context).close,
          ),
          backgroundColor: Colors.transparent,
        ),
        body: InteractiveViewer(
          minScale: 1.0,
          maxScale: 10.0,
          onInteractionEnd: (endDetails) {
            if (endDetails.velocity.pixelsPerSecond.dy >
                MediaQuery.sizeOf(context).height * 1.5) {
              Navigator.of(context, rootNavigator: false).pop();
            }
          },
          child: Center(
            child: GestureDetector(
              // Ignore taps to not go back here:
              onTap: () {},
              child: PrivateContactAvatarImage(
                client: client,
                userId: userId,
                store: privateAvatarStore,
                size: MediaQuery.sizeOf(context).shortestSide,
                fit: BoxFit.contain,
                child: MxcImage(
                  client: client,
                  key: ValueKey(mxContent.toString()),
                  uri: mxContent,
                  fit: BoxFit.contain,
                  isThumbnail: false,
                  animated: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

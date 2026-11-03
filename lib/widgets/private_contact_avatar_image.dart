// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:fluffychat/utils/private_contact_avatar.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// A local-only layer over the original Matrix avatar. No MXC matching: two
/// people can share the same public image and still have different overrides.
class PrivateContactAvatarImage extends StatefulWidget {
  final Client? client;
  final String? userId;
  final PrivateContactAvatarStore? store;
  final double size;
  final BoxFit fit;
  final Widget child;
  const PrivateContactAvatarImage({
    super.key,
    required this.client,
    required this.userId,
    this.store,
    required this.size,
    this.fit = BoxFit.cover,
    required this.child,
  });

  @override
  State<PrivateContactAvatarImage> createState() =>
      _PrivateContactAvatarImageState();
}

class _PrivateContactAvatarImageState extends State<PrivateContactAvatarImage>
    with WidgetsBindingObserver {
  PrivateContactAvatarStore get store =>
      widget.store ?? PrivateContactAvatarStore.instance;
  Uint8List? _bytes;
  Object? _identity;
  Object get _currentIdentity {
    final account = PrivateAvatarAccount.fromClient(widget.client);
    return (account?.userId, account?.homeserver, widget.userId);
  }

  int _request = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    store.addListener(_load);
    _load();
  }

  Future<void> _load() async {
    final request = ++_request;
    _identity = _currentIdentity;
    final account = PrivateAvatarAccount.fromClient(widget.client);
    final userId = widget.userId;
    final bytes = account == null || userId == null
        ? null
        : await store.read(account, userId);
    if (!mounted || request != _request) return;
    if (_bytes == null && bytes == null) return;
    setState(() => _bytes = bytes);
  }

  @override
  void didUpdateWidget(covariant PrivateContactAvatarImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldStore = oldWidget.store ?? PrivateContactAvatarStore.instance;
    if (oldStore != store) {
      oldStore.removeListener(_load);
      store.addListener(_load);
    }
    if (_identity != _currentIdentity || oldStore != store) {
      _bytes = null; // Never flash another account's photo while loading.
      _load();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  @override
  void dispose() {
    ++_request;
    store.removeListener(_load);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _identity == _currentIdentity ? _bytes : null;
    return bytes == null
        ? widget.child
        : Image.memory(
            bytes,
            width: widget.size,
            height: widget.size,
            fit: widget.fit,
            gaplessPlayback: false,
            errorBuilder: (_, _, _) => widget.child,
          );
  }
}
